import AVFoundation
import ScreenCaptureKit
import VideoToolbox
import RoomPlayKit

enum HostCaptureError: LocalizedError {
    case message(String)
    case status(String, OSStatus)
    var errorDescription: String? {
        switch self {
        case .message(let value): return value
        case .status(let operation, let status): return "\(operation) failed (\(status))."
        }
    }
}

struct CaptureDimensions: Equatable {
    let width: Int
    let height: Int

    static func fitting(displayWidth: Int, displayHeight: Int, maximumWidth: Int, maximumHeight: Int) -> CaptureDimensions {
        let scale = min(1, Double(maximumWidth) / Double(max(displayWidth, 2)), Double(maximumHeight) / Double(max(displayHeight, 2)))
        return CaptureDimensions(width: max(2, Int(Double(displayWidth) * scale) / 2 * 2),
                                 height: max(2, Int(Double(displayHeight) * scale) / 2 * 2))
    }
}

/// Capture/encoding runs on one serial queue. Callbacks only forward immutable data.
final class CaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate {
    var canAcceptVideo: (Int) -> Bool = { _ in false }
    var canAcceptAudio: () -> Bool = { false }
    var onVideoConfiguration: ((RPVideoConfiguration) -> Void)?
    var onVideo: ((Data) -> Bool)?
    var onAudio: ((Data) -> Void)?
    var onFailure: ((Error) -> Void)?

    private let queue = DispatchQueue(label: "app.roomplay.host.capture", qos: .userInteractive)
    private var stream: SCStream?
    private var encoder: VTCompressionSession?
    private var dimensions = CaptureDimensions(width: 1280, height: 720)
    private var forceKeyframe = true
    private var awaitingKeyframe = true
    private var stopped = false
    private var hasFailed = false
    private var encodedFramesInFlight = 0

    func start(displayID: CGDirectDisplayID, options: RPStreamOptions) async throws {
        guard (320...1920).contains(options.width), (240...1080).contains(options.height),
              [30, 60].contains(options.fps), (2...40).contains(options.bitrateMbps) else {
            throw HostCaptureError.message("Unsupported stream quality. Choose 720p or 1080p, 30/60 FPS and 2–40 Mbps.")
        }
        guard CGPreflightScreenCaptureAccess() else {
            throw HostCaptureError.message("Allow Screen Recording for JoyArk Host in System Settings, then restart the host.")
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard queue.sync(execute: { !stopped }) else { throw CancellationError() }
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw HostCaptureError.message("The selected display is no longer connected. Choose another display.")
        }
        dimensions = CaptureDimensions.fitting(displayWidth: display.width, displayHeight: display.height,
                                              maximumWidth: options.width, maximumHeight: options.height)
        try queue.sync { try prepareEncoder(options: options) }
        let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = dimensions.width
        configuration.height = dimensions.height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(options.fps))
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.queueDepth = 3
        configuration.showsCursor = true
        configuration.capturesAudio = options.audioEnabled
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        let capture = SCStream(filter: filter, configuration: configuration, delegate: self)
        do {
            try capture.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            if options.audioEnabled { try capture.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue) }
            stream = capture
            try await capture.startCapture()
            if queue.sync(execute: { stopped }) {
                try? await capture.stopCapture()
                throw CancellationError()
            }
        } catch {
            stream = nil
            queue.sync { invalidateEncoder() }
            throw error
        }
    }

    func stop() async {
        queue.sync { stopped = true }
        let capture = stream
        stream = nil
        try? await capture?.stopCapture()
        queue.sync { invalidateEncoder() }
    }

    func requestKeyframe() { queue.async { [weak self] in self?.forceKeyframe = true } }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { [weak self] in self?.fail(error) }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !stopped, !hasFailed, sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        if type == .audio { processAudio(sampleBuffer); return }
        guard type == .screen else { return }
        processVideo(sampleBuffer)
    }

    private func processVideo(_ sampleBuffer: CMSampleBuffer) {
        guard !stopped, !hasFailed, let encoder, let image = sampleBuffer.imageBuffer else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let raw = attachments.first?[.status] as? Int,
           raw != SCFrameStatus.complete.rawValue { return }
        // Drop before encoding, not after creating a long network/codec queue.
        guard canAcceptVideo(encodedFramesInFlight), encodedFramesInFlight < 2 else { return }
        let properties = forceKeyframe ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        forceKeyframe = false
        encodedFramesInFlight += 1
        let status = VTCompressionSessionEncodeFrame(encoder, imageBuffer: image,
                                                     presentationTimeStamp: sampleBuffer.presentationTimeStamp,
                                                     duration: sampleBuffer.duration,
                                                     frameProperties: properties,
                                                     sourceFrameRefcon: nil, infoFlagsOut: nil)
        if status != noErr {
            encodedFramesInFlight = max(0, encodedFramesInFlight - 1)
            fail(HostCaptureError.status("Video encoding", status))
        }
    }

    private func prepareEncoder(options: RPStreamOptions) throws {
        hasFailed = false
        forceKeyframe = true
        awaitingKeyframe = true
        encodedFramesInFlight = 0
        let specification = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
                             kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true] as CFDictionary
        let status = VTCompressionSessionCreate(allocator: nil, width: Int32(dimensions.width), height: Int32(dimensions.height),
                                                codecType: kCMVideoCodecType_H264, encoderSpecification: specification,
                                                imageBufferAttributes: nil, compressedDataAllocator: nil,
                                                outputCallback: { refcon, _, status, _, sample in
            guard let refcon else { return }
            let owner = Unmanaged<CaptureEngine>.fromOpaque(refcon).takeUnretainedValue()
            owner.queue.async { owner.processEncoded(sample, status: status) }
        }, refcon: Unmanaged.passUnretained(self).toOpaque(), compressionSessionOut: &encoder)
        guard status == noErr, let encoder else { throw HostCaptureError.status("H.264 encoder creation", status) }
        do {
            try set(kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
            try set(kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
            try set(kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
            try set(kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: options.fps))
            try set(kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: options.bitrateMbps * 1_000_000))
            try set(kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: options.fps * 2))
            let prepared = VTCompressionSessionPrepareToEncodeFrames(encoder)
            guard prepared == noErr else { throw HostCaptureError.status("Encoder preparation", prepared) }
        } catch { invalidateEncoder(); throw error }
    }

    private func set(_ key: CFString, value: CFTypeRef) throws {
        guard let encoder else { throw HostCaptureError.message("Video encoder is not available.") }
        let result = VTSessionSetProperty(encoder, key: key, value: value)
        guard result == noErr else { throw HostCaptureError.status("Encoder setting \(key)", result) }
    }

    private func processEncoded(_ sample: CMSampleBuffer?, status: OSStatus) {
        encodedFramesInFlight = max(0, encodedFramesInFlight - 1)
        guard !stopped, !hasFailed else { return }
        guard status == noErr else { fail(HostCaptureError.status("Video encoding", status)); return }
        guard let sample else { return } // VideoToolbox can intentionally drop a frame.
        guard let block = sample.dataBuffer, let format = sample.formatDescription else {
            fail(HostCaptureError.message("The encoder returned an invalid video frame.")); return
        }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let isKeyframe = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        guard !awaitingKeyframe || isKeyframe else { forceKeyframe = true; return }
        if isKeyframe {
            do { onVideoConfiguration?(try videoConfiguration(format)) }
            catch { fail(error); return }
        }
        let length = CMBlockBufferGetDataLength(block)
        guard length > 0, length <= RPProtocol.maxPayload else {
            fail(HostCaptureError.message("Encoded video exceeded the allowed frame size. Lower the stream quality.")); return
        }
        var data = Data(count: length)
        let copied = data.withUnsafeMutableBytes { bytes in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: bytes.baseAddress!)
        }
        guard copied == noErr else { fail(HostCaptureError.status("Copying video data", copied)); return }
        let accepted = onVideo?(data) ?? false
        if accepted && isKeyframe { awaitingKeyframe = false }
        if !accepted { awaitingKeyframe = true; forceKeyframe = true }
    }

    private func videoConfiguration(_ format: CMFormatDescription) throws -> RPVideoConfiguration {
        var count = 0
        var pointer: UnsafePointer<UInt8>?
        var size = 0
        var headerLength: Int32 = 0
        let first = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0,
                                                                       parameterSetPointerOut: &pointer,
                                                                       parameterSetSizeOut: &size,
                                                                       parameterSetCountOut: &count,
                                                                       nalUnitHeaderLengthOut: &headerLength)
        guard first == noErr, count >= 2, headerLength == 4 else {
            throw HostCaptureError.status("Reading H.264 configuration", first)
        }
        var sets = [Data]()
        for index in 0..<count {
            let result = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index,
                                                                           parameterSetPointerOut: &pointer,
                                                                           parameterSetSizeOut: &size,
                                                                           parameterSetCountOut: nil,
                                                                           nalUnitHeaderLengthOut: nil)
            guard result == noErr, let pointer, size > 0 else { throw HostCaptureError.status("Reading H.264 parameter set", result) }
            sets.append(Data(bytes: pointer, count: size))
        }
        return RPVideoConfiguration(parameterSets: sets, width: dimensions.width, height: dimensions.height)
    }

    private func processAudio(_ sample: CMSampleBuffer) {
        guard canAcceptAudio(), let description = sample.formatDescription else { return }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let frames = CMSampleBufferGetNumSamples(sample)
        guard frames > 0, frames <= 48_000 else { return }
        guard format.sampleRate == 48_000, format.channelCount == 2, format.commonFormat == .pcmFormatFloat32,
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let channels = pcm.floatChannelData else {
            fail(HostCaptureError.message("ScreenCaptureKit returned an unsupported audio format.")); return
        }
        pcm.frameLength = AVAudioFrameCount(frames)
        let copied = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList)
        guard copied == noErr else { fail(HostCaptureError.status("Copying system audio", copied)); return }
        if format.isInterleaved {
            onAudio?(Data(bytes: channels[0], count: frames * 2 * MemoryLayout<Float>.size))
        } else {
            var interleaved = [Float](repeating: 0, count: frames * 2)
            for index in 0..<frames {
                interleaved[index * 2] = channels[0][index]
                interleaved[index * 2 + 1] = channels[1][index]
            }
            onAudio?(interleaved.withUnsafeBytes { Data($0) })
        }
    }

    private func invalidateEncoder() {
        if let encoder { VTCompressionSessionInvalidate(encoder) }
        encoder = nil
        encodedFramesInFlight = 0
    }

    private func fail(_ error: Error) {
        guard !stopped, !hasFailed else { return }
        hasFailed = true
        DispatchQueue.main.async { [weak self] in self?.onFailure?(error) }
    }

    #if DEBUG
    /// Test-only entry points use the exact production encoder and never enter a
    /// release executable or create data on an app's first launch.
    func prepareEncoderForTesting(options: RPStreamOptions, width: Int, height: Int) throws {
        dimensions = CaptureDimensions(width: width, height: height)
        try queue.sync { try prepareEncoder(options: options) }
    }

    func encodeFrameForTesting(_ image: CVPixelBuffer) throws {
        var format: CMVideoFormatDescription?
        let formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: image, formatDescriptionOut: &format)
        guard formatStatus == noErr, let format else { throw HostCaptureError.status("Test video format", formatStatus) }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 60), presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: image, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample)
        guard sampleStatus == noErr, let sample else { throw HostCaptureError.status("Test sample", sampleStatus) }
        queue.async { self.processVideo(sample) }
    }

    func finishEncoderForTesting() { queue.sync { stopped = true; invalidateEncoder() } }

    func processAudioForTesting(_ sample: CMSampleBuffer) { queue.async { self.processAudio(sample) } }
    #endif
}

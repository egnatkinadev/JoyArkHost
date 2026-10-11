import XCTest
import AVFoundation
import VideoToolbox
import RoomPlayKit
@testable import RoomPlayHost

final class VideoRoundTripTests: XCTestCase {
    func testProductionEncoderProducesDecodableH264Keyframe() throws {
        let decoded = expectation(description: "The H.264 frame decodes to a real pixel buffer")
        let capture = CaptureEngine()
        let decoder = DecoderProbe(expectation: decoded)
        var configuration: RPVideoConfiguration?
        capture.canAcceptVideo = { _ in true }
        capture.onVideoConfiguration = { configuration = $0 }
        capture.onFailure = { error in XCTFail(error.localizedDescription); decoded.fulfill() }
        capture.onVideo = { data in
            do {
                guard let configuration else { throw HostCaptureError.message("No H.264 configuration preceded the keyframe") }
                XCTAssertTrue(configuration.isValid)
                XCTAssertEqual(configuration.width, 1280)
                XCTAssertEqual(configuration.height, 720)
                try decoder.decode(configuration: configuration, data: data)
            } catch { XCTFail(error.localizedDescription); decoded.fulfill() }
            return true
        }
        try capture.prepareEncoderForTesting(options: RPStreamOptions(width: 1280, height: 720, fps: 60, bitrateMbps: 8, audioEnabled: false), width: 1280, height: 720)
        defer { capture.finishEncoderForTesting(); decoder.stop() }
        var pixel: CVPixelBuffer?
        let made = CVPixelBufferCreate(nil, 1280, 720, kCVPixelFormatType_32BGRA,
                                      [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel)
        XCTAssertEqual(made, kCVReturnSuccess)
        let image = try XCTUnwrap(pixel)
        CVPixelBufferLockBaseAddress(image, [])
        if let address = CVPixelBufferGetBaseAddress(image) {
            let rowBytes = CVPixelBufferGetBytesPerRow(image)
            let bytes = address.assumingMemoryBound(to: UInt8.self)
            for row in 0..<720 {
                for column in 0..<1280 {
                    let offset = row * rowBytes + column * 4
                    bytes[offset] = 20; bytes[offset + 1] = 200; bytes[offset + 2] = 40; bytes[offset + 3] = 255
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(image, [])
        try capture.encodeFrameForTesting(image)
        wait(for: [decoded], timeout: 15)
    }
}

private final class DecoderProbe {
    private let expectation: XCTestExpectation
    private var session: VTDecompressionSession?
    init(expectation: XCTestExpectation) { self.expectation = expectation }

    func decode(configuration: RPVideoConfiguration, data: Data) throws {
        let sets = configuration.parameterSets.map { $0 as NSData }
        var pointers = sets.map { $0.bytes.assumingMemoryBound(to: UInt8.self) }
        var sizes = sets.map(\.length)
        var format: CMVideoFormatDescription?
        let made = pointers.withUnsafeMutableBufferPointer { pointer in
            sizes.withUnsafeMutableBufferPointer { size in
                CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: sets.count,
                                                                    parameterSetPointers: pointer.baseAddress!,
                                                                    parameterSetSizes: size.baseAddress!, nalUnitHeaderLength: 4,
                                                                    formatDescriptionOut: &format)
            }
        }
        guard made == noErr, let format else { throw HostCaptureError.status("Test decoder format", made) }
        var callback = VTDecompressionOutputCallbackRecord(decompressionOutputCallback: { refcon, _, status, _, image, _, _ in
            guard let refcon else { return }
            let probe = Unmanaged<DecoderProbe>.fromOpaque(refcon).takeUnretainedValue()
            XCTAssertEqual(status, noErr)
            guard let image else { XCTFail("Decoder returned no image"); probe.expectation.fulfill(); return }
            XCTAssertEqual(CVPixelBufferGetWidth(image), 1280)
            XCTAssertEqual(CVPixelBufferGetHeight(image), 720)
            CVPixelBufferLockBaseAddress(image, .readOnly)
            if let bytes = CVPixelBufferGetBaseAddress(image)?.assumingMemoryBound(to: UInt8.self) {
                XCTAssertGreaterThan(bytes[1], 150, "Decoded image preserves the test frame's green pixels")
                XCTAssertLessThan(bytes[0], 80)
            } else { XCTFail("Decoder returned no pixel storage") }
            CVPixelBufferUnlockBaseAddress(image, .readOnly)
            probe.expectation.fulfill()
        }, decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque())
        let created = VTDecompressionSessionCreate(allocator: nil, formatDescription: format, decoderSpecification: nil,
                                                   imageBufferAttributes: [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA] as CFDictionary,
                                                   outputCallback: &callback, decompressionSessionOut: &session)
        guard created == noErr, let session else { throw HostCaptureError.status("Test decoder creation", created) }
        var block: CMBlockBuffer?
        let allocated = CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: data.count,
                                                          blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                                          dataLength: data.count, flags: 0, blockBufferOut: &block)
        guard allocated == noErr, let block else { throw HostCaptureError.status("Test video block", allocated) }
        let copied = data.withUnsafeBytes { bytes in CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count) }
        guard copied == noErr else { throw HostCaptureError.status("Test video copy", copied) }
        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 60), presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var size = data.count
        let sampled = CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                               sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                               sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
        guard sampled == noErr, let sample else { throw HostCaptureError.status("Test compressed sample", sampled) }
        let result = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [._EnableAsynchronousDecompression], frameRefcon: nil, infoFlagsOut: nil)
        guard result == noErr else { throw HostCaptureError.status("Test decoding", result) }
    }

    func stop() {
        if let session { VTDecompressionSessionWaitForAsynchronousFrames(session); VTDecompressionSessionInvalidate(session) }
        session = nil
    }
}

import XCTest
import AVFoundation
@testable import RoomPlayHost

final class AudioPacketTests: XCTestCase {
    func testPlanarSystemAudioBecomesInterleavedStereoPCM() throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false))
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2))
        pcm.frameLength = 2
        let channels = try XCTUnwrap(pcm.floatChannelData)
        channels[0][0] = 0.25; channels[0][1] = -0.5
        channels[1][0] = 0.75; channels[1][1] = 0.5
        var description: CMAudioFormatDescription?
        let described = CMAudioFormatDescriptionCreate(allocator: nil, asbd: format.streamDescription,
                                                       layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
                                                       extensions: nil, formatDescriptionOut: &description)
        XCTAssertEqual(described, noErr)
        let audioDescription = try XCTUnwrap(description)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000), presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        let sampled = CMSampleBufferCreate(allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil,
                                          refcon: nil, formatDescription: audioDescription, sampleCount: 2,
                                          sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                          sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample)
        XCTAssertEqual(sampled, noErr)
        let audioSample = try XCTUnwrap(sample)
        XCTAssertEqual(CMSampleBufferSetDataBufferFromAudioBufferList(audioSample, blockBufferAllocator: nil,
                                                                    blockBufferMemoryAllocator: nil, flags: 0,
                                                                    bufferList: pcm.audioBufferList), noErr)
        XCTAssertEqual(CMSampleBufferSetDataReady(audioSample), noErr)
        let delivered = expectation(description: "Stereo PCM audio packet")
        let capture = CaptureEngine()
        capture.canAcceptAudio = { true }
        capture.onFailure = { error in XCTFail(error.localizedDescription); delivered.fulfill() }
        capture.onAudio = { data in
            var values = [Float](repeating: 0, count: 4)
            let count = values.withUnsafeMutableBytes { destination in data.copyBytes(to: destination) }
            XCTAssertEqual(count, 16)
            XCTAssertEqual(values, [0.25, 0.75, -0.5, 0.5])
            delivered.fulfill()
        }
        capture.processAudioForTesting(audioSample)
        wait(for: [delivered], timeout: 3)
    }
}

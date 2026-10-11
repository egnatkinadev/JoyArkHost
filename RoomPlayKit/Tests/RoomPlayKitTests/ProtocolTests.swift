import XCTest
@testable import RoomPlayKit

final class ProtocolTests: XCTestCase {
    func testEveryFragmentBoundaryAndCoalescedFrames() throws {
        let messages = [RPMessage(type: .hello, payload: Data("payload".utf8)),
                        RPMessage(type: .stop), RPMessage(type: .audio, payload: Data([1, 2, 3, 4]))]
        let encoded = try messages.reduce(into: Data()) { result, message in result.append(try RPFraming.encode(message)) }
        for boundary in 0...encoded.count {
            var parser = RPFrameParser()
            let received = try parser.append(Data(encoded.prefix(boundary))) + parser.append(Data(encoded.dropFirst(boundary)))
            XCTAssertEqual(received, messages, "Fragment boundary \(boundary)")
            XCTAssertEqual(parser.bufferedBytes, 0)
            try parser.finish()
        }
        var parser = RPFrameParser()
        var received = [RPMessage]()
        for byte in encoded { received.append(contentsOf: try parser.append(Data([byte]))) }
        XCTAssertEqual(received, messages)
    }

    func testMaliciousLengthsAndUnknownTypesAreRejectedBeforePayloadAllocation() throws {
        var oversized = RPFrameParser()
        XCTAssertThrowsError(try oversized.append(Data([RPMessageType.video.rawValue, 255, 255, 255, 255]))) { error in
            XCTAssertEqual(error as? RPTransportError, .oversizedPayload)
        }
        XCTAssertLessThanOrEqual(oversized.bufferedBytes, 5)
        var unknown = RPFrameParser()
        XCTAssertThrowsError(try unknown.append(Data([255, 0, 0, 0, 0]))) { error in
            XCTAssertEqual(error as? RPTransportError, .unknownMessageType)
        }
        var limited = RPFrameParser(maxPayload: 3)
        XCTAssertThrowsError(try limited.append(Data([RPMessageType.audio.rawValue, 0, 0, 0, 4])))
        XCTAssertThrowsError(try RPFraming.encode(RPMessage(type: .video, payload: Data(count: RPProtocol.maxPayload + 1))))
    }

    func testTruncatedFrameIsFailureAndPayloadBytesDoNotBecomeHeaders() throws {
        let payload = Data([RPMessageType.stop.rawValue, 0, 0, 0, 0])
        let encoded = try RPFraming.encode(RPMessage(type: .video, payload: payload))
        var parser = RPFrameParser()
        XCTAssertTrue(try parser.append(Data(encoded.dropLast())).isEmpty)
        XCTAssertThrowsError(try parser.finish()) { error in
            XCTAssertEqual(error as? RPTransportError, .incompleteFrame)
        }
        XCTAssertEqual(try parser.append(Data(encoded.suffix(1))), [RPMessage(type: .video, payload: payload)])
        try parser.finish()
    }

    func testCodableModelsAndValidationRejectUnboundedOrNonFiniteInput() throws {
        let options = RPStreamOptions(width: 1280, height: 720, fps: 60, bitrateMbps: 12, audioEnabled: true)
        let message = try RPMessage.json(type: .start, value: options)
        XCTAssertEqual(try message.decode(RPStreamOptions.self), options)
        XCTAssertTrue(options.isValid)
        XCTAssertFalse(RPStreamOptions(width: 100_000, height: 100_000, fps: 1000, bitrateMbps: 5000, audioEnabled: true).isValid)
        XCTAssertTrue(RPInputEvent(kind: .key, keyCode: 13, pressed: true).isValid)
        XCTAssertFalse(RPInputEvent(kind: .key, keyCode: 999, pressed: true).isValid)
        XCTAssertFalse(RPInputEvent(kind: .mouseMove, x: .infinity, y: 0).isValid)
        XCTAssertFalse(RPInputEvent(kind: .mouseMove, x: 5000, y: 0).isValid)
        XCTAssertFalse(RPInputEvent(kind: .mouseButton, pressed: true, button: 99).isValid)
        XCTAssertTrue(RPInputEvent(kind: .releaseAll).isValid)
        XCTAssertThrowsError(try RPMessage(type: .hello, payload: Data("{}".utf8)).decode(RPHello.self))
    }
}

import XCTest
import CryptoKit
import Network
@testable import RoomPlayKit

final class PairingTests: XCTestCase {
    func testApprovalRoundTripAndMatchingSixDigitCode() throws {
        let client = try RPPairingClient(clientName: "Test iPhone")
        let host = try RPPairingHost(request: client.request, hostName: "Test Mac")
        let reveal = try client.receive(offer: host.offer)
        let code = try host.receive(reveal: reveal)
        XCTAssertEqual(client.verificationCode, code)
        XCTAssertEqual(host.verificationCode, code)
        XCTAssertEqual(code.count, 6)
        XCTAssertTrue(code.utf8.allSatisfy { (48...57).contains($0) })
        let secret = try RPToken.generate()
        let credential = try host.approve(secret: secret)
        XCTAssertTrue(credential.isValid)
        XCTAssertFalse(credential.sealedSecret.range(of: secret) != nil)
        XCTAssertEqual(try client.open(credential: credential), secret)
        XCTAssertThrowsError(try client.open(credential: credential))
        XCTAssertThrowsError(try host.approve(secret: secret))
        XCTAssertThrowsError(try host.receive(reveal: reveal))
        XCTAssertThrowsError(try client.receive(offer: host.offer))
    }

    func testCredentialRequiresCompletedNonceVerification() throws {
        let client = try RPPairingClient(clientName: "Phone")
        let host = try RPPairingHost(request: client.request, hostName: "Mac")
        XCTAssertNil(client.verificationCode)
        XCTAssertNil(host.verificationCode)
        XCTAssertThrowsError(try host.approve(secret: RPToken.generate()))
        XCTAssertThrowsError(try client.open(credential: RPPairingCredential(sealedSecret: Data(repeating: 1, count: 60))))
        let reveal = try client.receive(offer: host.offer)
        try host.receive(reveal: reveal)
        XCTAssertThrowsError(try host.approve(secret: Data(repeating: 1, count: 31)))
        // Invalid local input can be corrected before the one allowed approval.
        XCTAssertEqual(try client.open(credential: host.approve(secret: Data(repeating: 2, count: 32))), Data(repeating: 2, count: 32))
    }

    func testTamperedNonceCommitmentPermanentlyRejectsSession() throws {
        let client = try RPPairingClient(clientName: "Phone")
        let request = RPPairingRequest(clientName: client.request.clientName,
                                       publicKey: client.request.publicKey,
                                       nonceCommitment: Data(repeating: 0, count: 32))
        let host = try RPPairingHost(request: request, hostName: "Mac")
        let reveal = try client.receive(offer: host.offer)
        XCTAssertThrowsError(try host.receive(reveal: reveal)) { error in
            XCTAssertEqual(error as? RPPairingError, .commitmentMismatch)
        }
        XCTAssertNil(host.verificationCode)
        XCTAssertThrowsError(try host.receive(reveal: reveal))
        XCTAssertThrowsError(try host.approve(secret: RPToken.generate()))
    }

    func testCredentialCannotBeReplayedIntoAnotherHandshake() throws {
        let firstClient = try RPPairingClient(clientName: "Phone")
        let firstHost = try RPPairingHost(request: firstClient.request, hostName: "Mac")
        try firstHost.receive(reveal: firstClient.receive(offer: firstHost.offer))
        let credential = try firstHost.approve(secret: RPToken.generate())
        let secondClient = try RPPairingClient(clientName: "Phone")
        let secondHost = try RPPairingHost(request: secondClient.request, hostName: "Mac")
        try secondHost.receive(reveal: secondClient.receive(offer: secondHost.offer))
        XCTAssertNotEqual(firstClient.request.publicKey, secondClient.request.publicKey)
        XCTAssertNotEqual(firstHost.offer.serverNonce, secondHost.offer.serverNonce)
        XCTAssertThrowsError(try secondClient.open(credential: credential)) { error in
            XCTAssertEqual(error as? RPPairingError, .credentialAuthenticationFailed)
        }
        // Authentication failure consumes the exchange, avoiding retries/oracles.
        XCTAssertThrowsError(try secondClient.open(credential: credential)) { error in
            XCTAssertEqual(error as? RPPairingError, .unexpectedMessage)
        }
    }

    func testTranscriptNameOrNonceTamperingAuthenticatesNothing() throws {
        let client = try RPPairingClient(clientName: "Phone")
        let host = try RPPairingHost(request: client.request, hostName: "Mac")
        let altered = RPPairingOffer(hostName: "Other Mac", publicKey: host.offer.publicKey,
                                     serverNonce: host.offer.serverNonce)
        try host.receive(reveal: client.receive(offer: altered))
        let credential = try host.approve(secret: RPToken.generate())
        XCTAssertThrowsError(try client.open(credential: credential)) { error in
            XCTAssertEqual(error as? RPPairingError, .credentialAuthenticationFailed)
        }
    }

    func testAlteredCiphertextFailsAuthentication() throws {
        let client = try RPPairingClient(clientName: "Phone")
        let host = try RPPairingHost(request: client.request, hostName: "Mac")
        try host.receive(reveal: client.receive(offer: host.offer))
        var bytes = try host.approve(secret: RPToken.generate()).sealedSecret
        bytes[bytes.startIndex + 20] ^= 1
        XCTAssertThrowsError(try client.open(credential: RPPairingCredential(sealedSecret: bytes))) { error in
            XCTAssertEqual(error as? RPPairingError, .credentialAuthenticationFailed)
        }
    }

    func testStrictWireValidationAndCodableRoundTrip() throws {
        let client = try RPPairingClient(clientName: "Phone")
        let host = try RPPairingHost(request: client.request, hostName: "Mac")
        let encoded = try RPMessage.json(type: .pairRequest, value: client.request)
        XCTAssertLessThan(encoded.payload.count, RPPairingProtocol.maxMessageBytes)
        XCTAssertEqual(try encoded.decode(RPPairingRequest.self), client.request)
        XCTAssertTrue(client.request.isValid)
        XCTAssertTrue(host.offer.isValid)
        XCTAssertFalse(RPPairingRequest(clientName: "", publicKey: client.request.publicKey, nonceCommitment: client.request.nonceCommitment).isValid)
        XCTAssertFalse(RPPairingRequest(clientName: "Phone\n", publicKey: client.request.publicKey, nonceCommitment: client.request.nonceCommitment).isValid)
        XCTAssertFalse(RPPairingRequest(clientName: String(repeating: "😀", count: 33), publicKey: client.request.publicKey, nonceCommitment: client.request.nonceCommitment).isValid)
        XCTAssertFalse(RPPairingRequest(clientName: "Phone", protocolVersion: 2, publicKey: client.request.publicKey, nonceCommitment: client.request.nonceCommitment).isValid)
        XCTAssertFalse(RPPairingRequest(clientName: "Phone", publicKey: Data(repeating: 0, count: 31), nonceCommitment: client.request.nonceCommitment).isValid)
        XCTAssertFalse(RPPairingOffer(hostName: "Mac", publicKey: host.offer.publicKey, serverNonce: Data(repeating: 0, count: 33)).isValid)
        XCTAssertFalse(RPPairingReveal(clientNonce: Data(repeating: 0, count: 31)).isValid)
        XCTAssertFalse(RPPairingCredential(sealedSecret: Data(repeating: 0, count: 61)).isValid)
        XCTAssertThrowsError(try RPPairingClient(clientName: "   "))
        XCTAssertThrowsError(try RPPairingHost(request: client.request, hostName: ""))
        let zeroKey = RPPairingRequest(clientName: "Phone", publicKey: Data(repeating: 0, count: 32), nonceCommitment: client.request.nonceCommitment)
        XCTAssertThrowsError(try RPPairingHost(request: zeroKey, hostName: "Mac"))
        let malformed = RPPairingOffer(hostName: "Mac", publicKey: host.offer.publicKey, serverNonce: Data(repeating: 0, count: 31))
        XCTAssertThrowsError(try client.receive(offer: malformed))
        XCTAssertThrowsError(try client.receive(offer: host.offer))
    }

    func testBootstrapFramedExchangeTransfersOnlySealedCredential() throws {
        let queue = DispatchQueue(label: "RoomPlayKitTests.Pairing")
        let listening = expectation(description: "Pairing listener ready")
        let approved = expectation(description: "Approved sealed credential received")
        let listener = try NWListener(using: RPPairingProtocol.parameters(), on: .any)
        let clientSession = try RPPairingClient(clientName: "Phone")
        let secret = try RPToken.generate()
        var hostSession: RPPairingHost?
        var server: RPConnection?
        listener.stateUpdateHandler = { state in
            if case .ready = state { listening.fulfill() }
        }
        listener.newConnectionHandler = { connection in
            let peer = RPConnection(connection: connection, maxPayload: RPPairingProtocol.maxMessageBytes)
            server = peer
            peer.onMessage = { message in
                do {
                    switch message.type {
                    case .pairRequest:
                        let session = try RPPairingHost(request: message.decode(RPPairingRequest.self), hostName: "Mac")
                        hostSession = session
                        peer.sendJSON(type: .pairOffer, value: session.offer)
                    case .pairReveal:
                        let session = try XCTUnwrap(hostSession)
                        XCTAssertEqual(try session.receive(reveal: message.decode(RPPairingReveal.self)), clientSession.verificationCode)
                        // This test's approval action stands in for Mac Allow.
                        peer.sendJSON(type: .pairCredential, value: try session.approve(secret: secret))
                    default: XCTFail("Unexpected pairing message")
                    }
                } catch { XCTFail(error.localizedDescription) }
            }
            peer.start()
        }
        listener.start(queue: queue)
        wait(for: [listening], timeout: 5)
        let client = RPConnection(connection: NWConnection(host: "127.0.0.1", port: try XCTUnwrap(listener.port), using: RPPairingProtocol.parameters()),
                                  maxPayload: RPPairingProtocol.maxMessageBytes)
        defer { client.cancel(); server?.cancel(); listener.cancel() }
        client.onState = { state in
            if case .ready = state {
                XCTAssertFalse(client.send(type: .pairRequest, payload: Data(repeating: 0, count: RPPairingProtocol.maxMessageBytes + 1)))
                client.sendJSON(type: .pairRequest, value: clientSession.request)
            }
            if case .failed(let message) = state { XCTFail(message) }
        }
        client.onMessage = { message in
            do {
                switch message.type {
                case .pairOffer:
                    let reveal = try clientSession.receive(offer: message.decode(RPPairingOffer.self))
                    client.sendJSON(type: .pairReveal, value: reveal)
                case .pairCredential:
                    XCTAssertEqual(try clientSession.open(credential: message.decode(RPPairingCredential.self)), secret)
                    approved.fulfill()
                default: XCTFail("Unexpected pairing message")
                }
            } catch { XCTFail(error.localizedDescription) }
        }
        client.start()
        wait(for: [approved], timeout: 10)
    }

    func testBootstrapRejectsOversizedHeaderWithoutReceivingPayload() throws {
        let queue = DispatchQueue(label: "RoomPlayKitTests.PairingLimit")
        let listening = expectation(description: "Pairing listener ready")
        let rejected = expectation(description: "Oversized advertised payload rejected")
        let listener = try NWListener(using: RPPairingProtocol.parameters(), on: .any)
        var server: RPConnection?
        listener.stateUpdateHandler = { state in
            if case .ready = state { listening.fulfill() }
        }
        listener.newConnectionHandler = { connection in
            let peer = RPConnection(connection: connection, maxPayload: RPPairingProtocol.maxMessageBytes)
            server = peer
            peer.onMessage = { _ in XCTFail("An oversized pairing message was delivered") }
            peer.onState = { state in
                if case .failed(let message) = state {
                    XCTAssertEqual(message, RPTransportError.oversizedPayload.localizedDescription)
                    rejected.fulfill()
                }
            }
            peer.start()
        }
        listener.start(queue: queue)
        wait(for: [listening], timeout: 5)
        let client = NWConnection(host: "127.0.0.1", port: try XCTUnwrap(listener.port), using: RPPairingProtocol.parameters())
        defer { client.cancel(); server?.cancel(); listener.cancel() }
        client.stateUpdateHandler = { state in
            if case .ready = state {
                // Only five bytes arrive. The parser must reject length 2049
                // immediately, without waiting for or allocating the payload.
                client.send(content: Data([RPMessageType.pairRequest.rawValue, 0, 0, 8, 1]),
                            completion: .contentProcessed { error in XCTAssertNil(error) })
            }
        }
        client.start(queue: queue)
        wait(for: [rejected], timeout: 10)
    }
}

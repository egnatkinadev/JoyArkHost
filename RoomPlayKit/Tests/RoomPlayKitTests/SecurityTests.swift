import XCTest
import Network
import Security
@testable import RoomPlayKit

final class SecurityTests: XCTestCase {
    func testStrongTokenRoundTripAndValidation() throws {
        let first = try RPToken.generate()
        let second = try RPToken.generate()
        XCTAssertEqual(first.count, 32)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try RPToken.data(from: RPToken.hexString(first)), first)
        XCTAssertEqual(try RPToken.data(from: RPToken.hexString(first).uppercased()), first)
        XCTAssertThrowsError(try RPToken.data(from: "123456"))
        XCTAssertThrowsError(try RPToken.data(from: String(repeating: "z", count: 64)))
        XCTAssertThrowsError(try RPSecurity.parameters(secret: Data(repeating: 0, count: 6)))
    }

    func testTLS12PSKNegotiatesAES256GCMAndTransfers() throws {
        let secret = try RPToken.generate()
        let queue = DispatchQueue(label: "RoomPlayKitTests.TLS")
        let listening = expectation(description: "Listener ready")
        let received = expectation(description: "Authenticated TLS data received")
        let listener = try NWListener(using: RPSecurity.parameters(secret: secret), on: .any)
        var accepted: NWConnection?
        listener.stateUpdateHandler = { state in
            if case .ready = state { listening.fulfill() }
        }
        listener.newConnectionHandler = { connection in
            accepted = connection
            connection.stateUpdateHandler = { state in
                if case .ready = state {
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 64) { data, _, _, error in
                        XCTAssertNil(error)
                        XCTAssertEqual(data, Data("authenticated".utf8))
                        guard let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else {
                            XCTFail("TLS metadata is missing")
                            received.fulfill()
                            return
                        }
                        XCTAssertEqual(sec_protocol_metadata_get_negotiated_tls_protocol_version(metadata.securityProtocolMetadata), .TLSv12)
                        XCTAssertEqual(sec_protocol_metadata_get_negotiated_tls_ciphersuite(metadata.securityProtocolMetadata).rawValue, 0x00A9)
                        received.fulfill()
                    }
                }
            }
            connection.start(queue: queue)
        }
        listener.start(queue: queue)
        wait(for: [listening], timeout: 5)
        let port = try XCTUnwrap(listener.port)
        let client = NWConnection(host: "127.0.0.1", port: port, using: try RPSecurity.parameters(secret: secret))
        defer { client.cancel(); accepted?.cancel(); listener.cancel() }
        client.stateUpdateHandler = { state in
            if case .ready = state {
                client.send(content: Data("authenticated".utf8), completion: .contentProcessed { error in
                    XCTAssertNil(error)
                })
            }
        }
        client.start(queue: queue)
        wait(for: [received], timeout: 10)
    }

    func testWrongSharedSecretFailsBeforeConnectionIsReady() throws {
        let queue = DispatchQueue(label: "RoomPlayKitTests.WrongSecret")
        let listening = expectation(description: "Listener ready")
        let rejected = expectation(description: "Wrong token rejected")
        let listener = try NWListener(using: RPSecurity.parameters(secret: RPToken.generate()), on: .any)
        var accepted: NWConnection?
        listener.stateUpdateHandler = { state in
            if case .ready = state { listening.fulfill() }
        }
        listener.newConnectionHandler = { connection in
            accepted = connection
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    XCTFail("An unauthenticated client reached ready")
                    rejected.fulfill()
                case .failed:
                    rejected.fulfill()
                    connection.cancel()
                default: break
                }
            }
            connection.start(queue: queue)
        }
        listener.start(queue: queue)
        wait(for: [listening], timeout: 5)
        let client = NWConnection(host: "127.0.0.1", port: try XCTUnwrap(listener.port),
                                  using: try RPSecurity.parameters(secret: RPToken.generate()))
        defer { client.cancel(); accepted?.cancel(); listener.cancel() }
        client.stateUpdateHandler = { state in
            switch state {
            case .ready:
                XCTFail("TLS authenticated a different pairing token")
            default: break
            }
        }
        client.start(queue: queue)
        wait(for: [rejected], timeout: 8)
    }
}

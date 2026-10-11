import XCTest
import Network
@testable import RoomPlayKit

final class ConnectionTests: XCTestCase {
    func testAuthenticatedFramedRoundTripAndCancellation() throws {
        let secret = try RPToken.generate()
        let queue = DispatchQueue(label: "RoomPlayKitTests.Connection")
        let listening = expectation(description: "Listening")
        let welcomed = expectation(description: "Framed welcome")
        let echo = expectation(description: "Framed binary payload")
        let closed = expectation(description: "Connection closed exactly once")
        let listener = try NWListener(using: RPSecurity.parameters(secret: secret), on: .any)
        var server: RPConnection?
        listener.stateUpdateHandler = { state in
            if case .ready = state { listening.fulfill() }
        }
        listener.newConnectionHandler = { connection in
            let peer = RPConnection(connection: connection)
            server = peer
            peer.onMessage = { message in
                switch message.type {
                case .hello:
                    do {
                        let hello = try message.decode(RPHello.self)
                        XCTAssertEqual(hello.clientName, "Test phone")
                        peer.sendJSON(type: .welcome, value: RPWelcome(hostName: "Test Mac", controlAvailable: true))
                    } catch { XCTFail(error.localizedDescription) }
                case .video: peer.send(type: .video, payload: message.payload)
                default: XCTFail("Unexpected message \(message.type)")
                }
            }
            peer.start()
        }
        listener.start(queue: queue)
        wait(for: [listening], timeout: 5)
        let client = RPConnection(connection: NWConnection(host: "127.0.0.1", port: try XCTUnwrap(listener.port),
                                                          using: try RPSecurity.parameters(secret: secret)))
        defer { client.cancel(); server?.cancel(); listener.cancel() }
        let binary = Data((0..<4096).map { UInt8($0 % 251) })
        client.onState = { state in
            XCTAssertTrue(Thread.isMainThread)
            switch state {
            case .ready: client.sendJSON(type: .hello, value: RPHello(clientName: "Test phone"))
            case .closed: closed.fulfill()
            case .failed(let message): XCTFail(message)
            case .waiting: break
            }
        }
        client.onMessage = { message in
            XCTAssertTrue(Thread.isMainThread)
            switch message.type {
            case .welcome:
                do {
                    let welcome = try message.decode(RPWelcome.self)
                    XCTAssertEqual(welcome.hostName, "Test Mac")
                }
                catch { XCTFail(error.localizedDescription) }
                welcomed.fulfill()
                XCTAssertTrue(client.send(type: .video, payload: binary))
            case .video:
                XCTAssertEqual(message.payload, binary)
                echo.fulfill()
            default: XCTFail("Unexpected message \(message.type)")
            }
        }
        client.start()
        client.start() // Idempotent; must not install duplicate receivers.
        wait(for: [welcomed, echo], timeout: 10)
        XCTAssertEqual(client.pendingBytes, 0)
        XCTAssertEqual(client.pendingVideoFrames, 0)
        client.cancel()
        client.cancel()
        wait(for: [closed], timeout: 3)
        XCTAssertFalse(client.send(type: .ping))
    }

    func testUnreadyConnectionRejectsPacketsAndCompletionIsOnMain() {
        let connection = RPConnection(connection: NWConnection(host: "127.0.0.1", port: 1, using: .tcp))
        let rejected = expectation(description: "Unready send rejected")
        XCTAssertFalse(connection.send(type: .ping) { error in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(error as? RPTransportError, .notConnected)
            rejected.fulfill()
        })
        XCTAssertEqual(connection.pendingBytes, 0)
        wait(for: [rejected], timeout: 1)
        connection.cancel()
    }
}

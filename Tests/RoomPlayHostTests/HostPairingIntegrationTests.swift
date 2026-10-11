import Combine
import Network
import RoomPlayKit
import XCTest
@testable import RoomPlayHost

@MainActor
final class HostPairingIntegrationTests: XCTestCase {
    func testLocalPairingRequiresMacApprovalBeforeSendingCredential() async throws {
        let fixture = try AutoPairingFixture(test: self)
        defer { fixture.stop() }
        let verified = expectation(description: "A verified request reaches the Mac approval state")
        let premature = expectation(description: "No credential before local approval")
        premature.isInverted = true
        let approved = expectation(description: "The phone receives the encrypted approved key")
        var allowed = false
        let observation = fixture.host.$request.compactMap { $0 }.prefix(1).sink { request in
            XCTAssertEqual(request.clientName, "RoomPlay Integration Test")
            XCTAssertEqual(request.verificationCode, fixture.phone.verificationCode)
            verified.fulfill()
        }
        defer { observation.cancel() }
        fixture.onMessage = { message in
            if message.type == .pairReject { XCTFail("An approved request was rejected by a duplicate approval action") }
            if message.type == .pairCredential {
                if !allowed { premature.fulfill(); return }
                do {
                    let actual = try fixture.phone.open(credential: message.decode(RPPairingCredential.self))
                    XCTAssertEqual(actual, fixture.secret)
                    approved.fulfill()
                } catch { XCTFail(error.localizedDescription); approved.fulfill() }
            }
        }
        try await fixture.start()
        await fulfillment(of: [verified], timeout: 5)
        await fulfillment(of: [premature], timeout: 0.15)
        let request = try XCTUnwrap(fixture.host.request)
        allowed = true
        fixture.host.approve(request.id)
        fixture.host.approve(request.id) // Repeated UI actions are ignored while sending.
        await fulfillment(of: [approved], timeout: 5)
        XCTAssertNil(fixture.host.request)
    }

    func testRejectDismissesPendingApprovalAndReportsRejection() async throws {
        let fixture = try AutoPairingFixture(test: self)
        defer { fixture.stop() }
        let verified = expectation(description: "A request is waiting for local approval")
        let rejected = expectation(description: "The phone receives the rejection")
        let observation = fixture.host.$request.compactMap { $0 }.prefix(1).sink { _ in verified.fulfill() }
        defer { observation.cancel() }
        fixture.onMessage = { message in
            if message.type == .pairCredential { XCTFail("A rejected request received a credential") }
            if message.type == .pairReject {
                do { _ = try message.decode(RPErrorMessage.self) }
                catch { XCTFail(error.localizedDescription) }
                rejected.fulfill()
            }
        }
        try await fixture.start()
        await fulfillment(of: [verified], timeout: 5)
        let request = try XCTUnwrap(fixture.host.request)
        fixture.host.reject(request.id)
        await fulfillment(of: [rejected], timeout: 5)
        XCTAssertNil(fixture.host.request)
        fixture.host.approve(request.id) // A stale UI action cannot revive it.
        XCTAssertNil(fixture.host.request)
    }
}

@MainActor
private final class AutoPairingFixture {
    let host = HostAutomaticPairing()
    let phone: RPPairingClient
    let secret: Data
    var onMessage: ((RPMessage) -> Void)?
    private let test: XCTestCase
    private var connection: RPConnection?

    init(test: XCTestCase) throws {
        self.test = test
        phone = try RPPairingClient(clientName: "RoomPlay Integration Test")
        secret = try RPToken.generate()
    }

    func start() async throws {
        guard let address = NetworkAddresses.ipv4Addresses.first(where: RPAddress.isAllowed) else {
            throw XCTSkip("A private local IPv4 interface is required to exercise the real host admission filter.")
        }
        let ready = test.expectation(description: "Production automatic pairing listener is ready")
        host.onListenerState = { state in
            switch state {
            case .ready: ready.fulfill()
            case .failed(let message): XCTFail(message); ready.fulfill()
            default: break
            }
        }
        try host.start(serviceName: "RoomPlay Integration \(UUID().uuidString.prefix(6))", hostName: "RoomPlay Integration Test",
                       credentialProvider: { [secret] in secret }, canAcceptRequest: { true }, port: 0)
        await test.fulfillment(of: [ready], timeout: 5)
        guard host.isReady else { throw HostCaptureError.message("The host pairing listener did not become ready.") }
        let boundPort = try XCTUnwrap(host.listeningPort)
        let next = RPConnection(connection: NWConnection(to: .hostPort(host: .init(address), port: boundPort),
                                                         using: RPPairingProtocol.parameters()), maxPayload: RPPairingProtocol.maxMessageBytes)
        connection = next
        next.onState = { [weak self, weak next] state in
            guard let self, let next else { return }
            if state == .ready { next.sendJSON(type: .pairRequest, value: self.phone.request) }
        }
        next.onMessage = { [weak self, weak next] message in
            guard let self, let next else { return }
            if message.type == .pairOffer {
                do {
                    let reveal = try self.phone.receive(offer: message.decode(RPPairingOffer.self))
                    next.sendJSON(type: .pairReveal, value: reveal)
                } catch { XCTFail(error.localizedDescription) }
            } else { self.onMessage?(message) }
        }
        next.start()
    }

    func stop() { host.stop(); connection?.cancel(); connection = nil }
}

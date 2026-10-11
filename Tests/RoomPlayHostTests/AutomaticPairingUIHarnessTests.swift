import Combine
import Darwin
import Network
import RoomPlayKit
import XCTest
@testable import RoomPlayHost

/// Opt-in real LAN fixture for simulator UI tests. It is compiled only into this
/// test bundle, creates no production data and never captures or controls a Mac.
@MainActor
final class AutomaticPairingUIHarnessTests: XCTestCase {
    func testAutomaticPairingUIHarness() async throws {
        guard ProcessInfo.processInfo.environment["ROOMPLAY_UI_PAIRING_HARNESS"] == "1" else {
            throw XCTSkip("The live simulator pairing harness is opt-in.")
        }
        let fixture = try PairingUIHarness()
        try await fixture.start(test: self)
        defer { fixture.stop() }
        print("ROOMPLAY_UI_PAIRING_HARNESS_READY")
        fflush(stdout)
        for _ in 0..<360 { try await Task.sleep(nanoseconds: 1_000_000_000) }
    }
}

@MainActor
private final class PairingUIHarness {
    private let host = HostAutomaticPairing()
    private let secret: Data
    private let ownAddresses = ownPrivateAddresses()
    private let name = "RoomPlay Pairing Test"
    private let allowedPhoneNames = Set(["RoomPlayStandard", "RoomPlayTall", "RoomPlay Standard", "RoomPlay Tall", "iPhone"])
    private var listener: NWListener?
    private var client: RPConnection?
    private var observation: AnyCancellable?

    init() throws { secret = try RPToken.generate() }

    func start(test: XCTestCase) async throws {
        guard !ownAddresses.isEmpty else { throw XCTSkip("The UI harness needs a private LAN interface.") }
        let streamReady = test.expectation(description: "Harness authenticated listener ready")
        let pairReady = test.expectation(description: "Production bootstrap listener ready")
        let next = try NWListener(using: RPSecurity.parameters(secret: secret), on: .init(rawValue: RPProtocol.port)!)
        listener = next
        next.service = NWListener.Service(name: name, type: RPProtocol.serviceType)
        next.stateUpdateHandler = { state in
            if case .ready = state { streamReady.fulfill() }
            if case .failed(let error) = state { XCTFail(error.localizedDescription); streamReady.fulfill() }
        }
        next.newConnectionHandler = { [weak self] connection in
            DispatchQueue.main.async { self?.acceptStream(connection) }
        }
        next.start(queue: DispatchQueue(label: "RoomPlay.UIHarness.Stream"))
        host.onListenerState = { state in
            if case .ready = state { pairReady.fulfill() }
            if case .failed(let message) = state { XCTFail(message); pairReady.fulfill() }
        }
        try host.start(serviceName: name, hostName: name, credentialProvider: { [secret] in secret },
                       canAcceptRequest: { [weak self] in self?.client == nil },
                       isAllowedPeer: { [ownAddresses] address in ownAddresses.contains(unscoped(address)) })
        observation = host.$request.compactMap { $0 }.sink { [weak self] request in
            guard let self else { return }
            guard self.allowedPhoneNames.contains(request.clientName) else { self.host.reject(request.id); return }
            // A test-only approval delay gives the iPhone UI time to display the
            // genuine production SAS. Real host approval is always manual.
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in self?.host.approve(request.id) }
        }
        await test.fulfillment(of: [streamReady, pairReady], timeout: 10)
        guard host.isReady else { throw HostCaptureError.message("The UI pairing harness did not become ready.") }
    }

    func stop() {
        observation?.cancel()
        observation = nil
        host.stop()
        client?.cancel()
        client = nil
        listener?.cancel()
        listener = nil
    }

    private func acceptStream(_ connection: NWConnection) {
        guard case .hostPort(let remote, _) = connection.endpoint,
              ownAddresses.contains(unscoped(String(describing: remote))), client == nil else {
            connection.cancel()
            return
        }
        let next = RPConnection(connection: connection)
        client = next
        next.onState = { [weak self, weak next] state in
            guard let self, let next, self.client === next else { return }
            if state == .closed { self.client = nil }
            if case .failed = state { self.client = nil }
        }
        next.onMessage = { [weak self, weak next] message in
            guard let self, let next, self.client === next else { return }
            do {
                switch message.type {
                case .hello:
                    let hello = try message.decode(RPHello.self)
                    guard hello.protocolVersion == RPProtocol.protocolVersion else { throw RPPairingError.invalidMessage }
                    next.sendJSON(type: .welcome, value: RPWelcome(hostName: self.name, controlAvailable: false))
                case .ping: next.send(type: .pong, payload: message.payload)
                case .stop, .input: break // No capture/control exists in this fixture.
                case .start: next.sendJSON(type: .failure, value: RPErrorMessage(message: "The pairing test host does not capture a screen."))
                default: throw RPPairingError.unexpectedMessage
                }
            } catch { next.sendJSON(type: .failure, value: RPErrorMessage(message: error.localizedDescription)) }
        }
        next.start()
    }
}

private func unscoped(_ address: String) -> String {
    String(address.lowercased().split(separator: "%").first ?? "")
}

private func ownPrivateAddresses() -> Set<String> {
    var interfaces: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&interfaces) == 0, let first = interfaces else { return [] }
    defer { freeifaddrs(interfaces) }
    var values = Set<String>()
    var cursor: UnsafeMutablePointer<ifaddrs>? = first
    while let entry = cursor {
        defer { cursor = entry.pointee.ifa_next }
        guard let address = entry.pointee.ifa_addr,
              [UInt8(AF_INET), UInt8(AF_INET6)].contains(address.pointee.sa_family),
              String(cString: entry.pointee.ifa_name).hasPrefix("en") else { continue }
        var text = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(address, socklen_t(address.pointee.sa_len), &text, socklen_t(text.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
        let value = String(cString: text)
        if RPAddress.isAllowed(value) { values.insert(unscoped(value)) }
    }
    return values
}

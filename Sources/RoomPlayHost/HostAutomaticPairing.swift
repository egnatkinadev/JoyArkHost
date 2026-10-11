import Combine
import Foundation
import Network
import RoomPlayKit

enum HostPairingListenerState {
    case starting, ready, waiting(String), failed(String), stopped
}

/// An unauthenticated bootstrap socket exchanges only ephemeral public material.
/// The durable streaming key can leave the host only after explicit Mac approval,
/// wrapped by the shared protocol's authenticated ECDH-derived encryption.
@MainActor
final class HostAutomaticPairing: ObservableObject {
    @Published private(set) var isReady = false
    @Published private(set) var request: HostPairingRequest?
    @Published private(set) var status = "Start Host to allow pairing"
    var onListenerState: ((HostPairingListenerState) -> Void)?

    private var listener: NWListener?
    private var generation = UUID()
    private var channel: RPConnection?
    private var session: RPPairingHost?
    private var gate = HostPairingGate()
    private var deadline: DispatchWorkItem?
    private var credentialProvider: (() -> Data?)?
    private var canAcceptRequest: (() -> Bool)?
    private var isAllowedPeer: ((String) -> Bool)?
    private var hostName = "Mac"

    var listeningPort: NWEndpoint.Port? { listener?.port }

    func start(serviceName: String, hostName: String, credentialProvider: @escaping () -> Data?,
               canAcceptRequest: @escaping () -> Bool, isAllowedPeer: @escaping (String) -> Bool = { _ in true },
               port: UInt16 = RPPairingProtocol.port) throws {
        guard listener == nil else { return }
        self.credentialProvider = credentialProvider
        self.canAcceptRequest = canAcceptRequest
        self.isAllowedPeer = isAllowedPeer
        self.hostName = hostName
        let next = try NWListener(using: RPPairingProtocol.parameters(), on: NWEndpoint.Port(rawValue: port)!)
        let id = UUID()
        generation = id
        listener = next
        status = "Starting automatic pairing…"
        onListenerState?(.starting)
        next.service = NWListener.Service(name: serviceName, type: RPPairingProtocol.serviceType)
        next.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                guard let self, self.generation == id, self.listener != nil else { return }
                switch state {
                case .ready:
                    self.isReady = true
                    self.status = "Select this Mac in JoyArk on your iPhone"
                    self.onListenerState?(.ready)
                case .waiting(let error):
                    self.isReady = false
                    self.status = "Waiting for local network"
                    self.onListenerState?(.waiting(error.localizedDescription))
                case .failed(let error):
                    self.isReady = false
                    self.onListenerState?(.failed(error.localizedDescription))
                case .cancelled: self.isReady = false
                default: break
                }
            }
        }
        next.newConnectionHandler = { [weak self] connection in
            DispatchQueue.main.async {
                guard let self, self.generation == id, self.isReady else { connection.cancel(); return }
                self.accept(connection)
            }
        }
        next.start(queue: DispatchQueue(label: "app.roomplay.host.pairing-listener"))
    }

    func stop() {
        generation = UUID()
        cancelPending()
        listener?.cancel()
        listener = nil
        isReady = false
        credentialProvider = nil
        canAcceptRequest = nil
        isAllowedPeer = nil
        status = "Start Host to allow pairing"
        onListenerState?(.stopped)
    }

    func cancelPending(reason: String = "Pairing was cancelled on the Mac.") {
        guard let id = gate.currentID else { return }
        finish(id, rejection: reason)
    }

    func reject(_ id: UUID) { finish(id, rejection: "The Mac declined this pairing request.") }

    func approve(_ id: UUID) {
        guard gate.currentID == id, gate.phase == .awaitingApproval else { return }
        guard let request, request.id == id, let session, let channel,
              canAcceptRequest?() == true, let secret = credentialProvider?() else {
            finish(id, rejection: "The host is no longer available for pairing.")
            return
        }
        do {
            let credential = try session.approve(secret: secret)
            guard gate.approve(id) else { return }
            self.request = nil
            status = "Completing secure pairing…"
            setDeadline(id: id, seconds: 10)
            channel.sendJSON(type: .pairCredential, value: credential) { [weak self] error in
                guard let self, self.gate.currentID == id else { return }
                self.finish(id, rejection: nil)
            }
        } catch { finish(id, rejection: error.localizedDescription) }
    }

    private func accept(_ connection: NWConnection) {
        guard case .hostPort(let host, _) = connection.endpoint,
              RPAddress.isAllowed(String(describing: host)), isAllowedPeer?(String(describing: host)) == true,
              canAcceptRequest?() == true,
              let id = gate.begin() else {
            connection.cancel()
            return
        }
        let next = RPConnection(connection: connection, maxPayload: RPPairingProtocol.maxMessageBytes)
        channel = next
        session = nil
        status = "Checking iPhone pairing request…"
        next.onState = { [weak self, weak next] state in
            guard let self, let next, self.channel === next, self.gate.currentID == id else { return }
            switch state {
            case .failed, .closed: self.finish(id, rejection: nil)
            default: break
            }
        }
        next.onMessage = { [weak self, weak next] message in
            guard let self, let next, self.channel === next, self.gate.currentID == id else { return }
            self.handle(message, id: id, channel: next)
        }
        setDeadline(id: id, seconds: 15)
        next.start()
    }

    private func handle(_ message: RPMessage, id: UUID, channel: RPConnection) {
        guard message.payload.count <= RPPairingProtocol.maxMessageBytes else { finish(id, rejection: "Invalid pairing request."); return }
        do {
            switch message.type {
            case .pairRequest:
                guard gate.phase == .negotiating, session == nil else { throw HostCaptureError.message("Pairing request was already received.") }
                let value = try message.decode(RPPairingRequest.self)
                let next = try RPPairingHost(request: value, hostName: hostName)
                session = next
                channel.sendJSON(type: .pairOffer, value: next.offer)
            case .pairReveal:
                guard gate.phase == .negotiating, let session else { throw HostCaptureError.message("A pairing request is required first.") }
                let value = try message.decode(RPPairingReveal.self)
                let code = try session.receive(reveal: value)
                guard gate.verified(id) else { throw HostCaptureError.message("This pairing request is no longer active.") }
                request = HostPairingRequest(id: id, clientName: session.clientName, verificationCode: code)
                status = "Confirm the matching code to allow your iPhone"
                setDeadline(id: id, seconds: 90)
            case .pairCancel: finish(id, rejection: nil)
            default: throw HostCaptureError.message("Unexpected pairing message.")
            }
        } catch { finish(id, rejection: error.localizedDescription) }
    }

    private func setDeadline(id: UUID, seconds: TimeInterval) {
        deadline?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.gate.currentID == id else { return }
            self.finish(id, rejection: "Pairing timed out. Select the Mac on your iPhone to try again.")
        }
        deadline = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func finish(_ id: UUID, rejection: String?) {
        guard gate.finish(id) else { return }
        deadline?.cancel()
        deadline = nil
        request = nil
        session = nil
        let old = channel
        channel = nil
        status = isReady ? "Select this Mac in JoyArk on your iPhone" : "Start Host to allow pairing"
        if let rejection, let old {
            old.sendJSON(type: .pairReject, value: RPErrorMessage(message: String(rejection.prefix(512)))) { _ in old.cancel() }
        } else { old?.cancel() }
    }
}

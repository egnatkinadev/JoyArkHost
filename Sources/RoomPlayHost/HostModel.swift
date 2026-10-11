import AppKit
import Combine
import CoreImage.CIFilterBuiltins
import Network
import RoomPlayKit

struct HostDisplay: Identifiable, Hashable {
    let id: CGDirectDisplayID
    let name: String
    let width: Int
    let height: Int
    var label: String { "\(name) · \(width) × \(height)" }
}

@MainActor
final class HostModel: ObservableObject {
    @Published private(set) var displays = [HostDisplay]()
    @Published var selectedDisplayID: CGDirectDisplayID = CGMainDisplayID() {
        didSet { UserDefaults.standard.set(selectedDisplayID, forKey: "selectedDisplayID") }
    }
    @Published private(set) var status = "Host is stopped"
    @Published private(set) var listenerReady = false
    @Published private(set) var listenerStarting = false
    @Published private(set) var clientName: String?
    @Published private(set) var streaming = false
    @Published private(set) var sessionStarting = false
    @Published private(set) var sessionStopping = false
    @Published private(set) var screenPermission = false
    @Published private(set) var controlPermission = false
    @Published private(set) var pairingToken = ""
    @Published private(set) var pairingURL = ""
    @Published private(set) var localAddresses = [String]()
    @Published var errorMessage: String?
    @Published var allowStreaming = true {
        didSet { if !allowStreaming { stopSession(notifyClient: true) } }
    }
    @Published var allowControl = true {
        didSet {
            if !allowControl { input.releaseAll() }
            sendWelcome()
        }
    }

    let hostName = NetworkAddresses.displayName
    let hostAddress = NetworkAddresses.localHostName
    let automaticPairing = HostAutomaticPairing()
    private var secret: Data?
    private var listener: NWListener?
    private var listenerID = UUID()
    private var client: RPConnection?
    private var clientDidHello = false
    private var engine: CaptureEngine?
    private let input = InputInjector()
    private var observers = [NSObjectProtocol]()
    private var handshakeDeadline: DispatchWorkItem?
    private var heartbeat: Timer?
    private var lastMessage = Date()
    private var lastInputFailure = Date.distantPast

    var controlsAvailable: Bool { allowControl && controlPermission }
    var displaySelectionLocked: Bool { streaming || sessionStarting || sessionStopping }

    init() {
        if let saved = UserDefaults.standard.object(forKey: "selectedDisplayID") as? NSNumber { selectedDisplayID = saved.uint32Value }
        do { secret = try PairingSecret.loadOrCreate(); updatePairing() }
        catch { errorMessage = "Pairing key could not be stored securely: \(error.localizedDescription)" }
        refreshDisplays()
        refreshPermissions()
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshPermissions(); self?.refreshDisplays() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopHost() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopHost() }
        })
        heartbeat = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.refreshPermissions()
                if self.clientDidHello, Date().timeIntervalSince(self.lastMessage) > 20 {
                    self.disconnectClient(message: "The iPhone stopped responding. Reconnect to start a new session.")
                }
            }
        }
    }

    func refreshDisplays() {
        displays = NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let id = CGDirectDisplayID(number.uint32Value)
            return HostDisplay(id: id, name: screen.localizedName, width: CGDisplayPixelsWide(id), height: CGDisplayPixelsHigh(id))
        }
        if !displays.contains(where: { $0.id == selectedDisplayID }), let display = displays.first {
            selectedDisplayID = display.id
        }
        localAddresses = NetworkAddresses.ipv4Addresses
    }

    func refreshPermissions() {
        screenPermission = CGPreflightScreenCaptureAccess()
        let available = input.isAvailable
        if controlPermission != available {
            controlPermission = available
            if !available { input.releaseAll() }
            sendWelcome()
        }
    }

    func requestScreenPermission() {
        _ = CGRequestScreenCaptureAccess()
        refreshPermissions()
        openSettings("Privacy_ScreenCapture")
    }

    func requestControlPermission() {
        input.requestPermission()
        openSettings("Privacy_Accessibility")
        refreshPermissions()
    }

    func openSettings(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        if !NSWorkspace.shared.open(url) { errorMessage = "Open System Settings → Privacy & Security to grant the permission." }
    }

    func startHost() {
        guard listener == nil, let secret else {
            if self.secret == nil { errorMessage = "A secure pairing key is required. Reset the pairing key and try again." }
            return
        }
        do {
            let parameters = try RPSecurity.parameters(secret: secret)
            let newListener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: RPProtocol.port)!)
            let generation = UUID()
            listenerID = generation
            listener = newListener
            listenerStarting = true
            status = "Starting local host…"
            let serviceName = String("JoyArk \(hostName)".prefix(48))
            newListener.service = NWListener.Service(name: serviceName, type: RPProtocol.serviceType)
            newListener.stateUpdateHandler = { [weak self] state in
                DispatchQueue.main.async {
                    guard let self, self.listenerID == generation, self.listener != nil else { return }
                    switch state {
                    case .ready:
                        self.listenerReady = true
                        self.refreshDisplays()
                        self.startAutomaticPairing(generation: generation, serviceName: serviceName)
                    case .failed(let error):
                        self.errorMessage = "Cannot start the local host: \(error.localizedDescription)"
                        self.stopHost()
                    case .waiting(let error):
                        self.status = "Waiting for local network: \(error.localizedDescription)"
                    case .cancelled:
                        self.listenerStarting = false
                        self.listenerReady = false
                    default: break
                    }
                }
            }
            newListener.newConnectionHandler = { [weak self] connection in
                DispatchQueue.main.async {
                    guard let self, self.listenerID == generation, self.listenerReady else { connection.cancel(); return }
                    self.accept(connection)
                }
            }
            newListener.start(queue: DispatchQueue(label: "app.roomplay.host.listener"))
        } catch { errorMessage = error.localizedDescription; stopHost() }
    }

    func stopHost() {
        listenerID = UUID()
        automaticPairing.stop()
        listener?.cancel()
        listener = nil
        listenerReady = false
        listenerStarting = false
        disconnectClient(message: nil)
        status = "Host is stopped"
    }

    func disconnectPhone() {
        client?.send(type: .stop)
        disconnectClient(message: nil)
    }

    func stopSession(notifyClient: Bool = true) {
        input.releaseAll()
        if notifyClient, clientDidHello { client?.send(type: .stop) }
        guard let capture = engine else { return }
        engine = nil
        streaming = false
        sessionStarting = false
        sessionStopping = true
        status = clientName.map { "Connected to \($0)" } ?? (listenerReady ? "Ready for iPhone" : "Host is stopped")
        Task { @MainActor in
            await capture.stop()
            self.sessionStopping = false
        }
    }

    func rotatePairingKey() {
        stopHost()
        do { secret = try PairingSecret.rotate(); updatePairing() }
        catch { errorMessage = "Could not replace the pairing key: \(error.localizedDescription)" }
    }

    func copyPairingLink() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pairingURL, forType: .string)
    }

    func copyToken() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pairingToken, forType: .string)
    }

    var qrImage: NSImage? {
        guard !pairingURL.isEmpty else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(pairingURL.utf8)
        filter.correctionLevel = "M"
        guard let image = filter.outputImage,
              let rendered = CIContext().createCGImage(image.transformed(by: CGAffineTransform(scaleX: 5, y: 5)), from: image.extent.applying(CGAffineTransform(scaleX: 5, y: 5))) else { return nil }
        return NSImage(cgImage: rendered, size: NSSize(width: rendered.width, height: rendered.height))
    }

    private func updatePairing() {
        guard let secret else { return }
        pairingToken = RPToken.hexString(secret)
        do {
            pairingURL = try RPPairingAddress(host: hostAddress, token: secret, name: String(hostName.prefix(128))).encoded()
        } catch { pairingURL = ""; errorMessage = error.localizedDescription }
    }

    private func accept(_ connection: NWConnection) {
        guard case .hostPort(let remoteHost, _) = connection.endpoint,
              RPAddress.isAllowed(String(describing: remoteHost)) else {
            connection.cancel()
            return
        }
        guard client == nil else { connection.cancel(); return }
        let channel = RPConnection(connection: connection)
        client = channel
        clientDidHello = false
        status = "Verifying iPhone pairing…"
        channel.onState = { [weak self, weak channel] state in
            guard let self, let channel, self.client === channel else { return }
            switch state {
            case .ready:
                // TLS is authenticated. A different phone's pending bootstrap
                // must not survive an already-established streaming connection.
                self.automaticPairing.cancelPending(reason: "An iPhone has connected to the host.")
            case .failed(let message): self.disconnectClient(message: "Connection failed: \(message)")
            case .closed: self.disconnectClient(message: nil)
            case .waiting(let message): self.status = "Connection waiting: \(message)"
            }
        }
        channel.onMessage = { [weak self, weak channel] message in
            guard let self, let channel, self.client === channel else { return }
            self.handle(message, from: channel)
        }
        let deadline = DispatchWorkItem { [weak self, weak channel] in
            guard let self, let channel, self.client === channel, !self.clientDidHello else { return }
            self.disconnectClient(message: "Pairing timed out. Check that both devices use the same pairing key.")
        }
        handshakeDeadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: deadline)
        channel.start()
    }

    private func handle(_ message: RPMessage, from channel: RPConnection) {
        lastMessage = Date()
        do {
            if !clientDidHello {
                guard message.type == .hello else { throw HostCaptureError.message("Send a valid RoomPlay hello before starting a session.") }
                let hello = try message.decode(RPHello.self)
                guard hello.protocolVersion == RPProtocol.protocolVersion,
                      !hello.clientName.isEmpty, hello.clientName.count <= 128 else {
                    throw HostCaptureError.message("The iPhone and Mac host use incompatible protocol versions.")
                }
                clientDidHello = true
                clientName = hello.clientName
                handshakeDeadline?.cancel()
                handshakeDeadline = nil
                status = "Connected to \(hello.clientName)"
                refreshPermissions()
                sendWelcome()
                return
            }
            switch message.type {
            case .start: try beginSession(options: message.decode(RPStreamOptions.self), channel: channel)
            case .stop: stopSession(notifyClient: false)
            case .input:
                let event = try message.decode(RPInputEvent.self)
                guard event.isValid else { throw HostCaptureError.message("Invalid input event.") }
                if event.kind == .releaseAll { input.releaseAll(); return }
                guard streaming, controlsAvailable else {
                    if Date().timeIntervalSince(lastInputFailure) > 5 {
                        lastInputFailure = Date()
                        sendFailure("Remote control is unavailable. Enable Accessibility and keyboard/mouse control on the Mac.")
                    }
                    return
                }
                switch event.kind {
                case .key: input.key(code: Int(event.keyCode!), pressed: event.pressed!)
                case .mouseMove: input.mouseMove(x: event.x!, y: event.y!)
                case .mouseButton: input.mouseButton(event.button!, pressed: event.pressed!)
                case .releaseAll: input.releaseAll()
                }
            case .requestKeyframe: engine?.requestKeyframe()
            case .ping: channel.send(type: .pong, payload: message.payload)
            case .pong: break
            default: throw HostCaptureError.message("Unexpected message from the iPhone.")
            }
        } catch { sendFailure(error.localizedDescription) }
    }

    private func beginSession(options: RPStreamOptions, channel: RPConnection) throws {
        guard allowStreaming else { throw HostCaptureError.message("Streaming is disabled on the Mac host.") }
        guard engine == nil, !sessionStarting, !sessionStopping else { throw HostCaptureError.message("A streaming session is already active or stopping.") }
        guard options.isValid else { throw HostCaptureError.message("Invalid stream quality settings.") }
        guard displays.contains(where: { $0.id == selectedDisplayID }) else { throw HostCaptureError.message("Select a connected display on the Mac host.") }
        refreshPermissions()
        sendWelcome()
        let capture = CaptureEngine()
        engine = capture
        sessionStarting = true
        status = "Starting screen capture…"
        let selected = selectedDisplayID
        input.selectDisplay(selected)
        capture.canAcceptVideo = { [weak channel] inFlight in
            guard let channel else { return false }
            return channel.pendingBytes < 512 * 1024 && channel.pendingVideoFrames + inFlight < 2
        }
        capture.canAcceptAudio = { [weak channel] in channel.map { $0.pendingBytes < 256 * 1024 } ?? false }
        capture.onVideoConfiguration = { [weak channel] value in channel?.sendJSON(type: .videoConfig, value: value) }
        capture.onVideo = { [weak channel] data in channel?.send(type: .video, payload: data) ?? false }
        capture.onAudio = { [weak channel] data in channel?.send(type: .audio, payload: data) }
        capture.onFailure = { [weak self, weak capture] error in
            guard let self, let capture, self.engine === capture else { return }
            self.errorMessage = error.localizedDescription
            self.sendFailure(error.localizedDescription)
            self.stopSession(notifyClient: true)
        }
        Task { @MainActor in
            do {
                try await capture.start(displayID: selected, options: options)
                guard self.engine === capture, self.client === channel else { await capture.stop(); return }
                self.sessionStarting = false
                self.streaming = true
                self.status = "Streaming to \(self.clientName ?? "iPhone")"
            } catch {
                guard self.engine === capture else { return }
                self.errorMessage = error.localizedDescription
                self.sendFailure(error.localizedDescription)
                self.stopSession(notifyClient: true)
            }
        }
    }

    private func sendWelcome() {
        guard clientDidHello else { return }
        client?.sendJSON(type: .welcome, value: RPWelcome(hostName: hostName, controlAvailable: controlsAvailable))
    }

    private func sendFailure(_ message: String) {
        client?.sendJSON(type: .failure, value: RPErrorMessage(message: String(message.prefix(2_048))))
    }

    private func disconnectClient(message: String?) {
        automaticPairing.cancelPending()
        handshakeDeadline?.cancel()
        handshakeDeadline = nil
        input.releaseAll()
        stopSession(notifyClient: false)
        client?.cancel()
        client = nil
        clientDidHello = false
        clientName = nil
        if let message { errorMessage = message }
        status = listenerReady ? "Ready for iPhone" : "Host is stopped"
    }

    private func startAutomaticPairing(generation: UUID, serviceName: String) {
        automaticPairing.onListenerState = { [weak self] state in
            guard let self, self.listenerID == generation, self.listener != nil else { return }
            switch state {
            case .starting: self.status = "Starting automatic pairing…"
            case .ready:
                self.listenerStarting = false
                if self.client == nil { self.status = "Ready for iPhone" }
            case .waiting(let message): self.status = "Waiting for local pairing: \(message)"
            case .failed(let message):
                self.errorMessage = "Cannot start automatic pairing: \(message)"
                self.stopHost()
            case .stopped: break
            }
        }
        do {
            try automaticPairing.start(serviceName: serviceName, hostName: hostName,
                                       credentialProvider: { [weak self] in self?.secret },
                                       canAcceptRequest: { [weak self] in self?.listenerReady == true && self?.client == nil })
        } catch {
            errorMessage = "Cannot start automatic pairing: \(error.localizedDescription)"
            stopHost()
        }
    }
}

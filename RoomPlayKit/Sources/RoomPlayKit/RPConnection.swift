import Foundation
import Network

public enum RPConnectionState: Equatable {
    case ready
    case failed(String)
    case closed
    case waiting(String)
}

public final class RPConnection {
    public var onMessage: ((RPMessage) -> Void)?
    public var onState: ((RPConnectionState) -> Void)?
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "RoomPlay.Connection", qos: .userInteractive)
    private let callbackQueue: DispatchQueue
    private let lock = NSLock()
    private var bytesInFlight = 0
    private var videoFramesInFlight = 0
    private var ready = false
    private var started = false
    private var terminated = false
    private var receiving = false
    private var parser: RPFrameParser
    private let maxPayload: Int
    public static let maxPendingBytes = RPProtocol.maxPayload * 2 + 10
    public static let maxPendingVideoFrames = 2

    public var pendingBytes: Int {
        lock.lock(); defer { lock.unlock() }
        return bytesInFlight
    }

    public var pendingVideoFrames: Int {
        lock.lock(); defer { lock.unlock() }
        return videoFramesInFlight
    }

    /// Set callbacks before calling start. Both callbacks and send completions are
    /// delivered on callbackQueue, main by default, in connection event order.
    public init(connection: NWConnection, callbackQueue: DispatchQueue = .main,
                maxPayload: Int = RPProtocol.maxPayload) {
        self.connection = connection
        self.callbackQueue = callbackQueue
        self.maxPayload = max(0, min(maxPayload, RPProtocol.maxPayload))
        parser = RPFrameParser(maxPayload: self.maxPayload)
    }

    public func start() {
        lock.lock()
        guard !started && !terminated else { lock.unlock(); return }
        started = true
        lock.unlock()
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.lock.lock()
                guard !self.terminated else { self.lock.unlock(); return }
                self.ready = true
                self.lock.unlock()
                self.deliver(.ready)
                if !self.receiving {
                    self.receiving = true
                    self.receive()
                }
            case .waiting(let error):
                self.lock.lock()
                self.ready = false
                self.lock.unlock()
                self.deliver(.waiting(error.localizedDescription))
            case .failed(let error): self.finish(.failed(error.localizedDescription))
            case .cancelled: self.finish(.closed)
            default: break
            }
        }
        connection.start(queue: queue)
    }

    /// False means the packet was not accepted. The sender must skip source video
    /// frames before encoding when pendingVideoFrames reaches two; it must never
    /// silently drop an already encoded reference frame and continue its GOP.
    @discardableResult
    public func send(type: RPMessageType, payload: Data = Data(), completion: ((Error?) -> Void)? = nil) -> Bool {
        guard payload.count <= maxPayload else {
            complete(completion, error: RPTransportError.oversizedPayload)
            return false
        }
        let frame: Data
        do { frame = try RPFraming.encode(RPMessage(type: type, payload: payload)) }
        catch { complete(completion, error: error); return false }
        lock.lock()
        guard ready && !terminated else {
            lock.unlock(); complete(completion, error: RPTransportError.notConnected); return false
        }
        guard bytesInFlight <= Self.maxPendingBytes - frame.count,
              type != .video || videoFramesInFlight < Self.maxPendingVideoFrames else {
            lock.unlock(); complete(completion, error: RPTransportError.backpressure); return false
        }
        bytesInFlight += frame.count
        if type == .video { videoFramesInFlight += 1 }
        lock.unlock()
        queue.async { [self] in
            lock.lock()
            let canSend = !terminated
            lock.unlock()
            guard canSend else {
                releaseReservation(bytes: frame.count, video: type == .video)
                complete(completion, error: RPTransportError.notConnected)
                return
            }
            connection.send(content: frame, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                self.releaseReservation(bytes: frame.count, video: type == .video)
                self.complete(completion, error: error)
                if let error { self.finish(.failed(error.localizedDescription)) }
            })
        }
        return true
    }

    @discardableResult
    public func sendJSON<T: Encodable>(type: RPMessageType, value: T, completion: ((Error?) -> Void)? = nil) -> Bool {
        do { return send(type: type, payload: try JSONEncoder().encode(value), completion: completion) }
        catch { complete(completion, error: error); return false }
    }

    public func cancel() {
        queue.async { [weak self] in self?.finish(.closed) }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: min(65_536, maxPayload + 5)) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            self.lock.lock()
            let stillActive = !self.terminated
            self.lock.unlock()
            guard stillActive else { return }
            if let data, !data.isEmpty {
                do {
                    let messages = try self.parser.append(data)
                    self.callbackQueue.async { [weak self] in
                        guard let self else { return }
                        for message in messages { self.onMessage?(message) }
                        // Consume only one bounded read batch at a time. Resuming
                        // after the renderer/input callbacks prevents a busy main
                        // thread from accumulating an unbounded media backlog.
                        self.queue.async { [weak self] in
                            self?.continueReceiving(isComplete: isComplete, error: error)
                        }
                    }
                    return
                } catch {
                    self.finish(.failed(error.localizedDescription))
                    return
                }
            }
            self.continueReceiving(isComplete: isComplete, error: error)
        }
    }

    private func continueReceiving(isComplete: Bool, error: NWError?) {
        lock.lock()
        let stillActive = !terminated
        lock.unlock()
        guard stillActive else { return }
        if let error { finish(.failed(error.localizedDescription)); return }
        if isComplete {
            do { try parser.finish(); finish(.closed) }
            catch { finish(.failed(error.localizedDescription)) }
        } else { receive() }
    }

    private func releaseReservation(bytes: Int, video: Bool) {
        lock.lock()
        bytesInFlight = max(0, bytesInFlight - bytes)
        if video { videoFramesInFlight = max(0, videoFramesInFlight - 1) }
        lock.unlock()
    }

    private func finish(_ state: RPConnectionState) {
        lock.lock()
        guard !terminated else { lock.unlock(); return }
        terminated = true
        ready = false
        lock.unlock()
        connection.cancel()
        deliver(state)
    }

    private func deliver(_ state: RPConnectionState) {
        callbackQueue.async { [weak self] in self?.onState?(state) }
    }

    private func complete(_ completion: ((Error?) -> Void)?, error: Error?) {
        guard let completion else { return }
        callbackQueue.async { completion(error) }
    }

    deinit { connection.cancel() }
}

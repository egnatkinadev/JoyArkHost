import Foundation

struct HostPairingRequest: Identifiable, Equatable {
    let id: UUID
    let clientName: String
    let verificationCode: String
}

/// Main-thread admission and approval state, separated from sockets and Keychain
/// so cancellation, stale approvals and attempt limits can be tested safely.
struct HostPairingGate {
    enum Phase: Equatable { case negotiating, awaitingApproval, deliveringCredential }
    private(set) var currentID: UUID?
    private(set) var phase: Phase?
    private var attempts = [Date]()

    mutating func begin(now: Date = Date()) -> UUID? {
        attempts.removeAll { now.timeIntervalSince($0) >= 60 }
        guard currentID == nil, attempts.count < 5,
              attempts.last.map({ now.timeIntervalSince($0) >= 3 }) ?? true else { return nil }
        let id = UUID()
        attempts.append(now)
        currentID = id
        phase = .negotiating
        return id
    }

    @discardableResult mutating func verified(_ id: UUID) -> Bool {
        guard currentID == id, phase == .negotiating else { return false }
        phase = .awaitingApproval
        return true
    }

    @discardableResult mutating func approve(_ id: UUID) -> Bool {
        guard currentID == id, phase == .awaitingApproval else { return false }
        phase = .deliveringCredential
        return true
    }

    @discardableResult mutating func finish(_ id: UUID) -> Bool {
        guard currentID == id else { return false }
        currentID = nil
        phase = nil
        return true
    }
}

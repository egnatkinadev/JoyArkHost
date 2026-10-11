import XCTest
@testable import RoomPlayHost

final class HostPairingGateTests: XCTestCase {
    func testApprovalRequiresVerifiedCurrentSession() throws {
        var gate = HostPairingGate()
        let id = try XCTUnwrap(gate.begin())
        XCTAssertFalse(gate.approve(id))
        XCTAssertTrue(gate.verified(id))
        XCTAssertTrue(gate.approve(id))
        XCTAssertEqual(gate.phase, .deliveringCredential)
        XCTAssertFalse(gate.approve(id))
    }

    func testOnlyOnePendingPhoneIsAccepted() throws {
        var gate = HostPairingGate()
        let time = Date(timeIntervalSince1970: 100)
        _ = try XCTUnwrap(gate.begin(now: time))
        XCTAssertNil(gate.begin(now: time.addingTimeInterval(10)))
    }

    func testCancelledSessionCannotApproveANewerRequest() throws {
        var gate = HostPairingGate()
        let time = Date(timeIntervalSince1970: 100)
        let first = try XCTUnwrap(gate.begin(now: time))
        XCTAssertTrue(gate.verified(first))
        XCTAssertTrue(gate.finish(first))
        let second = try XCTUnwrap(gate.begin(now: time.addingTimeInterval(4)))
        XCTAssertFalse(gate.approve(first))
        XCTAssertFalse(gate.finish(first))
        XCTAssertEqual(gate.currentID, second)
        XCTAssertTrue(gate.verified(second))
        XCTAssertTrue(gate.approve(second))
    }

    func testAttemptRateLimitResetsAfterAFullMinute() throws {
        var gate = HostPairingGate()
        let time = Date(timeIntervalSince1970: 100)
        for index in 0..<5 {
            let id = try XCTUnwrap(gate.begin(now: time.addingTimeInterval(Double(index * 4))))
            XCTAssertTrue(gate.finish(id))
        }
        XCTAssertNil(gate.begin(now: time.addingTimeInterval(20)))
        XCTAssertNotNil(gate.begin(now: time.addingTimeInterval(61)))
    }

    func testImmediateRetriesAreThrottled() throws {
        var gate = HostPairingGate()
        let time = Date(timeIntervalSince1970: 100)
        let id = try XCTUnwrap(gate.begin(now: time))
        XCTAssertTrue(gate.finish(id))
        XCTAssertNil(gate.begin(now: time.addingTimeInterval(2)))
        XCTAssertNotNil(gate.begin(now: time.addingTimeInterval(3)))
    }
}

import XCTest
import CoreGraphics
@testable import RoomPlayHost

final class InputEventTests: XCTestCase {
    func testRelativeMovementSurvivesCursorClamping() throws {
        let event = try XCTUnwrap(InputInjector.makeMoveEvent(current: CGPoint(x: 999, y: 1), x: 25, y: -10,
                                                            bounds: CGRect(x: 0, y: 0, width: 1000, height: 800),
                                                            heldButtons: [], flags: []))
        XCTAssertEqual(event.location, CGPoint(x: 999, y: 0))
        XCTAssertEqual(event.getIntegerValueField(.mouseEventDeltaX), 25)
        XCTAssertEqual(event.getIntegerValueField(.mouseEventDeltaY), -10)
        XCTAssertEqual(event.type, .mouseMoved)
    }

    func testHeldRightButtonProducesRightDrag() throws {
        let event = try XCTUnwrap(InputInjector.makeMoveEvent(current: CGPoint(x: 10, y: 10), x: 5, y: 5,
                                                            bounds: CGRect(x: 0, y: 0, width: 1000, height: 800),
                                                            heldButtons: [1], flags: .maskShift))
        XCTAssertEqual(event.type, .rightMouseDragged)
        XCTAssertTrue(event.flags.contains(.maskShift))
    }

    func testRejectsInvalidOrUnboundedMovement() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
        XCTAssertNil(InputInjector.makeMoveEvent(current: .zero, x: .infinity, y: 0, bounds: bounds, heldButtons: [], flags: []))
        XCTAssertNil(InputInjector.makeMoveEvent(current: .zero, x: 5_000, y: 0, bounds: bounds, heldButtons: [], flags: []))
    }
}

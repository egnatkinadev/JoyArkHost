import XCTest
@testable import RoomPlayHost

final class CaptureDimensionsTests: XCTestCase {
    func testRetinaDisplayFits1080pWithoutChangingAspect() {
        let value = CaptureDimensions.fitting(displayWidth: 3024, displayHeight: 1964, maximumWidth: 1920, maximumHeight: 1080)
        XCTAssertEqual(value.height, 1080)
        XCTAssertEqual(value.width % 2, 0)
        XCTAssertLessThanOrEqual(value.width, 1920)
        XCTAssertEqual(Double(value.width) / Double(value.height), 3024.0 / 1964.0, accuracy: 0.002)
    }

    func testUltrawideDisplayPreservesLetterboxAspect() {
        let value = CaptureDimensions.fitting(displayWidth: 5120, displayHeight: 1440, maximumWidth: 1920, maximumHeight: 1080)
        XCTAssertEqual(value, CaptureDimensions(width: 1920, height: 540))
    }

    func testDoesNotUpscaleSmallDisplay() {
        let value = CaptureDimensions.fitting(displayWidth: 800, displayHeight: 600, maximumWidth: 1920, maximumHeight: 1080)
        XCTAssertEqual(value, CaptureDimensions(width: 800, height: 600))
    }
}

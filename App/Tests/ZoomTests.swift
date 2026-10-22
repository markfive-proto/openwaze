@testable import OpenWaze
import XCTest

final class ZoomTests: XCTestCase {
    func testAccurateFixZoomsAllTheWayIn() {
        XCTAssertEqual(Zoom.level(forAccuracy: 5), Zoom.max)
        XCTAssertEqual(Zoom.level(forAccuracy: 10), Zoom.max)
    }

    func testEachDoublingOfErrorZoomsOutOneStep() {
        XCTAssertEqual(Zoom.level(forAccuracy: 20), Zoom.max - 1, accuracy: 1e-9)
        XCTAssertEqual(Zoom.level(forAccuracy: 80), Zoom.max - 3, accuracy: 1e-9)
    }

    func testInvalidOrHugeAccuracyFallsBackToMinimum() {
        XCTAssertEqual(Zoom.level(forAccuracy: -1), Zoom.min)
        XCTAssertEqual(Zoom.level(forAccuracy: .infinity), Zoom.min)
        XCTAssertEqual(Zoom.level(forAccuracy: 10_000_000), Zoom.min)
    }
}

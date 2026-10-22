import CoreLocation
@testable import OpenWaze
import XCTest

final class ZoomTests: XCTestCase {
    func testAccurateFixZoomsAllTheWayIn() {
        XCTAssertEqual(Zoom.level(forAccuracy: 0), Zoom.max)
        XCTAssertEqual(Zoom.level(forAccuracy: 5), Zoom.max)
        XCTAssertEqual(Zoom.level(forAccuracy: 10), Zoom.max)
    }

    func testEachDoublingOfErrorZoomsOutOneStep() {
        XCTAssertEqual(Zoom.level(forAccuracy: 20), Zoom.max - 1, accuracy: 1e-9)
        XCTAssertEqual(Zoom.level(forAccuracy: 80), Zoom.max - 3, accuracy: 1e-9)
    }

    func testInvalidOrHugeAccuracyFallsBackToMinimum() {
        XCTAssertEqual(Zoom.level(forAccuracy: -1), Zoom.min)
        XCTAssertEqual(Zoom.level(forAccuracy: .nan), Zoom.min)
        XCTAssertEqual(Zoom.level(forAccuracy: .infinity), Zoom.min)
        XCTAssertEqual(Zoom.level(forAccuracy: 10_000_000), Zoom.min)
    }

    func testFirstFixGate() {
        let now = Date()
        func fix(accuracy: CLLocationAccuracy, age: TimeInterval) -> CLLocation {
            CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: 1.28, longitude: 103.86),
                altitude: 0, horizontalAccuracy: accuracy, verticalAccuracy: -1,
                timestamp: now.addingTimeInterval(-age)
            )
        }
        XCTAssertTrue(Zoom.isUsableFirstFix(fix(accuracy: 0, age: 0), now: now))
        XCTAssertTrue(Zoom.isUsableFirstFix(fix(accuracy: 500, age: 10), now: now))
        XCTAssertFalse(Zoom.isUsableFirstFix(fix(accuracy: 501, age: 0), now: now))
        XCTAssertFalse(Zoom.isUsableFirstFix(fix(accuracy: -1, age: 0), now: now))
        XCTAssertFalse(Zoom.isUsableFirstFix(fix(accuracy: 10, age: 10.1), now: now))
    }
}

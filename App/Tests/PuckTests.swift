@testable import OpenWaze
import XCTest

final class PuckTests: XCTestCase {
    func testApproximateFixFallsBackToDot() {
        XCTAssertTrue(Puck.showsCar(accuracy: 0))
        XCTAssertTrue(Puck.showsCar(accuracy: 5))
        XCTAssertTrue(Puck.showsCar(accuracy: Puck.maxCarAccuracy))
        XCTAssertFalse(Puck.showsCar(accuracy: Puck.maxCarAccuracy + 0.1))
        XCTAssertFalse(Puck.showsCar(accuracy: 3000)) // approximate-location authorisation
        XCTAssertFalse(Puck.showsCar(accuracy: -1)) // unknown
        XCTAssertFalse(Puck.showsCar(accuracy: .nan))
    }

    func testDrivingUsesCourse() {
        XCTAssertEqual(Puck.angle(course: 90, speed: 12, heading: 180, previous: 0), 90)
        XCTAssertEqual(Puck.angle(course: 90, speed: Puck.minCourseSpeed, heading: 180, previous: 0), 90)
    }

    func testStationaryUsesHeading() {
        XCTAssertEqual(Puck.angle(course: 90, speed: 0, heading: 180, previous: 0), 180)
        XCTAssertEqual(Puck.angle(course: 90, speed: 0.9, heading: 180, previous: 0), 180)
        // A moving fix with no course is as good as stationary.
        XCTAssertEqual(Puck.angle(course: -1, speed: 12, heading: 180, previous: 0), 180)
    }

    func testNoCourseOrHeadingKeepsLastAngle() {
        XCTAssertEqual(Puck.angle(course: -1, speed: 0, heading: nil, previous: 45), 45)
        XCTAssertEqual(Puck.angle(course: -1, speed: 0, heading: -1, previous: 45), 45)
    }

    func testTurnGoesTheShortWayRound() {
        XCTAssertEqual(Puck.turn(from: 350, to: 10), 370)
        XCTAssertEqual(Puck.turn(from: 10, to: 350), -10)
        XCTAssertEqual(Puck.turn(from: 0, to: 180), 180)
        XCTAssertEqual(Puck.turn(from: 0, to: 181), -179)
        XCTAssertEqual(Puck.turn(from: 730, to: 20), 740) // stays unwrapped across many turns
        XCTAssertEqual(Puck.turn(from: 90, to: 90), 90)
    }

    func testReduceMotionSnapsInsteadOfSmoothing() {
        XCTAssertEqual(Puck.turnDuration(reduceMotion: true), 0)
        XCTAssertGreaterThan(Puck.turnDuration(reduceMotion: false), 0)
    }
}

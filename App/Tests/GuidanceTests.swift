import CoreLocation
@testable import OpenWaze
import XCTest

final class GuidanceTests: XCTestCase {
    // An L: ~1 km north, right turn, ~1 km east. 0.009 deg of latitude is ~1001 m.
    static let start = CLLocationCoordinate2D(latitude: 3.000, longitude: 101.700)
    static let corner = CLLocationCoordinate2D(latitude: 3.009, longitude: 101.700)
    static let end = CLLocationCoordinate2D(latitude: 3.009, longitude: 101.709)

    let route = Route(
        coordinates: [start, corner, end],
        steps: [
            Route.Step(type: "depart", latitude: 3.000, longitude: 101.700, distance: 1000, duration: 100),
            Route.Step(type: "turn", modifier: "right", latitude: 3.009, longitude: 101.700,
                       distance: 1000, duration: 100),
            Route.Step(type: "arrive", latitude: 3.009, longitude: 101.709),
        ],
        distance: 2000, duration: 200
    )

    func point(north: Double, east: Double = 0) -> CLLocationCoordinate2D {
        let degree = Geo.earthRadius * .pi / 180
        return CLLocationCoordinate2D(
            latitude: Self.start.latitude + north / degree,
            longitude: Self.start.longitude + east / (degree * cos(Self.start.latitude * .pi / 180))
        )
    }

    func testDistanceToPolyline() throws {
        let line = route.coordinates
        XCTAssertEqual(try XCTUnwrap(Geo.project(point(north: 500), onto: line)).distance, 0, accuracy: 0.01)
        let beside = try XCTUnwrap(Geo.project(point(north: 500, east: 30), onto: line))
        XCTAssertEqual(beside.distance, 30, accuracy: 0.1)
        XCTAssertEqual(beside.segment, 0)
        XCTAssertEqual(beside.fraction, 0.5, accuracy: 0.01)
        // Behind the start: distance to the endpoint, not the infinite line.
        XCTAssertEqual(try XCTUnwrap(Geo.project(point(north: -40), onto: line)).distance, 40, accuracy: 0.1)
        XCTAssertNil(Geo.project(point(north: 0), onto: [Self.start]))
    }

    func testProjectionNeverGoesBackPastTheHint() throws {
        // Near the start, but told we're already on the second segment.
        let match = try XCTUnwrap(Geo.project(point(north: 10), onto: route.coordinates, from: 1))
        XCTAssertEqual(match.segment, 1)
    }

    func testStepProgression() throws {
        let early = try XCTUnwrap(Guidance.progress(on: route, at: point(north: 200)))
        XCTAssertEqual(early.nextStep, 1)
        XCTAssertEqual(early.distanceToManeuver, 801, accuracy: 1)
        XCTAssertEqual(early.remainingDistance, 1801, accuracy: 2)
        XCTAssertEqual(early.remainingDuration, 180, accuracy: 0.5) // 80 s of depart + 100 s after the turn

        let turned = point(north: 1001, east: 300)
        let afterTurn = try XCTUnwrap(Guidance.progress(on: route, at: turned, from: early.segment))
        XCTAssertEqual(afterTurn.nextStep, 2)
        XCTAssertEqual(afterTurn.segment, 1)
        XCTAssertEqual(afterTurn.distanceToManeuver, 700, accuracy: 2)
        XCTAssertEqual(afterTurn.remainingDuration, 70, accuracy: 0.5)
        XCTAssertFalse(Guidance.hasArrived(afterTurn))

        let there = try XCTUnwrap(Guidance.progress(on: route, at: Self.end, from: afterTurn.segment))
        XCTAssertEqual(there.nextStep, 2)
        XCTAssertTrue(Guidance.hasArrived(there))
    }

    func testOffRouteNeedsDistanceAndTime() {
        var timer = Guidance.OffRouteTimer()
        let start = Date()
        XCTAssertFalse(timer.update(offRouteBy: 80, at: start))
        XCTAssertFalse(timer.update(offRouteBy: 80, at: start + 4.9))
        XCTAssertTrue(timer.update(offRouteBy: 80, at: start + 5))
        // Back on route resets; a GPS blip must not reroute.
        XCTAssertFalse(timer.update(offRouteBy: 20, at: start + 6))
        XCTAssertFalse(timer.update(offRouteBy: 51, at: start + 7))
        XCTAssertFalse(timer.update(offRouteBy: 50, at: start + 13)) // 50 m is still on route
        XCTAssertFalse(timer.update(offRouteBy: 60, at: start + 14))
        timer.reset()
        XCTAssertFalse(timer.update(offRouteBy: 60, at: start + 20))
    }

    func testProjectionWindowAndBounds() throws {
        // Near the start, but the window only covers the second segment.
        let ahead = try XCTUnwrap(Geo.project(point(north: 10), onto: route.coordinates, from: 1, to: 1))
        XCTAssertEqual(ahead.segment, 1)
        // A hint past the last segment is clamped, not a crash.
        XCTAssertEqual(try XCTUnwrap(Geo.project(point(north: 10), onto: route.coordinates, from: 9)).segment, 1)
    }

    func testProgressDoesNotJumpToALaterPassOfTheSameRoad() throws {
        // Out 3 km north, U-turn, back south on the other carriageway 10 m east.
        let north = point(north: 3000)
        let back = point(north: 0, east: 10)
        let outAndBack = Route(
            coordinates: [Self.start, point(north: 1500), north, point(north: 1500, east: 10), back],
            steps: [
                Route.Step(type: "depart", latitude: Self.start.latitude, longitude: Self.start.longitude,
                           distance: 3000, duration: 300),
                Route.Step(type: "turn", modifier: "uturn", latitude: north.latitude, longitude: north.longitude,
                           distance: 3000, duration: 300),
                Route.Step(type: "arrive", latitude: back.latitude, longitude: back.longitude),
            ],
            distance: 6000, duration: 600
        )
        XCTAssertEqual(outAndBack.stepStart[2], outAndBack.along[4], "arrive matched after the U-turn")
        // 100 m in on the way out, drifting east: the return pass is nearer, but 5.8 km ahead.
        let out = try XCTUnwrap(Guidance.progress(on: outAndBack, at: point(north: 100, east: 8)))
        XCTAssertEqual(out.segment, 0)
        XCTAssertEqual(out.nextStep, 1)
        XCTAssertFalse(Guidance.hasArrived(out))
    }

    func testZeroLengthStepDoesNotHideTheTurn() throws {
        // A rename with no length sits on the corner, right before the turn.
        let renamed = Route(
            coordinates: route.coordinates,
            steps: [
                route.steps[0],
                Route.Step(type: "new name", modifier: "straight", latitude: 3.009, longitude: 101.700),
                route.steps[1],
                route.steps[2],
            ],
            distance: 2000, duration: 200
        )
        XCTAssertEqual(renamed.stepStart[1], renamed.stepStart[2])
        let early = try XCTUnwrap(Guidance.progress(on: renamed, at: point(north: 200)))
        XCTAssertEqual(early.nextStep, 2)
        XCTAssertEqual(renamed.steps[early.nextStep].modifier, "right")
        XCTAssertEqual(early.distanceToManeuver, 801, accuracy: 1)
        XCTAssertEqual(early.remainingDuration, 180, accuracy: 0.5)
    }

    func testArrivalNeedsToBeOnTheRoad() throws {
        // 80 m north of the end, on a parallel street.
        let parallel = CLLocationCoordinate2D(latitude: Self.end.latitude + 80 / 111_195, longitude: Self.end.longitude)
        let progress = try XCTUnwrap(Guidance.progress(on: route, at: parallel, from: 1))
        XCTAssertLessThanOrEqual(progress.remainingDistance, Guidance.arrivalDistance)
        XCTAssertFalse(Guidance.hasArrived(progress))
    }

    func testAnnouncementsFireOncePerTier() {
        func progress(_ step: Int, _ distance: Double) -> RouteProgress {
            RouteProgress(segment: 0, nextStep: step, distanceToManeuver: distance,
                          remainingDistance: 5000, remainingDuration: 0, offRouteBy: 0)
        }
        var spoken: Set<Guidance.Announcement> = []
        func tick(_ step: Int, _ distance: Double, speed: Double = 10) -> Int? {
            let due = Guidance.due(progress(step, distance), speed: speed, spoken: spoken)
            guard let due else { return nil }
            spoken.formUnion(Guidance.markSpoken(due))
            return due.tier
        }
        XCTAssertNil(tick(1, 900))
        XCTAssertEqual(tick(1, 498), 0)
        XCTAssertNil(tick(1, 400))
        XCTAssertEqual(tick(1, 45), 1)
        XCTAssertNil(tick(1, 10))
        // Next maneuver starts fresh; arriving already close skips the early prompt.
        XCTAssertEqual(tick(2, 30), 1)
        XCTAssertNil(tick(2, 450))
        // At 30 m/s (108 km/h) prompts come earlier: 600 m and 75 m out.
        XCTAssertEqual(tick(3, 590, speed: 30), 0)
        XCTAssertEqual(tick(3, 70, speed: 30), 1)
    }

    func testPromptDistancesScaleWithSpeed() {
        XCTAssertEqual(Guidance.announceAt(speed: 0), [500, 50])
        XCTAssertEqual(Guidance.announceAt(speed: -1), [500, 50]) // invalid speed
        XCTAssertEqual(Guidance.announceAt(speed: 30), [600, 75])
    }

    func testRerouteBackoff() {
        XCTAssertEqual((1 ... 6).map(Guidance.retryDelay(after:)), [5, 10, 20, 40, 60, 60])
    }
}

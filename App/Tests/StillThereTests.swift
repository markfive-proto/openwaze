import CoreLocation
@testable import OpenWaze
import XCTest

final class StillThereTests: XCTestCase {
    static let metresPerDegree = Geo.earthRadius * .pi / 180
    static let origin = CLLocationCoordinate2D(latitude: 3.0, longitude: 101.7)

    /// 1 km due north in 100 m segments.
    let route = Route(
        coordinates: (0 ... 10).map { StillThereTests.point(north: Double($0) * 100) },
        steps: [], distance: 1000, duration: 100
    )

    static func point(north: Double, east: Double = 0) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: origin.latitude + north / metresPerDegree,
            longitude: origin.longitude + east / (metresPerDegree * cos(origin.latitude * .pi / 180))
        )
    }

    func report(_ id: String, north: Double, east: Double = 0) -> Report {
        let spot = Self.point(north: north, east: east)
        return Report(
            id: id, type: .hazard, lat: spot.latitude, lng: spot.longitude,
            createdAt: .distantPast, expiresAt: .distantFuture, upvotes: 0, downvotes: 0
        )
    }

    /// Driver 250 m along the route.
    var progress: RouteProgress {
        RouteProgress(
            segment: 2, nextStep: 0, distanceToManeuver: 0,
            remainingDistance: route.along.last! - 250, remainingDuration: 0, offRouteBy: 0
        )
    }

    func ahead(_ reports: [Report]) -> String? {
        StillThere.nextAhead(on: route, at: progress, reports: reports)?.id
    }

    func testPicksClosestReportAheadOnRoute() {
        XCTAssertEqual(ahead([report("far", north: 500), report("near", north: 400)]), "near")
        XCTAssertEqual(ahead([report("edge", north: 549)]), "edge")
    }

    func testIgnoresReportsBehind() {
        XCTAssertNil(ahead([report("behind", north: 200), report("way-behind", north: 0)]))
        XCTAssertEqual(ahead([report("behind", north: 240), report("ahead", north: 300)]), "ahead")
    }

    func testIgnoresReportsBeyond300m() {
        XCTAssertNil(ahead([report("beyond", north: 560), report("end", north: 1000)]))
    }

    func testLateralTolerance() {
        XCTAssertEqual(ahead([report("shoulder", north: 350, east: 20)]), "shoulder")
        XCTAssertNil(ahead([report("side-street", north: 350, east: 60)]))
    }

    func testNothingOnAnEmptyRouteOrList() {
        XCTAssertNil(ahead([]))
        let empty = Route(coordinates: [], steps: [], distance: 0, duration: 0)
        XCTAssertNil(StillThere.nextAhead(on: empty, at: progress, reports: [report("x", north: 300)]))
    }

    func testAsksOncePerReportPerTrip() {
        let reports = [report("a", north: 300), report("b", north: 400)]
        var trip = StillThere()
        XCTAssertEqual(trip.next(on: route, at: progress, reports: reports)?.id, "a")
        XCTAssertEqual(trip.next(on: route, at: progress, reports: reports)?.id, "b")
        XCTAssertNil(trip.next(on: route, at: progress, reports: reports))
        XCTAssertEqual(trip.asked, ["a", "b"])

        var nextTrip = StillThere()
        XCTAssertEqual(nextTrip.next(on: route, at: progress, reports: reports)?.id, "a")
    }
}

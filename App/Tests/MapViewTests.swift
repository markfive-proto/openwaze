import CoreLocation
@testable import OpenWaze
import XCTest

final class MapViewTests: XCTestCase {
    let klcc = CLLocationCoordinate2D(latitude: 3.1579, longitude: 101.7116)
    let pavilion = CLLocationCoordinate2D(latitude: 3.1488, longitude: 101.7133)

    func route(endingAt end: CLLocationCoordinate2D) -> Route {
        Route(coordinates: [klcc, end], steps: [], distance: 1000, duration: 100)
    }

    /// Metres north of `point`.
    func north(of point: CLLocationCoordinate2D, metres: Double) -> CLLocationCoordinate2D {
        let degrees = metres / Geo.earthRadius * 180 / .pi
        return CLLocationCoordinate2D(latitude: point.latitude + degrees, longitude: point.longitude)
    }

    func testJoinsRouteEndToDestination() throws {
        let end = north(of: pavilion, metres: 56) // where OSRM snaps Pavilion KL
        let line = try XCTUnwrap(MapView.connector(route: route(endingAt: end), to: pavilion))
        XCTAssertEqual(line.count, 2)
        XCTAssertEqual(line[0].latitude, end.latitude)
        XCTAssertEqual(line[0].longitude, end.longitude)
        XCTAssertEqual(line[1].latitude, pavilion.latitude)
        XCTAssertEqual(line[1].longitude, pavilion.longitude)
    }

    func testNoConnectorForTinyGap() {
        XCTAssertNil(MapView.connector(route: route(endingAt: pavilion), to: pavilion))
        XCTAssertNil(MapView.connector(route: route(endingAt: north(of: pavilion, metres: 4.9)), to: pavilion))
        XCTAssertNotNil(MapView.connector(route: route(endingAt: north(of: pavilion, metres: 5.1)), to: pavilion))
    }

    func testNoConnectorWithoutRouteOrDestination() {
        XCTAssertNil(MapView.connector(route: nil, to: pavilion))
        XCTAssertNil(MapView.connector(route: route(endingAt: klcc), to: nil))
        let empty = Route(coordinates: [], steps: [], distance: 0, duration: 0)
        XCTAssertNil(MapView.connector(route: empty, to: pavilion))
    }
}

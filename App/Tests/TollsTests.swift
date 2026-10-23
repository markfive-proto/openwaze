import CoreLocation
@testable import OpenWaze
import XCTest

final class TollsTests: XCTestCase {
    // Putrajaya toll plaza, southbound booth node (OSM n6477385198), on the
    // KLCC to KLIA route. Its northbound twin is about 45 m west.
    let southbound = TollPlaza(id: 6_477_385_198, name: "Plaza Tol Putrajaya", lat: 2.950_091, lng: 101.651_890)
    let northbound = TollPlaza(id: 6_477_385_199, name: "Plaza Tol Putrajaya", lat: 2.950_109, lng: 101.651_485)

    /// A straight north-south line through the southbound node.
    func line(through plaza: TollPlaza, metres: Double = 300) -> Geo.Line {
        let deg = metres / 111_000
        return [
            CLLocationCoordinate2D(latitude: plaza.lat + deg, longitude: plaza.lng),
            CLLocationCoordinate2D(latitude: plaza.lat, longitude: plaza.lng),
            CLLocationCoordinate2D(latitude: plaza.lat - deg, longitude: plaza.lng),
        ]
    }

    func testMatchesPlazaOnTheRouteButNotTheOppositeCarriageway() {
        let route = line(through: southbound)
        XCTAssertEqual(Tolls.plazas(on: route, in: [northbound, southbound]), [southbound])
    }

    func testThresholdBoundary() {
        // A node can sit a few metres off the way: just inside the threshold counts, just outside does not.
        let route = line(through: southbound)
        let deg = 1 / 111_000.0
        let lat = southbound.lat
        let inside = TollPlaza(id: 1, name: "in", lat: lat, lng: southbound.lng + (Tolls.threshold - 1) * deg)
        let outside = TollPlaza(id: 2, name: "out", lat: lat, lng: southbound.lng + (Tolls.threshold + 1) * deg)
        XCTAssertEqual(Tolls.plazas(on: route, in: [outside, inside]), [inside])
    }

    func testParallelRoadDoesNotMatch() {
        // Same heading, 20 m to the side.
        let shifted = TollPlaza(id: 3, name: "side", lat: southbound.lat, lng: southbound.lng + 20 / 111_000)
        XCTAssertEqual(Tolls.plazas(on: line(through: shifted), in: [southbound]), [])
    }

    func testPlazasComeBackInRouteOrder() {
        let first = TollPlaza(id: 1, name: "first", lat: 3.0, lng: 101.0)
        let second = TollPlaza(id: 2, name: "second", lat: 3.0, lng: 101.01)
        let route = [first.coordinate, CLLocationCoordinate2D(latitude: 3.0, longitude: 101.005), second.coordinate]
        XCTAssertEqual(Tolls.plazas(on: route, in: [second, first]).map(\.id), [1, 2])
    }

    func testEmptyAndSinglePointRoutes() {
        XCTAssertEqual(Tolls.plazas(on: [], in: [southbound]), [])
        XCTAssertEqual(Tolls.plazas(on: [southbound.coordinate], in: [southbound]), [])
    }

    func testRealRouteThroughPutrajayaMatchesBundledPlaza() {
        // OSRM demo geometry (KLCC to KLIA, 2026-10-23) around the Putrajaya plaza.
        let vertices: [(Double, Double)] = [
            (101.651842, 2.953041), (101.651855, 2.952112), (101.651874, 2.951645), (101.651903, 2.95067),
            (101.65189, 2.950091), (101.651852, 2.949579), (101.651856, 2.949232), (101.651798, 2.948347),
        ]
        let route = vertices.map { CLLocationCoordinate2D(latitude: $0.1, longitude: $0.0) }
        XCTAssertEqual(Tolls.plazas(on: route).map(\.id), [6_477_385_198])
    }

    func testBundledDatasetLoads() throws {
        let plazas = Tolls.bundled
        XCTAssertGreaterThan(plazas.count, 400)
        let klia = try XCTUnwrap(plazas.first { $0.name == "Plaza Tol KLIA" })
        XCTAssertEqual(klia.lat, 2.83, accuracy: 0.01)
        XCTAssertEqual(klia.lng, 101.66, accuracy: 0.01)
        XCTAssertEqual(Set(plazas.map(\.id)).count, plazas.count, "ids are unique")
    }
}

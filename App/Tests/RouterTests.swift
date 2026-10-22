import CoreLocation
@testable import OpenWaze
import XCTest

final class RouterTests: XCTestCase {
    /// Trimmed real OSRM response (Petaling Jaya), plus a malformed point
    /// and a step without a maneuver location, both of which are skipped.
    let fixture = Data("""
    {"code": "Ok", "routes": [{
      "distance": 3216.4, "duration": 290.1,
      "geometry": {"type": "LineString", "coordinates": [
        [101.640633, 3.103637], [101.640457, 3.104263], [7], [101.640123, 3.105105], [101.639508, 3.106207]]},
      "legs": [{"steps": [
        {"maneuver": {"type": "depart", "location": [101.640633, 3.103637]},
         "name": "", "distance": 70.4, "duration": 9.6},
        {"maneuver": {"type": "turn", "modifier": "left", "location": [101.640457, 3.104263]},
         "name": "Lorong Utara C", "distance": 100.2, "duration": 12.1},
        {"maneuver": {"type": "turn", "modifier": "right"}, "name": "No location"},
        {"maneuver": {"type": "roundabout turn", "modifier": "right", "location": [101.640123, 3.105105]},
         "name": "Lorong Utara C", "destinations": "SS2", "distance": 140.0, "duration": 20.0},
        {"maneuver": {"type": "arrive", "modifier": "right", "location": [101.639508, 3.106207]},
         "name": "", "distance": 0, "duration": 0}
      ]}]
    }]}
    """.utf8)

    func testParsesRouteAndSkipsBadPointsAndSteps() throws {
        let route = try Router.parse(fixture)
        XCTAssertEqual(route.coordinates.count, 4)
        XCTAssertEqual(route.coordinates[0].latitude, 3.103637)
        XCTAssertEqual(route.coordinates[0].longitude, 101.640633)
        XCTAssertEqual(route.distance, 3216.4)
        XCTAssertEqual(route.duration, 290.1)
        XCTAssertEqual(route.steps.map(\.type), ["depart", "turn", "roundabout turn", "arrive"])
        XCTAssertEqual(route.steps[1], Route.Step(
            type: "turn", modifier: "left", name: "Lorong Utara C",
            latitude: 3.104263, longitude: 101.640457, distance: 100.2, duration: 12.1
        ))
        XCTAssertEqual(route.steps[2].destinations, "SS2")
        // Each maneuver lines up with its vertex along the line.
        XCTAssertEqual(route.stepStart.count, 4)
        XCTAssertEqual(route.stepStart[0], 0)
        XCTAssertEqual(route.stepStart[1], route.along[1])
        XCTAssertEqual(route.stepStart[3], route.along[3])
    }

    func testNoRouteAndMalformedResponses() {
        XCTAssertThrowsError(try Router.parse(Data(#"{"code": "NoRoute", "routes": []}"#.utf8))) {
            XCTAssertEqual($0 as? RouterError, .noRoute(code: "NoRoute"))
        }
        let onePoint = Data(#"{"code": "Ok", "routes": [{"geometry": {"coordinates": [[1, 2]]}}]}"#.utf8)
        XCTAssertThrowsError(try Router.parse(onePoint)) {
            XCTAssertEqual($0 as? RouterError, .noRoute(code: "NoGeometry"))
        }
        XCTAssertThrowsError(try Router.parse(Data("<html>".utf8)))
    }

    func testURLIsLongitudeFirst() {
        let klcc = CLLocationCoordinate2D(latitude: 3.1579, longitude: 101.7116)
        let klia = CLLocationCoordinate2D(latitude: 2.7456, longitude: 101.7072)
        XCTAssertEqual(
            Router.url(from: klcc, to: klia).absoluteString,
            "https://router.project-osrm.org/route/v1/driving/101.7116,3.1579;101.7072,2.7456"
                + "?steps=true&overview=full&geometries=geojson&annotations=false"
        )
    }

    func testRouteSendsUserAgentAndParses() async throws {
        var sent: URLRequest?
        let route = try await Router.route(from: .init(), to: .init()) { request in
            sent = request
            return (self.fixture, Self.response(status: 200))
        }
        XCTAssertEqual(sent?.value(forHTTPHeaderField: "User-Agent"), Photon.userAgent)
        XCTAssertEqual(route.steps.count, 4)
    }

    func testRouteMapsHTTPErrors() async {
        let noRoute = Data(#"{"code": "NoSegment", "message": "Could not find a matching segment"}"#.utf8)
        for (body, status, expected) in [
            (noRoute, 400, RouterError.noRoute(code: "NoSegment")),
            (Data("Too Many Requests".utf8), 429, RouterError.http(status: 429)),
        ] {
            do {
                _ = try await Router.route(from: .init(), to: .init()) { _ in (body, Self.response(status: status)) }
                XCTFail("expected an error")
            } catch {
                XCTAssertEqual(error as? RouterError, expected)
            }
        }
    }

    private static func response(status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: Router.baseURL, statusCode: status, httpVersion: nil, headerFields: nil)!
    }
}

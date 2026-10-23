import CoreLocation
@testable import OpenWaze
import XCTest

final class SpeedTests: XCTestCase {
    let metric = Locale(identifier: "ms_MY")
    let imperial = Locale(identifier: "en_US")

    func testDisplayConvertsToLocaleUnit() {
        XCTAssertEqual(Speedometer.display(13.89, locale: metric), "50")
        XCTAssertEqual(Speedometer.display(13.41, locale: imperial), "30")
        XCTAssertEqual(Speedometer.display(0, locale: metric), "0")
        XCTAssertEqual(Speedometer.unitName(metric), "km/h")
        XCTAssertEqual(Speedometer.unitName(imperial), "mph")
    }

    func testNegativeSpeedIsInvalid() {
        XCTAssertNil(Speedometer.display(-1, locale: metric))
        XCTAssertNil(Speedometer.display(nil, locale: metric))
    }

    func testOverLimitOnlyPastTheMargin() {
        let limit = 50 / Speedometer.kmh, margin = 5 / Speedometer.kmh
        XCTAssertFalse(Speedometer.isOver(speed: 54.9 / Speedometer.kmh, limit: limit, margin: margin))
        XCTAssertFalse(Speedometer.isOver(speed: limit + margin, limit: limit, margin: margin))
        XCTAssertTrue(Speedometer.isOver(speed: 55.1 / Speedometer.kmh, limit: limit, margin: margin))
        XCTAssertTrue(Speedometer.isOver(speed: limit + 0.01, limit: limit, margin: 0))
        XCTAssertFalse(Speedometer.isOver(speed: 30, limit: nil, margin: 0))
        XCTAssertFalse(Speedometer.isOver(speed: -1, limit: 0, margin: 0))
        XCTAssertFalse(Speedometer.isOver(speed: nil, limit: limit, margin: 0))
    }

    func testMaxspeedParsing() throws {
        XCTAssertEqual(try XCTUnwrap(SpeedLimit.parse("50")), 50 / 3.6, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(SpeedLimit.parse(" 80 km/h ")), 80 / 3.6, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(SpeedLimit.parse("30 mph")), 13.411, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(SpeedLimit.parse("10 knots")), 5.144, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(SpeedLimit.parse("RU:urban")), 60 / 3.6, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(SpeedLimit.parse("MY:urban")), 50 / 3.6, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(SpeedLimit.parse("GB:nsl_single")), 60 * 0.44704, accuracy: 0.001)
        for bad in ["none", "signals", "variable", "walk", "", "0", "-30", "50 furlongs", "XX:urban", nil] {
            XCTAssertNil(SpeedLimit.parse(bad), bad ?? "nil")
        }
    }

    func testNearestWayWithinReachGivesTheLimit() {
        let origin = NavigatorTests.origin
        let north = SpeedLimits.Way(limit: 50, line: [origin, NavigatorTests.point(north: 1000)])
        let parallel = SpeedLimits.Way(limit: 90, line: [NavigatorTests.point(north: 0, east: 40),
                                                         NavigatorTests.point(north: 1000, east: 40)])
        let limits = SpeedLimits(ways: [parallel, north])
        XCTAssertEqual(limits.limit(near: NavigatorTests.point(north: 500, east: 10)), 50)
        XCTAssertEqual(limits.limit(near: NavigatorTests.point(north: 500, east: 30)), 90)
        XCTAssertEqual(limits.limit(near: NavigatorTests.point(north: 500, east: 65)), 90) // 25 m away: in reach
        XCTAssertNil(limits.limit(near: NavigatorTests.point(north: 500, east: 66)))
        XCTAssertNil(limits.limit(near: NavigatorTests.point(north: 1030)))
        XCTAssertNil(SpeedLimits().limit(near: origin))
    }

    func testQueryRoundsAndThinsTheRoute() {
        let line = [
            CLLocationCoordinate2D(latitude: 3.15791, longitude: 101.71162),
            CLLocationCoordinate2D(latitude: 3.15794, longitude: 101.71158), // same cell: dropped
            CLLocationCoordinate2D(latitude: 3.16049, longitude: 101.71449),
        ]
        let query = Overpass.query(along: line)
        XCTAssertTrue(query.contains("around:120,3.158,101.712,3.160,101.714)"), query)
        XCTAssertFalse(query.contains("3.15791"))
        XCTAssertTrue(query.contains("[maxspeed]"))

        let long = (0 ..< 5000).map { CLLocationCoordinate2D(latitude: 3 + Double($0) / 1000, longitude: 101) }
        let thinned = Overpass.thin(long)
        XCTAssertLessThanOrEqual(thinned.count, Overpass.maxPoints + 1)
        XCTAssertEqual(thinned.first?.lat, 3)
        XCTAssertEqual(thinned.last?.lat, 7.999)
    }

    func testParseSkipsWaysWithoutAUsableLimit() throws {
        let json = """
        {"elements":[
          {"type":"way","id":1,"tags":{"highway":"primary","maxspeed":"60"},
           "geometry":[{"lat":3.1,"lon":101.7},{"lat":3.2,"lon":101.7}]},
          {"type":"way","id":2,"tags":{"highway":"primary","maxspeed":"none"},
           "geometry":[{"lat":3.1,"lon":101.7},{"lat":3.2,"lon":101.7}]},
          {"type":"way","id":3,"tags":{"highway":"primary","maxspeed":"40"},"geometry":[{"lat":3.1,"lon":101.7}]},
          {"type":"way","id":4,"tags":{"highway":"primary","maxspeed":"40"},"geometry":"broken"}
        ]}
        """
        let limits = try Overpass.parse(Data(json.utf8))
        XCTAssertEqual(limits.ways.count, 1)
        XCTAssertEqual(limits.ways.first?.limit ?? 0, 60 / 3.6, accuracy: 0.001)
        XCTAssertEqual(limits.ways.first?.line.count, 2)
    }

    func testFetchRejectsHTTPErrors() async throws {
        let response = try XCTUnwrap(
            HTTPURLResponse(url: Overpass.baseURL, statusCode: 429, httpVersion: nil, headerFields: nil)
        )
        do {
            _ = try await Overpass.fetch(along: [NavigatorTests.origin]) { request in
                // Overpass answers 502 to a bare body; it wants a form field.
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
                XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), HTTP.userAgent)
                let body = String(bytes: request.httpBody ?? Data(), encoding: .utf8) ?? ""
                XCTAssertTrue(body.hasPrefix("data=%5Bout%3Ajson%5D%5Btimeout%3A25%5D%3Bway"), body)
                return (Data("{}".utf8), response)
            }
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? RouterError, .http(status: 429))
        }
    }
}

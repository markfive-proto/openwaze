import CoreLocation
@testable import OpenWaze
import XCTest

final class SpeedLimitTests: XCTestCase {
    func testParsesMaxspeed() throws {
        XCTAssertEqual(Maxspeed.kmh("50"), 50)
        XCTAssertEqual(Maxspeed.kmh(" 80 "), 80)
        XCTAssertEqual(Maxspeed.kmh("60 km/h"), 60)
        XCTAssertEqual(try XCTUnwrap(Maxspeed.kmh("30 mph")), 48.28, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(Maxspeed.kmh("30mph")), 48.28, accuracy: 0.01)
        XCTAssertEqual(Maxspeed.kmh("MY:urban"), 60)
        XCTAssertEqual(Maxspeed.kmh("MY:rural"), 90)
        XCTAssertEqual(Maxspeed.kmh("MY:motorway"), 110)
        XCTAssertEqual(Maxspeed.kmh("50;60"), 50)
        XCTAssertEqual(Maxspeed.kmh("60;50"), 50)
        XCTAssertEqual(Maxspeed.kmh("none;60"), 60)
        for none in [nil, "", "none", "signals", "walk", "RU:urban", "fast", "-30", "0", "50 knots", "1e9"] {
            XCTAssertNil(Maxspeed.kmh(none), String(describing: none))
        }
    }

    func testTileSnapsToGrid() {
        let klcc = SpeedTile(CLLocationCoordinate2D(latitude: 3.1579, longitude: 101.7116))
        XCTAssertEqual(klcc, SpeedTile(row: 315, column: 10171))
        XCTAssertEqual(klcc.key, "315_10171")
        XCTAssertEqual(klcc, SpeedTile(CLLocationCoordinate2D(latitude: 3.1501, longitude: 101.7199)))
        for (value, expected) in zip(klcc.bounds, [3.15, 101.71, 3.16, 101.72]) {
            XCTAssertEqual(value, expected, accuracy: 1e-9)
        }
        // Floors, not truncates, below zero.
        let south = SpeedTile(CLLocationCoordinate2D(latitude: -0.001, longitude: -0.001))
        XCTAssertEqual(south, SpeedTile(row: -1, column: -1))
    }

    func testQuerySendsOnlyTheTile() throws {
        let request = Overpass.request(for: SpeedTile(CLLocationCoordinate2D(latitude: 3.1579, longitude: 101.7116)))
        let body = try XCTUnwrap(request.httpBody.flatMap { String(data: $0, encoding: .utf8) })
        XCTAssertFalse(body.contains("3.1579"))
        XCTAssertFalse(body.contains("101.7116"))
        XCTAssertTrue(Overpass.query(for: SpeedTile(row: 315, column: 10171)).contains("(3.15,101.71,3.16,101.72)"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), HTTP.userAgent)
    }

    func testParsesOverpassAndSkipsBadElements() throws {
        let json = Data("""
        {"elements": [
          {"type": "way", "id": 1, "tags": {"highway": "primary", "maxspeed": "60"},
           "geometry": [{"lat": 3.15, "lon": 101.71}, {"lat": 3.151, "lon": 101.71}]},
          {"type": "way", "id": 2, "tags": {"highway": "residential"},
           "geometry": [{"lat": 3.15, "lon": 101.71}, {"lat": 3.15, "lon": 101.711}]},
          {"type": "way", "id": 3, "geometry": [{"lat": 3.15, "lon": 101.71}]},
          {"type": "way", "id": 4, "geometry": "oops"},
          {"type": "node", "id": 5}
        ]}
        """.utf8)
        let ways = try Overpass.parse(json)
        XCTAssertEqual(ways.map(\.maxspeed), ["60", nil])
        XCTAssertThrowsError(try Overpass.parse(Data("<html>".utf8)))
    }

    /// A north-south road with a limit crossed by an east-west one without.
    let crossing = [
        SpeedWay(maxspeed: "80", points: [.init(lat: 3.150, lon: 101.710), .init(lat: 3.152, lon: 101.710)]),
        SpeedWay(maxspeed: nil, points: [.init(lat: 3.151, lon: 101.709), .init(lat: 3.151, lon: 101.711)]),
    ]

    func testNearestWayUsesHeading() {
        // 5 m east of the junction: the east-west road is nearer.
        let point = CLLocationCoordinate2D(latitude: 3.15101, longitude: 101.71005)
        XCTAssertNil(SpeedMatch.nearest(crossing, to: point, course: 90)?.maxspeed)
        XCTAssertEqual(SpeedMatch.nearest(crossing, to: point, course: 90), crossing[1])
        // Heading north (or south) puts us on the north-south road.
        XCTAssertEqual(SpeedMatch.nearest(crossing, to: point, course: 2), crossing[0])
        XCTAssertEqual(SpeedMatch.nearest(crossing, to: point, course: 181), crossing[0])
        // No usable course: plain nearest.
        XCTAssertEqual(SpeedMatch.nearest(crossing, to: point, course: nil), crossing[1])
        // Crossing the only road: not on it.
        XCTAssertNil(SpeedMatch.nearest([crossing[0]], to: point, course: 90))
        // Far from every road.
        XCTAssertNil(SpeedMatch.nearest(crossing, to: .init(latitude: 3.155, longitude: 101.715), course: nil))
    }

    func testAngleIgnoresDirectionAlongRoad() {
        XCTAssertEqual(SpeedMatch.angle(10, 350), 20, accuracy: 1e-9)
        XCTAssertEqual(SpeedMatch.angle(0, 180), 0, accuracy: 1e-9)
        XCTAssertEqual(SpeedMatch.angle(90, 0), 90, accuracy: 1e-9)
        let west = SpeedMatch.bearing(.init(latitude: 3, longitude: 101), .init(latitude: 3, longitude: 100))
        XCTAssertEqual(west, 270, accuracy: 0.01)
    }

    func testOverLimitHysteresis() {
        var warning = OverLimit()
        XCTAssertFalse(warning.update(speed: 64, limit: 60))
        XCTAssertFalse(warning.update(speed: 65, limit: 60)) // at limit + margin is fine
        XCTAssertTrue(warning.update(speed: 66, limit: 60)) // goes over: chime once
        XCTAssertTrue(warning.isOver)
        XCTAssertFalse(warning.update(speed: 70, limit: 60)) // still over, no repeat
        XCTAssertFalse(warning.update(speed: 63, limit: 60)) // inside the band, stays red
        XCTAssertTrue(warning.isOver)
        XCTAssertFalse(warning.update(speed: 61.9, limit: 60))
        XCTAssertFalse(warning.isOver)
        XCTAssertTrue(warning.update(speed: 66, limit: 60)) // a new episode chimes again
        XCTAssertFalse(warning.update(speed: 66, limit: nil))
        XCTAssertFalse(warning.isOver)
    }

    func testUnitConversion() {
        XCTAssertEqual(SpeedUnit.display(59.6, metric: true), 60)
        XCTAssertEqual(SpeedUnit.display(48.28, metric: false), 30)
        XCTAssertEqual(SpeedUnit.display(100, metric: false), 62)
    }

    @MainActor
    func testSpeedometerSmoothsAndIgnoresInvalid() {
        var chimes = 0
        let offline = SpeedLimitStore(directory: nil, fetch: { _ in throw URLError(.notConnectedToInternet) })
        let meter = Speedometer(store: offline) {
            chimes += 1
        }
        meter.update(fix(speed: -1))
        XCTAssertNil(meter.speed)
        meter.update(fix(speed: 10)) // 36 km/h
        XCTAssertEqual(meter.speed ?? 0, 36, accuracy: 1e-9)
        meter.update(fix(speed: 20)) // 72 km/h, smoothed
        XCTAssertEqual(meter.speed ?? 0, 36 + 0.6 * 36, accuracy: 1e-9)
        meter.update(fix(speed: -1)) // invalid sample keeps the last value
        XCTAssertEqual(meter.speed ?? 0, 36 + 0.6 * 36, accuracy: 1e-9)
        XCTAssertEqual(chimes, 0) // no limit known
    }

    @MainActor
    func testStoreCachesAndBacksOff() async {
        var calls = 0
        var status = 429
        var clock = Date(timeIntervalSince1970: 0)
        let body = Data("""
        {"elements": [{"type": "way", "tags": {"maxspeed": "50"},
          "geometry": [{"lat": 0, "lon": 0}, {"lat": 0.001, "lon": 0}]}]}
        """.utf8)
        let store = SpeedLimitStore(directory: nil, fetch: { request in
            calls += 1
            return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }, now: { clock })
        let tile = SpeedTile(row: 0, column: 0)
        let busy = await store.ways(for: tile)
        XCTAssertNil(busy)
        _ = await store.ways(for: tile) // backing off: no request
        XCTAssertEqual(calls, 1)
        status = 200
        clock.addTimeInterval(Overpass.backoff(after: 1, status: 429))
        let ways = await store.ways(for: tile)
        XCTAssertEqual(ways?.count, 1)
        _ = await store.ways(for: tile) // cached
        XCTAssertEqual(calls, 2)
        clock.addTimeInterval(SpeedLimitStore.ttl)
        _ = await store.ways(for: tile) // stale: refetch
        XCTAssertEqual(calls, 3)
    }

    func testBackoff() {
        XCTAssertEqual(Overpass.backoff(after: 1, status: 500), 30)
        XCTAssertEqual(Overpass.backoff(after: 2, status: 500), 60)
        XCTAssertEqual(Overpass.backoff(after: 1, status: 429), 120)
        XCTAssertEqual(Overpass.backoff(after: 1, status: 504), 120)
        XCTAssertEqual(Overpass.backoff(after: 10, status: 429), 900)
    }

    @MainActor
    func testSpeedometerLooksUpLimitAndChimesOnce() async {
        // A north-south 50 km/h road through KLCC.
        let body = Data("""
        {"elements": [{"type": "way", "tags": {"maxspeed": "50"},
          "geometry": [{"lat": 3.155, "lon": 101.7116}, {"lat": 3.159, "lon": 101.7116}]}]}
        """.utf8)
        var calls = 0
        let store = SpeedLimitStore(directory: nil, fetch: { request in
            calls += 1
            return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        var chimes = 0
        let meter = Speedometer(store: store) { chimes += 1 }
        meter.update(fix(speed: 20)) // 72 km/h heading north
        await meter.pending?.value
        XCTAssertEqual(meter.limit, 50)
        XCTAssertTrue(meter.isOver)
        XCTAssertEqual(chimes, 1)
        meter.update(fix(speed: 20))
        await meter.pending?.value
        XCTAssertEqual(chimes, 1) // still over: no repeat
        XCTAssertEqual(calls, 1) // tile cached
        // A vague fix is not used for the limit, and no lookup starts.
        let before = meter.pending
        meter.update(fix(speed: 20, accuracy: 51))
        XCTAssertTrue(meter.pending == before)
        meter.update(fix(speed: 20, age: 11))
        XCTAssertTrue(meter.pending == before)
        XCTAssertEqual(meter.limit, 50)
    }

    @MainActor
    func testUnknownTileClearsLimit() async {
        let body = Data("""
        {"elements": [{"type": "way", "tags": {"maxspeed": "50"},
          "geometry": [{"lat": 3.155, "lon": 101.7116}, {"lat": 3.159, "lon": 101.7116}]}]}
        """.utf8)
        var status = 200
        let store = SpeedLimitStore(directory: nil, fetch: { request in
            (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        })
        let meter = Speedometer(store: store) {}
        meter.update(fix(speed: 20))
        await meter.pending?.value
        XCTAssertEqual(meter.limit, 50)
        // Into the next tile, which cannot be fetched: no sign, not the old 50.
        status = 503
        meter.update(fix(speed: 20, latitude: 3.1650))
        await meter.pending?.value
        XCTAssertNil(meter.limit)
        XCTAssertFalse(meter.isOver)
    }

    func testMatchBoundaries() {
        let road = [SpeedWay(maxspeed: "60", points: [.init(lat: 0, lon: 0), .init(lat: 0, lon: 0.01)])]
        let metre = 1 / 111_195.0 // degrees of latitude per metre
        XCTAssertNotNil(SpeedMatch.nearest(road, to: .init(latitude: 24.9 * metre, longitude: 0.005), course: nil))
        XCTAssertNil(SpeedMatch.nearest(road, to: .init(latitude: 25.1 * metre, longitude: 0.005), course: nil))
        let point = CLLocationCoordinate2D(latitude: 0, longitude: 0.005)
        XCTAssertNotNil(SpeedMatch.nearest(road, to: point, course: 90 + 44.9))
        XCTAssertNil(SpeedMatch.nearest(road, to: point, course: 90 + 45.1))
        XCTAssertNil(SpeedMatch.nearest([], to: point, course: nil))
    }

    private func fix(
        speed: Double, accuracy: Double = 5, age: TimeInterval = 0, latitude: Double = 3.1579
    ) -> CLLocation {
        CLLocation(
            coordinate: .init(latitude: latitude, longitude: 101.7116), altitude: 0,
            horizontalAccuracy: accuracy, verticalAccuracy: 5, course: 0, courseAccuracy: 5,
            speed: speed, speedAccuracy: 1, timestamp: Date(timeIntervalSinceNow: -age)
        )
    }
}

import CoreLocation
@testable import OpenWaze
import XCTest

final class TrafficTests: XCTestCase {
    let start = CLLocationCoordinate2D(latitude: 3.0, longitude: 101.7000)
    let end = CLLocationCoordinate2D(latitude: 3.0, longitude: 101.7008) // ~89 m due east, one cell

    func eastRoute(duration: Double) -> Route {
        Route(
            coordinates: [start, end],
            steps: [Route.Step(type: "depart", latitude: 3.0, longitude: 101.7000, distance: 89, duration: duration)],
            distance: Geo.distance(start, end), duration: duration
        )
    }

    func levels(_ level: TrafficReading.Level, heading: Int = 90) -> [Traffic.Key: TrafficReading.Level] {
        Traffic.index([TrafficReading(lat: 3.0, lng: 101.700, heading: heading, level: level)])
    }

    func testJamAndSlowAddTheExtraTime() {
        let route = eastRoute(duration: 8.9)
        let metres = route.distance
        XCTAssertEqual(Traffic.delay(of: route, levels: levels(.jam)), metres / (8 / 3.6) - 8.9, accuracy: 0.01)
        XCTAssertEqual(Traffic.delay(of: route, levels: levels(.slow)), metres / (27 / 3.6) - 8.9, accuracy: 0.01)
    }

    func testNoDataFreeFlowOtherDirectionAndAlreadySlowRoadsAddNothing() {
        let route = eastRoute(duration: 8.9)
        XCTAssertEqual(Traffic.delay(of: route, levels: [:]), 0)
        XCTAssertEqual(Traffic.delay(of: route, levels: levels(.free)), 0)
        XCTAssertEqual(Traffic.delay(of: route, levels: levels(.jam, heading: 270)), 0) // the other carriageway
        // OSRM already expects this road to be slower than the jam band: never a negative delay.
        XCTAssertEqual(Traffic.delay(of: eastRoute(duration: 300), levels: levels(.jam)), 0)
    }

    func testHeadingBucketsMatchTheServerAtTheirEdges() {
        XCTAssertEqual(Traffic.bucket(22.4), 0)
        XCTAssertEqual(Traffic.bucket(22.5), 45)
        XCTAssertEqual(Traffic.bucket(337.4), 315)
        XCTAssertEqual(Traffic.bucket(337.5), 0)
        XCTAssertEqual(Traffic.bucket(-10), 0)
        XCTAssertEqual(Traffic.bucket(-30), 315)
        XCTAssertEqual(Traffic.bucket(0), 0)
    }

    func testParseDropsOneBadReading() throws {
        let data = Data("""
        [{"lat": 3.0, "lng": 101.7, "heading": 90, "level": "jam"},
         {"lat": 3.0, "lng": 101.7, "heading": 90, "level": "gridlock"},
         {"lat": "x"}]
        """.utf8)
        XCTAssertEqual(try Traffic.parse(data).map(\.level), [.jam])
    }

    func testBoxGrowsOutwardToTheGridSoItHidesTheExactOrigin() throws {
        let origin = CLLocationCoordinate2D(latitude: 3.0123, longitude: 101.7041)
        let target = CLLocationCoordinate2D(latitude: 3.0151, longitude: 101.7089)
        let route = Route(coordinates: [origin, target], steps: [], distance: 100, duration: 10)
        let box = try XCTUnwrap(Traffic.box(around: route))
        XCTAssertEqual(box.minLat, 3.01, accuracy: 1e-9)
        XCTAssertEqual(box.maxLat, 3.02, accuracy: 1e-9)
        XCTAssertEqual(box.minLng, 101.70, accuracy: 1e-9)
        XCTAssertEqual(box.maxLng, 101.71, accuracy: 1e-9)
        // A point already on the grid stays put instead of stepping out a cell.
        let flat = try XCTUnwrap(Traffic.box(around: eastRoute(duration: 9)))
        XCTAssertEqual(flat.minLat, 3.0, accuracy: 1e-9)
        XCTAssertEqual(flat.maxLat, 3.0, accuracy: 1e-9)
    }

    func testRoutesComeBackUnchangedWhenTrafficIsUnavailable() async {
        let route = eastRoute(duration: 8.9)
        let none = await Traffic.adjusted([route], using: nil)
        XCTAssertEqual(none.map(\.trafficDelay), [0])
        let failed = await Traffic.adjusted([route], using: { _ in throw URLError(.notConnectedToInternet) })
        XCTAssertEqual(failed.map(\.trafficDelay), [0])
    }

    func testAdjustedFillsInTheDelayAndKeepsTheRoute() async {
        let route = eastRoute(duration: 8.9)
        let readings = [TrafficReading(lat: 3.0, lng: 101.700, heading: 90, level: .jam)]
        let adjusted = await Traffic.adjusted([route], using: { _ in readings })
        XCTAssertEqual(adjusted.first?.id, route.id)
        XCTAssertGreaterThan(adjusted.first?.eta ?? 0, 30)
    }

    func testRemainingTimeScalesWithTheDelay() {
        var route = eastRoute(duration: 10)
        route.trafficDelay = 10
        XCTAssertEqual(Guidance.remainingDuration(on: route, nextStep: 1, left: 89), 20, accuracy: 0.01)
    }
}

@MainActor
final class AlternativesTests: XCTestCase {
    let destination = Destination(id: "N1", name: "SS2", address: "", latitude: 3.018, longitude: 101.700)
    var clock = Date(timeIntervalSince1970: 0)
    var answers: [Result<[Route], Error>] = []
    var calls = 0

    /// Straight north for 2 km; `duration` is the whole trip.
    nonisolated static func straight(duration: Double) -> Route {
        let end = NavigatorTests.point(north: 2000)
        let length = Geo.distance(NavigatorTests.origin, end) // exact, so the step share is exactly 1
        return Route(
            coordinates: [NavigatorTests.origin, end],
            steps: [
                Route.Step(type: "depart", latitude: 3.0, longitude: 101.7, distance: length, duration: duration),
                Route.Step(type: "arrive", latitude: end.latitude, longitude: end.longitude),
            ],
            distance: length, duration: duration
        )
    }

    func makeNavigator(traffic: Traffic.Fetch? = nil) -> Navigator {
        Navigator(
            fetchRoutes: { [unowned self] _, _ in
                calls += 1
                return try answers.removeFirst().get()
            },
            traffic: traffic,
            speech: NavigatorTests.FakeSpeech(),
            now: { [unowned self] in clock },
            sleep: { _ in },
            feed: nil
        )
    }

    func driving(_ current: Route) async -> Navigator {
        answers = [.success([current])]
        let navigator = makeNavigator()
        await navigator.preview(to: destination, from: NavigatorTests.origin)
        navigator.start()
        return navigator
    }

    // MARK: pick before Go

    func testPreviewListsAlternativesAndPicksOneBeforeGo() async {
        let (fast, slow) = (Self.straight(duration: 500), Self.straight(duration: 700))
        answers = [.success([fast, slow])]
        let navigator = makeNavigator()
        await navigator.preview(to: destination, from: NavigatorTests.origin)
        XCTAssertEqual(navigator.alternatives.map(\.id), [fast.id, slow.id])
        XCTAssertEqual(navigator.route?.id, fast.id)

        navigator.select(1)
        XCTAssertEqual(navigator.route?.id, slow.id)
        XCTAssertEqual(navigator.progress?.remainingDuration, 700)
        navigator.select(2) // out of range: ignored
        navigator.select(-1)
        XCTAssertEqual(navigator.route?.id, slow.id)

        navigator.start()
        XCTAssertEqual(navigator.route?.id, slow.id)
        navigator.select(0) // too late, the trip has started
        XCTAssertEqual(navigator.route?.id, slow.id)
        XCTAssertTrue(navigator.alternatives.isEmpty)
    }

    func testLiveTrafficReordersTheRoutes() async {
        let east = TrafficTests().eastRoute(duration: 8.9)
        let north = Self.straight(duration: 20)
        answers = [.success([east, north])]
        let jam = [TrafficReading(lat: 3.0, lng: 101.700, heading: 90, level: .jam)]
        let navigator = makeNavigator(traffic: { _ in jam })
        await navigator.preview(to: destination, from: NavigatorTests.origin)
        XCTAssertEqual(navigator.alternatives.map(\.id), [north.id, east.id], "the jammed road drops to second")
        XCTAssertEqual(navigator.route?.id, north.id)
    }

    // MARK: faster route while driving

    func testNoCheckUntilTwoMinutesHavePassed() async {
        let navigator = await driving(Self.straight(duration: 600))
        answers = [.success([Self.straight(duration: 100)])]
        clock = Date(timeIntervalSince1970: 119.9)
        navigator.update(NavigatorTests.fix(north: 50))
        XCTAssertEqual(calls, 1)
        XCTAssertNil(navigator.check)
        clock = Date(timeIntervalSince1970: 120)
        navigator.update(NavigatorTests.fix(north: 60))
        await navigator.check?.value
        XCTAssertEqual(calls, 2)
        XCTAssertNotNil(navigator.faster)
    }

    func offer(candidate: Double) async -> Navigator.Offer? {
        let navigator = await driving(Self.straight(duration: 600))
        answers = [.success([Self.straight(duration: candidate)])]
        clock = Date(timeIntervalSince1970: 120)
        navigator.update(NavigatorTests.fix(north: 0))
        await navigator.check?.value
        return navigator.faster
    }

    func testOfferNeedsAtLeastAMinuteSaved() async {
        let atLimit = await offer(candidate: 540)
        XCTAssertEqual(atLimit?.saves, 60)
        let justUnder = await offer(candidate: 541)
        XCTAssertNil(justUnder)
        let slower = await offer(candidate: 700)
        XCTAssertNil(slower)
    }

    func testAcceptingTheOfferSwitchesRoute() async {
        let candidate = Self.straight(duration: 300)
        let navigator = await driving(Self.straight(duration: 600))
        answers = [.success([candidate])]
        clock = Date(timeIntervalSince1970: 120)
        navigator.update(NavigatorTests.fix(north: 0))
        await navigator.check?.value
        navigator.acceptFaster()
        XCTAssertEqual(navigator.route?.id, candidate.id)
        XCTAssertNil(navigator.faster)
        XCTAssertEqual(navigator.phase, .navigating)
    }

    func testDismissingClearsTheOfferUntilTheNextCheck() async {
        let navigator = await driving(Self.straight(duration: 600))
        answers = [.success([Self.straight(duration: 300)]), .success([Self.straight(duration: 300)])]
        clock = Date(timeIntervalSince1970: 120)
        navigator.update(NavigatorTests.fix(north: 0))
        await navigator.check?.value
        navigator.dismissFaster()
        XCTAssertNil(navigator.faster)
        navigator.update(NavigatorTests.fix(north: 10)) // same minute: no new request
        XCTAssertEqual(calls, 2)
        clock = Date(timeIntervalSince1970: 240)
        navigator.update(NavigatorTests.fix(north: 20))
        await navigator.check?.value
        XCTAssertNotNil(navigator.faster)
    }

    func testAnswerAfterTheTripEndedIsDropped() async {
        let navigator = await driving(Self.straight(duration: 600))
        answers = [.success([Self.straight(duration: 300)])]
        clock = Date(timeIntervalSince1970: 120)
        navigator.update(NavigatorTests.fix(north: 0))
        let pending = navigator.check
        navigator.end()
        await pending?.value
        XCTAssertNil(navigator.faster)
    }

    func testVagueFixDoesNotStartACheck() async {
        let navigator = await driving(Self.straight(duration: 600))
        clock = Date(timeIntervalSince1970: 130)
        navigator.update(NavigatorTests.fix(north: 0, accuracy: 120))
        XCTAssertEqual(calls, 1)
        XCTAssertNil(navigator.check)
    }

    func testAFailedCheckIsRetriedAtTheNextInterval() async {
        let navigator = await driving(Self.straight(duration: 600))
        answers = [.failure(RouterError.http(status: 503)), .success([Self.straight(duration: 300)])]
        clock = Date(timeIntervalSince1970: 120)
        navigator.update(NavigatorTests.fix(north: 0))
        await navigator.check?.value
        XCTAssertNil(navigator.faster)
        clock = Date(timeIntervalSince1970: 240)
        navigator.update(NavigatorTests.fix(north: 10))
        await navigator.check?.value
        XCTAssertNotNil(navigator.faster)
    }
}

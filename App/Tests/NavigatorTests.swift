import CoreLocation
@testable import OpenWaze
import XCTest

@MainActor
final class NavigatorTests: XCTestCase {
    final class FakeSpeech: Speaking {
        var said: [(text: String, key: PromptKey)] = []

        func say(_ text: String, key: PromptKey) {
            said.append((text, key))
        }

        func stop() {}
    }

    /// Answers from `results` in order; once they run out, calls wait in
    /// `pending` until the test resumes them.
    final class FakeRouter {
        var results: [Result<Route, Error>] = []
        var pending: [CheckedContinuation<Route, Error>] = []
        var origins: [CLLocationCoordinate2D] = []

        func fetch(_ origin: CLLocationCoordinate2D, _: CLLocationCoordinate2D) async throws -> Route {
            origins.append(origin)
            if !results.isEmpty {
                return try results.removeFirst().get()
            }
            return try await withCheckedThrowingContinuation { pending.append($0) }
        }
    }

    static let origin = CLLocationCoordinate2D(latitude: 3.000, longitude: 101.700)
    static let corner = CLLocationCoordinate2D(latitude: 3.009, longitude: 101.700)
    static let end = CLLocationCoordinate2D(latitude: 3.009, longitude: 101.709)
    let destination = Destination(id: "N1", name: "SS2", address: "", latitude: 3.009, longitude: 101.709)

    let speech = FakeSpeech()
    let router = FakeRouter()
    var clock = Date(timeIntervalSince1970: 0)
    var slept: [TimeInterval] = []

    func makeNavigator() -> Navigator {
        Navigator(
            fetchRoutes: { [unowned self] in try await [router.fetch($0, $1)] },
            speech: speech,
            now: { [unowned self] in clock },
            sleep: { [unowned self] in slept.append($0) },
            feed: nil
        )
    }

    /// ~1 km north, right turn, ~1 km east; optionally a second turn `shortStep` metres after the first.
    nonisolated static func lRoute(shortStep: Double? = nil) -> Route {
        var coordinates = [origin, corner, end]
        var steps = [
            Route.Step(type: "depart", latitude: 3.000, longitude: 101.700, distance: 1000, duration: 100),
            Route.Step(type: "turn", modifier: "right", latitude: 3.009, longitude: 101.700,
                       distance: shortStep ?? 1000, duration: 10),
            Route.Step(type: "arrive", latitude: 3.009, longitude: 101.709),
        ]
        if let shortStep {
            let second = point(north: 1000.75, east: shortStep)
            coordinates.insert(second, at: 2)
            steps.insert(Route.Step(type: "turn", modifier: "left", latitude: second.latitude,
                                    longitude: second.longitude, distance: 970, duration: 90), at: 2)
        }
        return Route(coordinates: coordinates, steps: steps, distance: 2000, duration: 200)
    }

    nonisolated static func point(north: Double, east: Double = 0) -> CLLocationCoordinate2D {
        let degree = Geo.earthRadius * .pi / 180
        return CLLocationCoordinate2D(
            latitude: origin.latitude + north / degree,
            longitude: origin.longitude + east / (degree * cos(origin.latitude * .pi / 180))
        )
    }

    nonisolated static func fix(north: Double, east: Double = 0, accuracy: Double = 5) -> CLLocation {
        CLLocation(coordinate: point(north: north, east: east), altitude: 0, horizontalAccuracy: accuracy,
                   verticalAccuracy: -1, course: 0, speed: 10, timestamp: Date())
    }

    func navigating(_ route: Route = lRoute()) async -> Navigator {
        router.results.append(.success(route))
        let navigator = makeNavigator()
        await navigator.preview(to: destination, from: Self.origin)
        navigator.start()
        XCTAssertEqual(navigator.phase, .navigating)
        return navigator
    }

    func waitForPendingRequests(_ count: Int) async {
        for _ in 0 ..< 1000 where router.pending.count < count {
            await Task.yield()
        }
        XCTAssertEqual(router.pending.count, count)
    }

    func testStaleRouteResponseIsIgnored() async {
        let navigator = makeNavigator()
        let other = Destination(id: "N2", name: "KLCC", address: "", latitude: 3.1579, longitude: 101.7116)
        let first = Task { await navigator.preview(to: destination, from: Self.origin) }
        await waitForPendingRequests(1)
        let second = Task { await navigator.preview(to: other, from: Self.origin) }
        await waitForPendingRequests(2)
        let newer = Self.lRoute(), older = Self.lRoute()
        router.pending[1].resume(returning: newer)
        await second.value
        router.pending[0].resume(returning: older) // the slow first answer lands last
        await first.value
        XCTAssertEqual(navigator.route?.id, newer.id)
        XCTAssertEqual(navigator.destination, other)
        XCTAssertEqual(navigator.phase, .preview)

        // A response that lands after End is dropped too.
        let third = Task { await navigator.preview(to: destination, from: Self.origin) }
        await waitForPendingRequests(3)
        navigator.end()
        router.pending[2].resume(returning: Self.lRoute())
        await third.value
        XCTAssertNil(navigator.route)
        XCTAssertEqual(navigator.phase, .idle)
    }

    func testRerouteRetriesWithBackoffUntilItWorks() async {
        let navigator = await navigating()
        let detour = Self.lRoute()
        router.results = [.failure(RouterError.http(status: 503)), .failure(RouterError.http(status: 429)),
                          .success(detour)]
        navigator.update(Self.fix(north: 500, east: 200))
        await navigator.work?.value // the stationary recheck, too early to reroute
        XCTAssertEqual(router.origins.count, 1)
        clock += 5
        navigator.update(Self.fix(north: 500, east: 210))
        await navigator.work?.value
        XCTAssertEqual(router.origins.count, 4) // preview, then three reroute attempts
        XCTAssertEqual(Array(slept.suffix(2)), [5, 10])
        XCTAssertEqual(navigator.route?.id, detour.id)
        XCTAssertEqual(navigator.phase, .navigating)
    }

    func testVagueFixesNeverTriggerAReroute() async {
        let navigator = await navigating()
        navigator.update(Self.fix(north: 500, east: 200, accuracy: 120))
        clock += 30
        navigator.update(Self.fix(north: 500, east: 200, accuracy: 120))
        await navigator.work?.value
        XCTAssertEqual(router.origins.count, 1)
    }

    func testNoArrivalOnAParallelStreetNearTheEnd() async {
        let navigator = await navigating()
        // 80 m north of the end, on a parallel street.
        let parallel = CLLocation(latitude: Self.end.latitude + 80 / 111_195, longitude: Self.end.longitude)
        navigator.update(parallel)
        XCTAssertEqual(navigator.phase, .navigating)
        navigator.update(CLLocation(latitude: Self.end.latitude, longitude: Self.end.longitude))
        XCTAssertEqual(navigator.phase, .arrived)
        XCTAssertEqual(speech.said.last?.text, "You have arrived")
    }

    func testShortStepGetsItsOwnLatePrompt() async {
        let navigator = await navigating(Self.lRoute(shortStep: 30))
        navigator.update(Self.fix(north: 960)) // 40 m before the first turn
        navigator.update(Self.fix(north: 1000.75, east: 10)) // past it, 20 m before the second
        XCTAssertEqual(speech.said.map(\.text), ["Turn right", "Turn left"])
        XCTAssertEqual(speech.said.map(\.key.step), [1, 2])
    }

    func testRerouteResetsSpokenPrompts() async {
        let navigator = await navigating()
        navigator.update(Self.fix(north: 960))
        XCTAssertEqual(speech.said.map(\.text), ["Turn right"])
        router.results = [.success(Self.lRoute())]
        navigator.update(Self.fix(north: 500, east: 200))
        await navigator.work?.value
        clock += 5
        navigator.update(Self.fix(north: 500, east: 200))
        await navigator.work?.value
        navigator.update(Self.fix(north: 960))
        XCTAssertEqual(speech.said.map(\.text), ["Turn right", "Turn right"])
        XCTAssertLessThan(speech.said[0].key, speech.said[1].key) // the old prompt counts as stale
    }
}

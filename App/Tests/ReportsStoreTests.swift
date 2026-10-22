import CoreLocation
@testable import OpenWaze
import XCTest

@MainActor
final class ReportsStoreTests: XCTestCase {
    let server = FakeServer()
    var delays: [TimeInterval] = []
    var clock = fixtureNow
    let defaults = UserDefaults(suiteName: "ReportsStoreTests")!
    lazy var store = makeStore()

    func makeStore() -> ReportsStore {
        ReportsStore(
            client: server.client,
            now: { [unowned self] in clock },
            sleep: { [unowned self] seconds in
                delays.append(seconds)
                try Task.checkCancellation()
            },
            defaults: defaults
        )
    }

    override func setUp() {
        defaults.removePersistentDomain(forName: "ReportsStoreTests")
    }

    let areaA = BBox(minLat: 3.1, minLng: 101.6, maxLat: 3.2, maxLng: 101.8)
    let areaB = BBox(minLat: 3.0, minLng: 101.5, maxLat: 3.1, maxLng: 101.6)

    func waitForPending() async {
        while server.pending.isEmpty {
            await Task.yield()
        }
    }

    /// A sleep that records what was asked and returns only when released.
    @MainActor
    final class Gate {
        var delays: [TimeInterval] = []
        var waiting: [CheckedContinuation<Void, Never>] = []

        func sleep(_ seconds: TimeInterval) async throws {
            delays.append(seconds)
            try Task.checkCancellation()
            await withCheckedContinuation { waiting.append($0) }
            try Task.checkCancellation()
        }

        func release() {
            waiting.forEach { $0.resume() }
            waiting = []
        }
    }

    func testDebouncesRegionChanges() async throws {
        let gate = Gate()
        let store = ReportsStore(client: server.client, now: { fixtureNow }, sleep: { try await gate.sleep($0) },
                                 defaults: defaults)
        server.responses = [(200, "[\(reportJSON("b", lat: 3.05, lng: 101.55))]")]
        store.setRegion(BBox(minLat: 0, minLng: 0, maxLat: 1, maxLng: 1))
        store.setRegion(areaA)
        store.setRegion(areaB)
        while gate.waiting.isEmpty {
            await Task.yield()
        }
        XCTAssertEqual(gate.waiting.count, 1, "earlier moves were cancelled")
        XCTAssertTrue(gate.delays.allSatisfy { $0 == ReportsStore.debounce })
        XCTAssertEqual(ReportsStore.debounce, 0.5)
        XCTAssertTrue(server.requests.isEmpty, "nothing is fetched before the map rests")
        gate.release()
        await store.work?.value
        XCTAssertEqual(server.requests.count, 1)
        XCTAssertTrue(try XCTUnwrap(server.requests[0].url?.query?.contains("minLat=3.0&minLng=101.5")))
        XCTAssertEqual(store.reports.map(\.id), ["b"])
    }

    func testListOlderThanAVoteIsRefetched() async throws {
        server.responses = [(200, "[\(reportJSON("a"))]")]
        store.setRegion(areaA)
        await store.work?.value

        store.setRegion(areaA)
        let refresh = store.work
        await waitForPending() // a list started before the vote
        server.responses = [(200, reportJSON("a", upvotes: 1))]
        try await store.vote("a", stillThere: true)
        XCTAssertEqual(store.reports.first?.upvotes, 1)

        server.responses = [(200, "[\(reportJSON("a", upvotes: 1))]")]
        server.resume(200, "[\(reportJSON("a", upvotes: 0))]") // stale copy
        await refresh?.value
        await store.work?.value
        XCTAssertEqual(store.reports.first?.upvotes, 1)
        XCTAssertEqual(server.requests.count, 4, "list, list (stale), vote, list again")
    }

    func testOwnReportIDsSurviveARelaunchUntilExpiry() async throws {
        server.responses = [(201, reportJSON("mine", expires: "2026-10-22T11:00:00Z"))]
        try await store.report(.police, at: CLLocationCoordinate2D(latitude: 3.15, longitude: 101.71))
        XCTAssertEqual(makeStore().mine, ["mine"])
        clock = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-22T11:00:01Z"))
        XCTAssertEqual(makeStore().mine, [])
    }

    func testTimerStopsWhenStoreIsGone() async throws {
        var ticks = 0
        weak var weakStore: ReportsStore?
        do {
            let store = ReportsStore(client: server.client, sleep: { _ in
                ticks += 1
                try await Task.sleep(for: .milliseconds(5))
            }, defaults: defaults)
            store.start()
            weakStore = store
        }
        XCTAssertNil(weakStore)
        try await Task.sleep(for: .milliseconds(50))
        let settled = ticks
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(ticks, settled)
        XCTAssertLessThanOrEqual(ticks, 1)
    }

    func testDropsStaleResponseForAnAreaLeftBehind() async {
        store.setRegion(areaA)
        let first = store.work
        await waitForPending() // A is in flight and ignores cancellation
        server.responses = [(200, "[\(reportJSON("b"))]")]
        store.setRegion(areaB)
        await store.work?.value
        server.resume(200, "[\(reportJSON("a"))]")
        await first?.value
        XCTAssertEqual(store.reports.map(\.id), ["b"])
        XCTAssertNil(store.lastError)
    }

    func testMergesByIDAndDropsExpired() async throws {
        server.responses = [(200, """
        [\(reportJSON("new", created: "2026-10-22T10:20:00Z")),
         \(reportJSON("old")),
         \(reportJSON("gone", expires: "2026-10-22T10:29:59Z"))]
        """)]
        store.setRegion(areaA)
        await store.work?.value
        XCTAssertEqual(store.reports.map(\.id), ["new", "old"])

        // A failed refresh keeps what is shown, minus anything expired.
        server.responses = [(500, "")]
        store.setRegion(areaA)
        await store.work?.value
        XCTAssertEqual(store.lastError as? ReportsError, .http(status: 500, message: nil))
        XCTAssertEqual(store.reports.map(\.id), ["new", "old"])
        clock = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-22T11:00:00Z"))
        server.responses = [(500, "")]
        store.setRegion(areaA)
        await store.work?.value
        XCTAssertEqual(store.reports, [])
    }

    func testOptimisticReportRollsBackOnFailure() async throws {
        server.responses = [(200, "[\(reportJSON("old"))]")]
        store.setRegion(areaA)
        await store.work?.value

        let here = CLLocationCoordinate2D(latitude: 3.15, longitude: 101.7)
        let posting = Task { try await store.report(.flood, at: here) }
        await waitForPending()
        XCTAssertEqual(store.reports.count, 2)
        let draft = try XCTUnwrap(store.reports.first)
        XCTAssertEqual(draft.type, .flood)
        XCTAssertEqual(draft.expiresAt, fixtureNow.addingTimeInterval(120 * 60))
        XCTAssertTrue(store.votable.map(\.id) == ["old"], "drafts can't be voted on")

        server.resume(429, #"{"error": "rate limit: 10 reports per hour"}"#)
        do {
            _ = try await posting.value
            XCTFail("expected rateLimited")
        } catch {
            XCTAssertEqual(error as? ReportsError, .rateLimited)
        }
        XCTAssertEqual(store.reports.map(\.id), ["old"])
        XCTAssertTrue(store.mine.isEmpty)
    }

    func testOptimisticReportIsReplacedByServerCopy() async throws {
        store.setRegion(areaA)
        server.responses = [(200, "[]"), (201, reportJSON("mine", created: "2026-10-22T10:30:00Z"))]
        await store.work?.value
        let saved = try await store.report(.police, at: CLLocationCoordinate2D(latitude: 3.15, longitude: 101.71))
        XCTAssertEqual(saved.id, "mine")
        XCTAssertEqual(store.reports.map(\.id), ["mine"])
        XCTAssertEqual(store.mine, ["mine"])
        XCTAssertTrue(store.votable.isEmpty)

        // A refresh that already lists it shows it once; one that started
        // before the post (so lacks it) doesn't hide it.
        server.responses = [(200, "[\(reportJSON("mine", created: "2026-10-22T10:30:00Z", upvotes: 3))]")]
        store.setRegion(areaA)
        await store.work?.value
        XCTAssertEqual(store.reports.map(\.upvotes), [3])
    }

    func testOwnReportSurvivesARefreshThatPredatesIt() async throws {
        store.setRegion(areaA)
        server.responses = [(200, "[]"), (201, reportJSON("mine"))]
        await store.work?.value
        try await store.report(.police, at: CLLocationCoordinate2D(latitude: 3.15, longitude: 101.71))
        server.responses = [(200, "[]")]
        store.setRegion(areaA)
        await store.work?.value
        XCTAssertEqual(store.reports.map(\.id), ["mine"])
    }

    func testVoteUpdatesOrRemovesReport() async throws {
        server.responses = [(200, "[\(reportJSON("a")), \(reportJSON("b"))]")]
        store.setRegion(areaA)
        await store.work?.value

        server.responses = [(200, reportJSON("a", expires: "2026-10-22T11:30:00Z", upvotes: 1))]
        try await store.vote("a", stillThere: true)
        XCTAssertEqual(store.reports.first { $0.id == "a" }?.upvotes, 1)

        // The second "gone" vote expires it now on the server.
        server.responses = [(200, reportJSON("b", expires: "2026-10-22T10:30:00Z", downvotes: 2))]
        try await store.vote("b", stillThere: false)
        XCTAssertEqual(store.reports.map(\.id), ["a"])

        server.responses = [(409, #"{"error": "already voted"}"#)]
        do {
            try await store.vote("a", stillThere: true)
            XCTFail("expected conflict")
        } catch {
            XCTAssertEqual(error as? ReportsError, .conflict)
        }
        XCTAssertEqual(store.reports.map(\.id), ["a"])
    }

    func testRefreshesEveryMinute() async throws {
        var ticks = 0
        let store = ReportsStore(client: server.client, now: { fixtureNow }, sleep: { seconds in
            guard seconds == ReportsStore.refreshInterval else { return try Task.checkCancellation() }
            ticks += 1
            // One quick tick, then park until stop().
            try await Task.sleep(for: ticks == 1 ? .milliseconds(10) : .seconds(3600))
        }, defaults: defaults)
        server.responses = [(200, "[]"), (200, "[]"), (200, "[\(reportJSON("a"))]")]
        store.setRegion(areaA)
        await store.work?.value
        store.start() // loads at once, then once a minute
        let deadline = Date().addingTimeInterval(5)
        while server.requests.count < 3, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        await store.work?.value
        store.stop()
        XCTAssertEqual(store.reports.map(\.id), ["a"])
        XCTAssertEqual(server.requests.count, 3)
    }
}

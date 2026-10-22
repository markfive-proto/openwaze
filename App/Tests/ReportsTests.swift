import CoreLocation
@testable import OpenWaze
import XCTest

/// Answers requests from `responses` in order; once they run out, requests
/// wait in `pending` until the test resumes them.
final class FakeServer {
    var requests: [URLRequest] = []
    var responses: [(status: Int, body: String)] = []
    var pending: [(URLRequest, CheckedContinuation<(Data, URLResponse), Error>)] = []

    func fetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        if !responses.isEmpty {
            let (status, body) = responses.removeFirst()
            return Self.reply(request, status, body)
        }
        return try await withCheckedThrowingContinuation { pending.append((request, $0)) }
    }

    func resume(_ status: Int, _ body: String) {
        let (request, continuation) = pending.removeFirst()
        continuation.resume(returning: Self.reply(request, status, body))
    }

    static func reply(_ request: URLRequest, _ status: Int, _ body: String) -> (Data, URLResponse) {
        (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    var client: ReportsClient {
        ReportsClient(baseURL: URL(string: "http://test.local:8787/")!, deviceID: "device-1", fetch: fetch)
    }
}

func reportJSON(
    _ id: String, type: String = "police", lat: Double = 3.15, lng: Double = 101.71,
    created: String = "2026-10-22T10:00:00Z", expires: String = "2026-10-22T11:00:00Z",
    upvotes: Int = 0, downvotes: Int = 0
) -> String {
    """
    {"id": "\(id)", "type": "\(type)", "lat": \(lat), "lng": \(lng), "createdAt": "\(created)",
     "expiresAt": "\(expires)", "upvotes": \(upvotes), "downvotes": \(downvotes)}
    """
}

/// 2026-10-22T10:30:00Z, between the fixtures' created and expires times.
let fixtureNow = ISO8601DateFormatter().date(from: "2026-10-22T10:30:00Z")!

@MainActor
final class ReportsClientTests: XCTestCase {
    let server = FakeServer()

    func testTypesMatchServerAndCarryUIHints() {
        let types = ["police", "accident", "hazard", "traffic", "closure", "flood"]
        XCTAssertEqual(ReportType.allCases.map(\.rawValue), types)
        XCTAssertEqual(ReportType.flood.colorToken, "reportFlood")
        XCTAssertEqual(ReportType.flood.symbol, "water.waves")
        XCTAssertEqual(ReportType.flood.title, "Flood")
        XCTAssertEqual(ReportType.flood.lifetime, 120 * 60)
        XCTAssertEqual(ReportType.traffic.lifetime, 30 * 60)
        XCTAssertEqual(ReportType.police.lifetime, 60 * 60)
    }

    func testParsesReportsAndSkipsBadOnes() throws {
        let data = Data("""
        [\(reportJSON("a", type: "flood", upvotes: 2)),
         \(reportJSON("ufo", type: "ufo")),
         \(reportJSON("bad-date", created: "yesterday")),
         {"id": "partial"},
         \(reportJSON("b", type: "traffic", lat: 1.3521, lng: 103.8198))]
        """.utf8)
        let reports = try ReportsClient.parse(data)
        XCTAssertEqual(reports.map(\.id), ["a", "b"])
        XCTAssertEqual(reports[0].type, .flood)
        XCTAssertEqual(reports[0].upvotes, 2)
        XCTAssertEqual(reports[0].createdAt, ISO8601DateFormatter().date(from: "2026-10-22T10:00:00Z"))
        XCTAssertEqual(reports[1].coordinate.latitude, 1.3521)
        XCTAssertThrowsError(try ReportsClient.parse(Data(#"{"error": "nope"}"#.utf8)))
    }

    func testListSendsBBoxQuery() async throws {
        server.responses = [(200, "[\(reportJSON("a"))]")]
        let reports = try await server.client.list(BBox(minLat: 3.1, minLng: 101.6, maxLat: 3.2, maxLng: 101.8))
        XCTAssertEqual(reports.map(\.id), ["a"])
        XCTAssertEqual(
            server.requests[0].url?.absoluteString,
            "http://test.local:8787/reports?minLat=3.1&minLng=101.6&maxLat=3.2&maxLng=101.8"
        )
        XCTAssertEqual(server.requests[0].httpMethod, "GET")
    }

    func testCreateAndVotePostJSON() async throws {
        server.responses = [(201, reportJSON("new", type: "flood")), (200, reportJSON("x", upvotes: 1))]
        let here = CLLocationCoordinate2D(latitude: 3.15, longitude: 101.71)
        let created = try await server.client.create(.flood, at: here)
        XCTAssertEqual(created.id, "new")
        let voted = try await server.client.vote("x", stillThere: true)
        XCTAssertEqual(voted.upvotes, 1)

        let (create, vote) = (server.requests[0], server.requests[1])
        XCTAssertEqual(create.httpMethod, "POST")
        XCTAssertEqual(create.url?.absoluteString, "http://test.local:8787/reports")
        XCTAssertEqual(create.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(create.httpBody)) as? [String: Any])
        XCTAssertEqual(body["type"] as? String, "flood")
        XCTAssertEqual(body["lat"] as? Double, 3.15)
        XCTAssertEqual(body["lng"] as? Double, 101.71)
        XCTAssertEqual(body["deviceId"] as? String, "device-1")

        XCTAssertEqual(vote.url?.absoluteString, "http://test.local:8787/reports/x/vote")
        let voteBody = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(vote.httpBody)) as? [String: Any])
        XCTAssertEqual(voteBody["stillThere"] as? Bool, true)
        XCTAssertEqual(voteBody["deviceId"] as? String, "device-1")
    }

    func testMapsErrorStatuses() async {
        let cases: [(Int, ReportsError)] = [
            (429, .rateLimited),
            (404, .notFound),
            (409, .conflict),
            (400, .http(status: 400, message: "lat must be a number in -90..90")),
            (413, .http(status: 413, message: "body too large")),
            (500, .http(status: 500, message: nil)),
        ]
        for (status, expected) in cases {
            let body = switch status {
            case 400: #"{"error": "lat must be a number in -90..90"}"#
            case 413: #"{"error": "body too large"}"#
            case 500: "<html>oops</html>"
            default: #"{"error": "whatever"}"#
            }
            server.responses = [(status, body)]
            do {
                _ = try await server.client.vote("x", stillThere: false)
                XCTFail("expected \(expected)")
            } catch {
                XCTAssertEqual(error as? ReportsError, expected, "status \(status)")
            }
        }
    }

    func testBaseURLFromBuildSetting() {
        let hosted = "https://reports.example.org/v1/"
        XCTAssertEqual(ReportsClient.url(from: hosted).absoluteString, hosted)
        XCTAssertEqual(ReportsClient.url(from: nil), ReportsClient.defaultBaseURL)
        XCTAssertEqual(ReportsClient.url(from: ""), ReportsClient.defaultBaseURL)
        XCTAssertEqual(ReportsClient.url(from: "$(OPENWAZE_API_URL)"), ReportsClient.defaultBaseURL)
        // The app's Info.plist carries the build setting.
        XCTAssertEqual(ReportsClient.baseURL.absoluteString, "http://localhost:8787")
    }

    func testBBoxClampsToServerLimits() {
        let wide = BBox(minLat: -10, minLng: 95, maxLat: 10, maxLng: 115).clamped
        XCTAssertEqual(wide, BBox(minLat: -1, minLng: 104, maxLat: 1, maxLng: 106))
        let small = BBox(minLat: 3.1, minLng: 101.6, maxLat: 3.2, maxLng: 101.8)
        XCTAssertEqual(small.clamped, small)
        XCTAssertEqual(BBox(minLat: 88, minLng: 0, maxLat: 95, maxLng: 1).clamped.maxLat, 90)
    }

    func testDeviceIDIsGeneratedOnceAndStored() {
        let service = "org.openwaze.tests.\(UUID().uuidString)"
        defer {
            SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service] as CFDictionary)
        }
        let first = DeviceID.load(service: service)
        XCTAssertNotNil(UUID(uuidString: first))
        XCTAssertEqual(DeviceID.load(service: service), first)
        XCTAssertEqual(DeviceID.current, DeviceID.current)
        XCTAssertNotEqual(DeviceID.load(service: service + ".other"), first)
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service + ".other"] as CFDictionary)
    }
}

@MainActor
final class ReportsStoreTests: XCTestCase {
    let server = FakeServer()
    var delays: [TimeInterval] = []
    var clock = fixtureNow
    lazy var store = ReportsStore(
        client: server.client,
        now: { [unowned self] in clock },
        sleep: { [unowned self] seconds in
            delays.append(seconds)
            try Task.checkCancellation()
        }
    )

    let areaA = BBox(minLat: 3.1, minLng: 101.6, maxLat: 3.2, maxLng: 101.8)
    let areaB = BBox(minLat: 3.0, minLng: 101.5, maxLat: 3.1, maxLng: 101.6)

    func waitForPending() async {
        while server.pending.isEmpty {
            await Task.yield()
        }
    }

    func testDebouncesRegionChanges() async throws {
        server.responses = [(200, "[\(reportJSON("b", lat: 3.05, lng: 101.55))]")]
        store.setRegion(BBox(minLat: 0, minLng: 0, maxLat: 1, maxLng: 1))
        store.setRegion(areaA)
        store.setRegion(areaB)
        await store.work?.value
        XCTAssertEqual(server.requests.count, 1)
        XCTAssertTrue(try XCTUnwrap(server.requests[0].url?.query?.contains("minLat=3.0&minLng=101.5")))
        XCTAssertTrue(delays.allSatisfy { $0 == 0.5 })
        XCTAssertEqual(store.reports.map(\.id), ["b"])
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
        })
        server.responses = [(200, "[]"), (200, "[\(reportJSON("a"))]")]
        store.setRegion(areaA)
        await store.work?.value
        store.start()
        let deadline = Date().addingTimeInterval(5)
        while server.requests.count < 2, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        await store.work?.value
        store.stop()
        XCTAssertEqual(store.reports.map(\.id), ["a"])
        XCTAssertEqual(server.requests.count, 2)
    }
}

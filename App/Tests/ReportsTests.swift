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
        ReportsClient(baseURL: URL(string: "http://test.local:8787/")!, deviceID: { "device-1" }, fetch: fetch)
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

    func testDatesWithWholeOrFractionalSeconds() throws {
        let reports = try ReportsClient.parse(Data("""
        [\(reportJSON("whole", created: "2026-10-22T10:00:00Z")),
         \(reportJSON("millis", created: "2026-10-22T10:00:00.250Z", expires: "2026-10-22T11:00:00.000Z"))]
        """.utf8))
        XCTAssertEqual(reports.map(\.id), ["whole", "millis"])
        let whole = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-22T10:00:00Z"))
        XCTAssertEqual(reports[0].createdAt, whole)
        XCTAssertEqual(reports[1].createdAt.timeIntervalSince(whole), 0.25, accuracy: 0.001)
        XCTAssertEqual(reports[1].expiresAt, whole.addingTimeInterval(3600))
    }

    func testFailsClearlyWithoutServerOrDeviceID() async throws {
        var client = server.client
        client.baseURL = nil
        do {
            _ = try await client.list(BBox(minLat: 0, minLng: 0, maxLat: 1, maxLng: 1))
            XCTFail("expected notConfigured")
        } catch {
            XCTAssertEqual(error as? ReportsError, .notConfigured)
        }
        client = server.client
        client.deviceID = { nil }
        do {
            _ = try await client.vote("x", stillThere: true)
            XCTFail("expected noDeviceID")
        } catch {
            XCTAssertEqual(error as? ReportsError, .noDeviceID)
        }
        XCTAssertTrue(server.requests.isEmpty)
        var unconfigured = server.client
        unconfigured.baseURL = nil
        let store = try ReportsStore(client: unconfigured, defaults: XCTUnwrap(UserDefaults(suiteName: "unconfigured")))
        XCTAssertEqual(store.lastError as? ReportsError, .notConfigured)
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

    func testUIStringsAndColours() {
        XCTAssertEqual(reportProblem(ReportsError.rateLimited),
                       "You've sent a lot of reports this hour. Try again later.")
        XCTAssertEqual(reportProblem(URLError(.notConnectedToInternet)),
                       "Couldn't send the report. Check your connection.")
        let report = Report(
            id: "a", type: .flood, lat: 3, lng: 101, createdAt: fixtureNow.addingTimeInterval(-300),
            expiresAt: fixtureNow.addingTimeInterval(3600), upvotes: 3, downvotes: 1
        )
        XCTAssertEqual(reportDetail(report, now: fixtureNow), "Reported 5 minutes ago · 3 still there · 1 gone")
        for type in ReportType.allCases {
            XCTAssertNotNil(Theme.reportColors[type.colorToken], type.rawValue)
        }
    }

    func testBaseURLFromBuildSetting() {
        let hosted = "https://reports.example.org/v1/"
        XCTAssertEqual(ReportsClient.url(from: hosted)?.absoluteString, hosted)
        XCTAssertNil(ReportsClient.url(from: nil))
        XCTAssertNil(ReportsClient.url(from: ""))
        XCTAssertNil(ReportsClient.url(from: "$(OPENWAZE_API_URL)"))
        XCTAssertNil(ReportsClient.url(from: "localhost:8787"))
        // Debug's Info.plist carries the local default.
        XCTAssertEqual(ReportsClient.baseURL?.absoluteString, "http://localhost:8787")
    }

    func testBBoxClampsToServerLimits() {
        func assertValid(_ box: BBox, line: UInt = #line) {
            XCTAssertLessThanOrEqual(box.minLat, box.maxLat, line: line)
            XCTAssertLessThanOrEqual(box.minLng, box.maxLng, line: line)
            XCTAssertLessThanOrEqual(box.maxLat - box.minLat, BBox.maxSpan + 1e-9, line: line)
            XCTAssertLessThanOrEqual(box.maxLng - box.minLng, BBox.maxSpan + 1e-9, line: line)
            XCTAssertTrue((-90 ... 90).contains(box.minLat) && (-90 ... 90).contains(box.maxLat), line: line)
            XCTAssertTrue((-180 ... 180).contains(box.minLng) && (-180 ... 180).contains(box.maxLng), line: line)
        }
        let wide = BBox(minLat: -10, minLng: 95, maxLat: 10, maxLng: 115).clamped
        XCTAssertEqual(wide, BBox(minLat: -1, minLng: 104, maxLat: 1, maxLng: 106))
        let small = BBox(minLat: 3.1, minLng: 101.6, maxLat: 3.2, maxLng: 101.8)
        XCTAssertEqual(small.clamped, small)

        // Past the pole: shifted inside ±90, not inverted.
        let polar = BBox(minLat: 88, minLng: 0, maxLat: 95, maxLng: 1).clamped
        XCTAssertEqual(polar, BBox(minLat: 88, minLng: 0, maxLat: 90, maxLng: 1))
        XCTAssertEqual(BBox(minLat: 89.5, minLng: 0, maxLat: 95, maxLng: 1).clamped.minLat, 88)
        XCTAssertEqual(BBox(minLat: 2, minLng: 0, maxLat: 1, maxLng: 1).clamped.minLat, 1) // swapped input

        // Antimeridian: unwrapped, then shifted to the side of its centre.
        let fiji = BBox(minLat: -18, minLng: 179, maxLat: -17, maxLng: -179.5).clamped // centre 179.75
        XCTAssertEqual(fiji.maxLng, 180)
        XCTAssertEqual(fiji.minLng, 178.5, accuracy: 1e-9)
        let wrapped = BBox(minLat: 3, minLng: 461.6, maxLat: 3.1, maxLng: 461.8).clamped // KL, one world east
        XCTAssertEqual(wrapped.minLng, 101.6, accuracy: 1e-9)
        for box in [wide, polar, fiji, wrapped, BBox(minLat: -100, minLng: -200, maxLat: 100, maxLng: 200).clamped] {
            assertValid(box)
        }
        XCTAssertFalse(BBox(minLat: 2, minLng: 2, maxLat: 1, maxLng: 1).contains(.init(latitude: 1.5, longitude: 1.5)))
    }

    func testDeviceIDIsStoredAndResetOnReinstall() throws {
        let service = "org.openwaze.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: service))
        defer {
            SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service] as CFDictionary)
            defaults.removePersistentDomain(forName: service)
        }
        let device = DeviceID(service: service, defaults: defaults)
        let first = try XCTUnwrap(device.value)
        XCTAssertNotNil(UUID(uuidString: first))

        device.clearCache() // next read comes from the Keychain, not memory
        XCTAssertEqual(device.value, first)
        XCTAssertEqual(DeviceID(service: service, defaults: defaults).value, first, "a relaunch keeps it")

        // A reinstall wipes UserDefaults (the install marker) but not the Keychain.
        defaults.removePersistentDomain(forName: service)
        let reinstalled = try XCTUnwrap(DeviceID(service: service, defaults: defaults).value)
        XCTAssertNotEqual(reinstalled, first)
        XCTAssertEqual(DeviceID(service: service, defaults: defaults).value, reinstalled)
    }
}

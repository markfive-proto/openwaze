import CoreLocation
@testable import OpenWaze
import XCTest

/// Runs against a live reports server at the app's OPENWAZE_API_URL
/// (`cd server && npm run dev`); skipped when none is reachable, as on CI.
final class ReportsIntegrationTests: XCTestCase {
    func client() -> ReportsClient {
        ReportsClient(deviceID: "it-\(UUID().uuidString)")
    }

    func testTwoDevicesSeeAndVoteOnEachOthersReports() async throws {
        var health = URLRequest(url: ReportsClient.baseURL.appending(path: "health"), timeoutInterval: 2)
        health.httpMethod = "GET"
        guard let (_, response) = try? await URLSession.shared.data(for: health),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { throw XCTSkip("No reports server at \(ReportsClient.baseURL)") }

        let (alice, bob) = (client(), client())
        // A random spot, so repeated runs do not see each other.
        let spot = CLLocationCoordinate2D(latitude: 2 + .random(in: 0 ..< 1), longitude: 100 + .random(in: 0 ..< 1))
        let created = try await alice.create(.flood, at: spot)
        XCTAssertEqual(created.type, .flood)
        XCTAssertEqual(created.expiresAt.timeIntervalSince(created.createdAt), 120 * 60, accuracy: 1)

        let box = BBox(
            minLat: spot.latitude - 0.01, minLng: spot.longitude - 0.01,
            maxLat: spot.latitude + 0.01, maxLng: spot.longitude + 0.01
        )
        let seen = try await bob.list(box)
        XCTAssertEqual(seen.first { $0.id == created.id }, created)

        let voted = try await bob.vote(created.id, stillThere: true)
        XCTAssertEqual(voted.upvotes, 1)
        await assertThrows(.conflict) { _ = try await bob.vote(created.id, stillThere: true) }
        await assertThrows(.conflict) { _ = try await alice.vote(created.id, stillThere: true) }
        await assertThrows(.notFound) { _ = try await bob.vote(UUID().uuidString, stillThere: true) }
        await assertThrows(.http(status: 400, message: "bbox span must be <= 2 degrees per axis")) {
            _ = try await bob.list(BBox(minLat: 0, minLng: 0, maxLat: 3, maxLng: 1))
        }
    }

    func assertThrows(_ expected: ReportsError, line: UInt = #line, _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("expected \(expected)", line: line)
        } catch {
            XCTAssertEqual(error as? ReportsError, expected, line: line)
        }
    }
}

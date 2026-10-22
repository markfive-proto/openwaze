@testable import OpenWaze
import SwiftData
import XCTest

@MainActor
final class PlacesTests: XCTestCase {
    var context: ModelContext!

    override func setUpWithError() throws {
        let container = try ModelContainer(
            for: Place.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
    }

    func place(_ number: Int) -> Destination {
        Destination(id: "N\(number)", name: "Place \(number)", address: "Kuala Lumpur",
                    latitude: 3.15, longitude: 101.71)
    }

    func recentIDs() throws -> [String] {
        try Places.all(.recent, in: context).map(\.placeID)
    }

    func testNewestFirst() throws {
        let start = Date(timeIntervalSince1970: 0)
        for number in 1 ... 3 {
            try Places.recordRecent(place(number), in: context, now: start + Double(number))
        }
        XCTAssertEqual(try recentIDs(), ["N3", "N2", "N1"])
    }

    func testRepeatMovesToTopWithoutDuplicate() throws {
        let start = Date(timeIntervalSince1970: 0)
        try Places.recordRecent(place(1), in: context, now: start + 1)
        try Places.recordRecent(place(2), in: context, now: start + 2)
        try Places.recordRecent(place(1), in: context, now: start + 3)
        XCTAssertEqual(try recentIDs(), ["N1", "N2"])
    }

    func testKeepsOnlyTheNewestTen() throws {
        let start = Date(timeIntervalSince1970: 0)
        for number in 1 ... 12 {
            try Places.recordRecent(place(number), in: context, now: start + Double(number))
        }
        XCTAssertEqual(try recentIDs(), (3 ... 12).reversed().map { "N\($0)" })
        // A repeat at the cap drops nothing else.
        try Places.recordRecent(place(5), in: context, now: start + 13)
        XCTAssertEqual(try recentIDs().count, 10)
        XCTAssertEqual(try recentIDs().first, "N5")
        XCTAssertTrue(try recentIDs().contains("N3"))
    }

    func testHomeIsReplacedAndSeparateFromRecents() throws {
        try Places.save(place(1), as: .home, in: context)
        try Places.save(place(2), as: .home, in: context)
        try Places.recordRecent(place(2), in: context)
        XCTAssertEqual(try Places.all(.home, in: context).map(\.placeID), ["N2"])
        XCTAssertEqual(try recentIDs(), ["N2"])
        XCTAssertTrue(try Places.all(.work, in: context).isEmpty)
    }
}

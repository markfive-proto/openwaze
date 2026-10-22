import CoreLocation
@testable import OpenWaze
import SwiftData
import XCTest

@MainActor
final class HomeModelTests: XCTestCase {
    let home = Destination(id: "W42", name: "Home", address: "", latitude: 3.009, longitude: 101.709)
    var context: ModelContext!

    override func setUpWithError() throws {
        let container = try ModelContainer(
            for: Place.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
    }

    func makeModel() -> HomeModel {
        let route = NavigatorTests.lRoute()
        let navigator = Navigator(fetchRoutes: { _, _ in [route] }, speech: NavigatorTests.FakeSpeech(), feed: nil)
        return HomeModel(navigator: navigator, context: context, origin: { NavigatorTests.origin })
    }

    /// Expanded search -> Home shortcut -> Go -> Start -> End must land back
    /// on the normal home screen, not a collapsed sheet with hidden controls.
    func testShortcutFromExpandedSearchThenEndRestoresHome() async {
        let model = makeModel()
        model.searching = true
        XCTAssertFalse(model.showsControls)

        model.go(home)
        XCTAssertFalse(model.searching)
        await model.preview?.value
        XCTAssertEqual(model.panel, .trip)
        XCTAssertEqual(model.navigator.phase, .preview)

        model.start()
        XCTAssertEqual(model.panel, .driving)
        XCTAssertTrue(model.showsControls)

        model.endTrip()
        XCTAssertEqual(model.panel, .search)
        XCTAssertNil(model.destination)
        XCTAssertTrue(model.showsControls)
        XCTAssertTrue(model.showsMenu)
        XCTAssertEqual(try Places.all(.recent, in: context).map(\.placeID), ["W42"])
    }

    func testClosingPreviewReturnsToPlaceCard() async {
        let model = makeModel()
        model.go(home)
        await model.preview?.value
        model.closeTrip()
        XCTAssertEqual(model.panel, .place(home))
        XCTAssertTrue(model.showsControls)
    }

    func testNavigatingNeverShowsTripCard() async {
        let model = makeModel()
        model.go(home)
        await model.preview?.value
        model.start()
        XCTAssertEqual(model.panel, .driving)
        XCTAssertFalse(model.showsRecenter) // following until the user pans
        model.following = false
        XCTAssertTrue(model.showsRecenter)
    }
}

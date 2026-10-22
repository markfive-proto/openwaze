import XCTest

/// Scripted walkthrough for the demo video (#52): search, route, drive, report, end.
/// Run by `scripts/demo/record.sh`, not by `make test`. Needs the local reports
/// server (`DEMO_API_URL`, else the Debug default http://localhost:8787) and network for Photon and OSRM.
/// Pauses are for viewers, not for correctness.
final class DemoTour: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testDemoTour() {
        let app = XCUIApplication()
        app.launchArguments = ["-ShowTouches", "YES"]
        if let api = ProcessInfo.processInfo.environment["DEMO_API_URL"] {
            app.launchArguments += ["-OPENWAZE_API_URL", api]
        }
        app.launch()

        let field = app.textFields["search.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 30))
        pause(2)
        field.tap()
        pause(1)
        type("Pavilion Kuala Lumpur", into: field)

        let result = app.buttons["search.result"].firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 30), "no search result")
        pause(2)
        result.tap()

        let goButton = app.buttons["destination.go"]
        XCTAssertTrue(goButton.waitForExistence(timeout: 10))
        pause(2)
        goButton.tap()

        let start = app.buttons["trip.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 60), "no route preview")
        pause(4) // route preview
        start.tap()
        signalDriveStarted()

        let end = app.buttons["trip.end"]
        XCTAssertTrue(end.waitForExistence(timeout: 10))
        pause(30) // the drive plays

        app.buttons["report.button"].tap()
        let hazard = app.buttons["report.hazard"]
        XCTAssertTrue(hazard.waitForExistence(timeout: 10))
        pause(2)
        hazard.tap()
        pause(8) // the report lands on the map

        end.tap()
        pause(3)
    }

    /// One character at a time, so the typing reads as a person's.
    private func type(_ text: String, into field: XCUIElement) {
        for character in text {
            field.typeText(String(character))
            pause(0.09)
        }
    }

    /// Tells the recording script the drive can begin (`DEMO_MARKER` file).
    private func signalDriveStarted() {
        guard let path = ProcessInfo.processInfo.environment["DEMO_MARKER"] else { return }
        FileManager.default.createFile(atPath: path, contents: nil)
    }

    private func pause(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }
}

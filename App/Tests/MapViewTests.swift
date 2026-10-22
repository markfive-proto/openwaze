import CoreLocation
import MapLibre
@testable import OpenWaze
import XCTest

@MainActor
final class MapViewTests: XCTestCase {
    func fix(accuracy: CLLocationAccuracy = 5) -> CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 3.1579, longitude: 101.7116),
            altitude: 0, horizontalAccuracy: accuracy, verticalAccuracy: -1, timestamp: Date()
        )
    }

    /// #50: the first-fix zoom must leave the map following the user, or the
    /// dot drives off screen and the reports area never changes.
    func testFirstFixZoomKeepsFollowing() {
        let map = MLNMapView(frame: CGRect(x: 0, y: 0, width: 300, height: 600), styleURL: nil)
        map.userTrackingMode = .follow
        let coordinator = MapView.Coordinator()
        coordinator.animated = false
        coordinator.zoom(toFirstFix: fix(), on: map)
        XCTAssertEqual(map.userTrackingMode, .follow)
        XCTAssertEqual(map.zoomLevel, Zoom.max, accuracy: 0.01)
    }

    func testVagueFirstFixDoesNotZoom() {
        let map = MLNMapView(frame: CGRect(x: 0, y: 0, width: 300, height: 600), styleURL: nil)
        let coordinator = MapView.Coordinator()
        coordinator.animated = false
        coordinator.zoom(toFirstFix: fix(accuracy: Zoom.maxFixAccuracy + 1), on: map)
        XCTAssertEqual(map.zoomLevel, 0, accuracy: 0.01)
        coordinator.zoom(toFirstFix: fix(), on: map)
        XCTAssertEqual(map.zoomLevel, Zoom.max, accuracy: 0.01, "a later good fix still zooms")
        coordinator.zoom(toFirstFix: fix(accuracy: 100), on: map)
        XCTAssertEqual(map.zoomLevel, Zoom.max, accuracy: 0.01, "only the first fix sets the zoom")
    }
}

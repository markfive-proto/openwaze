import CoreLocation
import MapLibre
import SwiftUI

/// Full-screen MapLibre map that follows the user's location until a
/// destination is picked, then pins and centres on it. With a route it
/// draws the line and fits it on screen; while navigating it follows the
/// user heading-up.
struct MapView: UIViewRepresentable {
    var destination: Destination?
    var route: Route?
    var navigating = false
    /// While navigating: whether the camera follows the user. Panning the map
    /// calls `onUnfollow`; the app sets this back to re-centre.
    var following = true
    var onUnfollow: () -> Void = {}
    /// Bump to snap the camera back to the user when not navigating.
    var recenter = 0
    /// Height of the bottom chrome; keeps the route and OSM attribution above it.
    var bottomInset: CGFloat = 0
    /// Crowd reports to show as icons (ReportsUI.swift).
    var reports: [Report] = []
    /// Called with the visible area after the map moves.
    var onRegion: (BBox) -> Void = { _ in }

    /// What the map last showed, so SwiftUI updates only redo what changed.
    struct State: Equatable {
        var destination: Destination?
        var route: UUID?
        var navigating = false
        var following = true
        var recenter = 0
        var bottomInset: CGFloat = 0
    }

    static let styleURL = URL(string: "https://tiles.openfreemap.org/styles/liberty")!
    /// Camera tilt while driving; the car puck lies flat on the tilted road.
    static let drivingPitch: CGFloat = 50

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> MLNMapView {
        let map = MLNMapView(frame: .zero, styleURL: Self.styleURL)
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.showsUserHeadingIndicator = true // compass heading reaches the puck while browsing
        map.userTrackingMode = .follow
        return map
    }

    func updateUIView(_ map: MLNMapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.sync(reports: reports, onRegion: onRegion, on: map)
        let state = State(
            destination: destination, route: route?.id, navigating: navigating, following: following,
            recenter: recenter, bottomInset: bottomInset
        )
        guard state != coordinator.shown else { return }
        let previous = coordinator.shown
        coordinator.shown = state
        coordinator.route = route
        coordinator.onUnfollow = onUnfollow
        let animated = !context.environment.accessibilityReduceMotion
        coordinator.animated = animated
        // Heading-up driving rotates the map constantly; the compass would just sit behind the banner.
        map.compassView.compassVisibility = navigating ? .hidden : .adaptive
        coordinator.drawRoute(on: map)
        // Keep the OSM attribution and logo visible above the bottom card.
        let bottom = 8 + bottomInset
        map.logoViewMargins = CGPoint(x: 8, y: bottom)
        map.attributionButtonMargins = CGPoint(x: 8, y: bottom)
        if destination != previous.destination {
            Self.pin(destination, on: map)
        }
        if recenter != previous.recenter, !navigating {
            map.setUserTrackingMode(.follow, animated: animated, completionHandler: nil)
            return
        }
        if navigating {
            guard following, !previous.navigating || !previous.following else { return }
            coordinator.movingCamera = true // our own camera moves are not the user panning
            map.setZoomLevel(17, animated: false)
            Self.pitch(map, to: Self.drivingPitch, animated: false)
            map.setUserTrackingMode(.followWithCourse, animated: animated, completionHandler: nil)
            coordinator.movingCamera = false
        } else if let route {
            guard route.id != previous.route || previous.navigating else { return }
            var line = route.coordinates
            map.userTrackingMode = .none
            Self.pitch(map, to: 0, animated: false)
            map.direction = 0
            map.setVisibleCoordinates(
                &line, count: UInt(line.count),
                edgePadding: UIEdgeInsets(top: 120, left: 40, bottom: 40 + Theme.fab + bottomInset, right: 40),
                animated: animated
            )
        } else if let destination {
            guard destination != previous.destination || previous.route != nil else { return }
            map.userTrackingMode = .none
            map.setCenter(destination.coordinate, zoomLevel: 16, animated: animated)
        } else {
            map.userTrackingMode = .follow
        }
    }

    static func pitch(_ map: MLNMapView, to degrees: CGFloat, animated: Bool) {
        let camera = map.camera
        camera.pitch = degrees
        map.setCamera(camera, animated: animated)
    }

    /// Replaces the destination pin, leaving report icons alone.
    static func pin(_ destination: Destination?, on map: MLNMapView) {
        map.removeAnnotations((map.annotations ?? []).filter { !($0 is ReportAnnotation) })
        if let destination {
            let pin = MLNPointAnnotation()
            pin.coordinate = destination.coordinate
            pin.title = destination.name
            map.addAnnotation(pin)
        }
    }

    final class Coordinator: NSObject, MLNMapViewDelegate {
        var shown = State()
        var route: Route?
        var onUnfollow: () -> Void = {}
        var onRegion: (BBox) -> Void = { _ in }
        var reports: [Report] = []
        var movingCamera = false
        var animated = true
        private var zoomedToFirstFix = false

        func mapView(_: MLNMapView, didChange mode: MLNUserTrackingMode, animated _: Bool) {
            guard shown.navigating, shown.following, !movingCamera, mode != .followWithCourse else { return }
            let onUnfollow = onUnfollow
            DispatchQueue.main.async(execute: onUnfollow) // not during a SwiftUI update
        }

        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            // Flat map: 3D buildings hide the road and the route at driving zooms.
            for layer in style.layers where layer is MLNFillExtrusionStyleLayer {
                layer.isVisible = false
            }
            drawRoute(on: mapView) // a route may arrive before the style
        }

        /// Puts the current route (or nothing) in a line layer under the labels.
        func drawRoute(on map: MLNMapView) {
            guard let style = map.style else { return }
            // MapLibre throws on an empty polyline, so no route means no shape.
            let shape = route.map { route in
                var line = route.coordinates
                return MLNPolylineFeature(coordinates: &line, count: UInt(line.count))
            }
            if let source = style.source(withIdentifier: "route") as? MLNShapeSource {
                source.shape = shape
                return
            }
            let source = MLNShapeSource(identifier: "route", shape: shape, options: nil)
            style.addSource(source)
            let layer = MLNLineStyleLayer(identifier: "route", source: source)
            layer.lineColor = NSExpression(forConstantValue: UIColor(Theme.accentFill))
            layer.lineWidth = NSExpression(forConstantValue: 7)
            layer.lineCap = NSExpression(forConstantValue: "round")
            layer.lineJoin = NSExpression(forConstantValue: "round")
            if let labels = style.layers.first(where: { $0 is MLNSymbolStyleLayer }) {
                style.insertLayer(layer, below: labels)
            } else {
                style.addLayer(layer)
            }
        }

        func mapView(_ mapView: MLNMapView, didUpdate userLocation: MLNUserLocation?) {
            guard !zoomedToFirstFix,
                  shown.destination == nil, // don't yank the map off a picked destination
                  let location = userLocation?.location,
                  Zoom.isUsableFirstFix(location) else { return }
            zoomedToFirstFix = true
            mapView.setCenter(
                location.coordinate,
                zoomLevel: Zoom.level(forAccuracy: location.horizontalAccuracy),
                animated: animated
            )
        }
    }
}

/// Asks for when-in-use location access and tracks whether it was refused.
@Observable
final class LocationAuthorization: NSObject, CLLocationManagerDelegate {
    private(set) var isDenied = false
    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
    }

    /// Last known fix, used to bias search results.
    var coordinate: CLLocationCoordinate2D? {
        manager.location?.coordinate
    }

    func request() {
        manager.requestWhenInUseAuthorization()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        isDenied = [.denied, .restricted].contains(manager.authorizationStatus)
    }
}

struct LocationHint: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            if let url = URL(string: UIApplication.openSettingsURLString) {
                openURL(url)
            }
        } label: {
            Label("Enable location in Settings", systemImage: "location.slash.fill")
        }
        .buttonStyle(PrimaryButtonStyle())
        .padding(.horizontal, Theme.Space.medium)
    }
}

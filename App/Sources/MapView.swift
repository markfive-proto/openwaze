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

    /// What the map last showed, so SwiftUI updates only redo what changed.
    struct State: Equatable {
        var destination: Destination?
        var route: UUID?
        var navigating = false
    }

    static let styleURL = URL(string: "https://tiles.openfreemap.org/styles/liberty")!

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> MLNMapView {
        let map = MLNMapView(frame: .zero, styleURL: Self.styleURL)
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.userTrackingMode = .follow
        return map
    }

    func updateUIView(_ map: MLNMapView, context: Context) {
        let coordinator = context.coordinator
        let state = State(destination: destination, route: route?.id, navigating: navigating)
        guard state != coordinator.shown else { return }
        let previous = coordinator.shown
        coordinator.shown = state
        coordinator.route = route
        coordinator.drawRoute(on: map)
        // Keep the OSM attribution and logo visible above the bottom card.
        let bottom = 8 + (destination == nil ? 0 : DestinationCard.height)
        map.logoViewMargins = CGPoint(x: 8, y: bottom)
        map.attributionButtonMargins = CGPoint(x: 8, y: bottom)
        if destination != previous.destination {
            map.removeAnnotations(map.annotations ?? [])
            if let destination {
                let pin = MLNPointAnnotation()
                pin.coordinate = destination.coordinate
                pin.title = destination.name
                map.addAnnotation(pin)
            }
        }
        if navigating {
            map.setZoomLevel(17, animated: false)
            map.setUserTrackingMode(.followWithCourse, animated: true, completionHandler: nil)
        } else if let route {
            guard route.id != previous.route || previous.navigating else { return }
            var line = route.coordinates
            map.userTrackingMode = .none
            map.direction = 0
            map.setVisibleCoordinates(
                &line, count: UInt(line.count),
                edgePadding: UIEdgeInsets(top: 120, left: 40, bottom: 40 + DestinationCard.height, right: 40),
                animated: true
            )
        } else if let destination {
            guard destination != previous.destination || previous.route != nil else { return }
            map.userTrackingMode = .none
            map.setCenter(destination.coordinate, zoomLevel: 16, animated: true)
        } else {
            map.userTrackingMode = .follow
        }
    }

    final class Coordinator: NSObject, MLNMapViewDelegate {
        var shown = State()
        var route: Route?
        private var zoomedToFirstFix = false

        func mapView(_ mapView: MLNMapView, didFinishLoading _: MLNStyle) {
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
            layer.lineColor = NSExpression(forConstantValue: UIColor.systemBlue)
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
                animated: true
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
        Button("Enable location in Settings") {
            if let url = URL(string: UIApplication.openSettingsURLString) {
                openURL(url)
            }
        }
        .buttonStyle(.borderedProminent)
        .padding(.bottom, 40)
    }
}

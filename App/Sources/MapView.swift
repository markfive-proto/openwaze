import CoreLocation
import MapLibre
import SwiftUI

/// Full-screen MapLibre map that follows the user's location.
struct MapView: UIViewRepresentable {
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

    func updateUIView(_: MLNMapView, context _: Context) {}

    final class Coordinator: NSObject, MLNMapViewDelegate {
        private var zoomedToFirstFix = false

        func mapView(_ mapView: MLNMapView, didUpdate userLocation: MLNUserLocation?) {
            guard !zoomedToFirstFix,
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

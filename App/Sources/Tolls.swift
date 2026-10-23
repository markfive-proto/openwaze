import CoreLocation
import Foundation

/// A toll plaza from OSM (`barrier=toll_booth`), bundled in `TollPlazas.json`.
/// Fee fields (`system`, `rate`) are for #70 and decode as optional when added.
struct TollPlaza: Decodable, Equatable, Identifiable {
    /// OSM node id.
    let id: Int
    let name: String
    let lat: Double
    let lng: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }
}

enum Tolls {
    /// A plaza counts when the route passes this close to its booth node.
    /// OSRM's full geometry includes the node itself when the route is on that
    /// carriageway (distance ~0), while the opposite carriageway is 15 m or more
    /// away, so a small threshold tells them apart without a heading check.
    /// ponytail: lane-split plazas whose booth nodes sit on side ways (SMART
    /// Sungai Besi, 11+ m) are missed; snap plazas to ways at extract time if
    /// that matters for #70.
    static let threshold = 10.0 // metres

    /// Plazas the route drives through, in route order.
    static func plazas(
        on route: Geo.Line, in plazas: [TollPlaza] = bundled, within threshold: Double = threshold
    ) -> [TollPlaza] {
        guard route.count >= 2 else { return [] }
        // Cheap bounding-box reject (1e-5 deg is about 1 m) before projecting.
        let margin = threshold * 2 / 100_000
        let lat = route.map(\.latitude), lng = route.map(\.longitude)
        let box = (lat.min()! - margin ... lat.max()! + margin,
                   lng.min()! - margin ... lng.max()! + margin)
        return plazas
            .filter { box.0.contains($0.lat) && box.1.contains($0.lng) }
            .compactMap { plaza -> (TollPlaza, Geo.Projection)? in
                guard let hit = Geo.project(plaza.coordinate, onto: route),
                      hit.distance <= threshold else { return nil }
                return (plaza, hit)
            }
            .sorted { ($0.1.segment, $0.1.fraction) < ($1.1.segment, $1.1.fraction) }
            .map(\.0)
    }

    /// The bundled Malaysian dataset (ODbL, see the file header).
    static let bundled: [TollPlaza] = {
        guard let url = Bundle.main.url(forResource: "TollPlazas", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data)
        else {
            assertionFailure("TollPlazas.json missing or malformed")
            return []
        }
        return file.plazas.compactMap(\.value)
    }()

    private struct File: Decodable {
        let plazas: [HTTP.Lossy<TollPlaza>]
    }
}

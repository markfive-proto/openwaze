import CoreLocation
import Foundation

/// One cell of live traffic from `GET /traffic` (server/README.md): a ~110 m
/// grid cell, a heading bucket and a coarse level. Never a speed.
struct TrafficReading: Decodable, Equatable {
    enum Level: String, Decodable {
        case jam, slow, free

        /// Typical speed in m/s inside the server's band (jam < 15 km/h, slow < 40 km/h).
        /// Free-flow has none: OSRM's own time stands.
        var speed: Double? {
            switch self {
            case .jam: 8 / 3.6
            case .slow: 27 / 3.6
            case .free: nil
            }
        }
    }

    let lat: Double
    let lng: Double
    let heading: Int
    let level: Level
}

enum Traffic {
    typealias Fetch = (BBox) async throws -> [TrafficReading]

    /// Grid cell and direction, the way the server keys its probes.
    struct Key: Hashable {
        let lat: Int
        let lng: Int
        let heading: Int
    }

    /// Longest piece of road looked up as one unit; the cells are ~110 m.
    static let pieceLength = 100.0

    static func parse(_ data: Data) throws -> [TrafficReading] {
        try JSONDecoder().decode([HTTP.Lossy<TrafficReading>].self, from: data).compactMap(\.value)
    }

    static func index(_ readings: [TrafficReading]) -> [Key: TrafficReading.Level] {
        Dictionary(readings.map { (key(lat: $0.lat, lng: $0.lng, heading: Double($0.heading)), $0.level) },
                   uniquingKeysWith: { _, last in last })
    }

    static func key(lat: Double, lng: Double, heading: Double) -> Key {
        Key(lat: Int((lat * 1000).rounded()), lng: Int((lng * 1000).rounded()), heading: bucket(heading))
    }

    /// Eight 45 degree buckets: 0, 45, ... 315.
    static func bucket(_ degrees: Double) -> Int {
        let wrapped = degrees.truncatingRemainder(dividingBy: 360)
        return (Int((wrapped < 0 ? wrapped + 360 : wrapped) / 45 + 0.5) % 8) * 45
    }

    static func bearing(from start: CLLocationCoordinate2D, to end: CLLocationCoordinate2D) -> Double {
        let (east, north) = Geo.offset(end, from: start)
        return atan2(east, north) * 180 / .pi
    }

    /// Extra seconds on top of the route's free-flow time, for the parts of the
    /// road that have a slow or jam reading in the direction of travel. Roads
    /// without data, and free-flow roads, add nothing. Never negative.
    static func delay(of route: Route, levels: [Key: TrafficReading.Level]) -> Double {
        guard !levels.isEmpty, route.distance > 0, route.duration > 0 else { return 0 }
        let secondsPerMetre = route.duration / route.distance
        var delay = 0.0
        for index in 0 ..< max(0, route.coordinates.count - 1) {
            let (start, end) = (route.coordinates[index], route.coordinates[index + 1])
            let length = Geo.distance(start, end)
            guard length > 0 else { continue }
            let heading = bearing(from: start, to: end)
            let pieces = max(1, Int((length / pieceLength).rounded(.up)))
            for piece in 0 ..< pieces {
                let middle = (Double(piece) + 0.5) / Double(pieces)
                let lat = start.latitude + (end.latitude - start.latitude) * middle
                let lng = start.longitude + (end.longitude - start.longitude) * middle
                guard let speed = levels[key(lat: lat, lng: lng, heading: heading)]?.speed else { continue }
                let metres = length / Double(pieces)
                delay += max(0, metres / speed - metres * secondsPerMetre)
            }
        }
        return delay
    }

    /// The box around the route, grown outward to 0.01 degrees (~1 km) so the
    /// request does not carry the exact origin, then trimmed to what the server allows.
    static func box(around route: Route) -> BBox? {
        guard !route.coordinates.isEmpty else { return nil }
        let lats = route.coordinates.map(\.latitude), lngs = route.coordinates.map(\.longitude)
        // Hundredths of a degree; the 1e-6 keeps a value already on the grid (3.0) from stepping out a cell.
        func down(_ degrees: Double) -> Double {
            (degrees * 100 + 1e-6).rounded(.down) / 100
        }
        func up(_ degrees: Double) -> Double {
            (degrees * 100 - 1e-6).rounded(.up) / 100
        }
        return BBox(
            minLat: down(lats.min()!), minLng: down(lngs.min()!), maxLat: up(lats.max()!), maxLng: up(lngs.max()!)
        ).clamped
    }

    /// The routes with `trafficDelay` filled in. Traffic is a bonus: if it is
    /// unreachable, the routes come back as OSRM gave them.
    static func adjusted(_ routes: [Route], using fetch: Fetch?) async -> [Route] {
        guard let fetch, let box = union(routes), let readings = try? await fetch(box) else { return routes }
        let levels = index(readings)
        return routes.map { route in
            var route = route
            route.trafficDelay = delay(of: route, levels: levels)
            return route
        }
    }

    /// `adjusted`, fastest first. A stable sort, so ties keep OSRM's order.
    static func fastestFirst(_ routes: [Route], using fetch: Fetch?) async -> [Route] {
        let priced = await adjusted(routes, using: fetch)
        return priced.enumerated().sorted { ($0.element.eta, $0.offset) < ($1.element.eta, $1.offset) }.map(\.element)
    }

    private static func union(_ routes: [Route]) -> BBox? {
        let boxes = routes.compactMap(box(around:))
        guard let first = boxes.first else { return nil }
        return boxes.dropFirst().reduce(first) {
            BBox(minLat: min($0.minLat, $1.minLat), minLng: min($0.minLng, $1.minLng),
                 maxLat: max($0.maxLat, $1.maxLat), maxLng: max($0.maxLng, $1.maxLng))
        }.clamped
    }

    /// The OpenWaze server; throws `notConfigured` when this build has none.
    static let live: Fetch = { try await ReportsClient().traffic($0) }
}

import CoreLocation
import Foundation

/// Speed display and the over-limit rule. Speeds are metres per second
/// inside the app; only the bubble and the settings picker use km/h or mph.
enum Speedometer {
    static let kmh = 3.6
    static let mph = 2.236_936

    /// Metres per second per display unit for the locale.
    static func unitFactor(_ locale: Locale = .current) -> Double {
        locale.measurementSystem == .metric ? kmh : mph
    }

    static func unitName(_ locale: Locale = .current) -> String {
        locale.measurementSystem == .metric ? String(localized: "km/h") : String(localized: "mph")
    }

    /// "52" in the locale's unit; nil for an invalid speed (Core Location
    /// reports a negative speed when it can't tell).
    static func display(_ speed: Double?, locale: Locale = .current) -> String? {
        guard let speed, speed >= 0 else { return nil }
        return String(Int((speed * unitFactor(locale)).rounded()))
    }

    /// Over the limit once the speed passes limit + margin (both m/s).
    /// Exactly at the margin is still fine: signs round, GPS speed jitters.
    static func isOver(speed: Double?, limit: Double?, margin: Double) -> Bool {
        guard let speed, let limit, speed >= 0 else { return false }
        return speed > limit + margin
    }
}

/// OSM `maxspeed` values, as metres per second.
enum SpeedLimit {
    /// Implicit limits in km/h for the countries we know (OSM wiki, default
    /// speed limits). Others parse as nil, which shows no limit.
    /// Five countries for now; extend the table when a market needs it.
    static let implicit: [String: Double] = [
        "MY:urban": 50, "MY:rural": 90, "MY:motorway": 110,
        "SG:urban": 50, "SG:motorway": 90,
        "RU:living_street": 20, "RU:urban": 60, "RU:rural": 90, "RU:motorway": 110,
        "DE:living_street": 7, "DE:urban": 50, "DE:rural": 100,
        "GB:nsl_restricted": 30 * mile, "GB:nsl_single": 60 * mile, "GB:nsl_dual": 70 * mile, "GB:motorway": 70 * mile,
    ]

    private static let mile = 1.609_344 // km

    /// `50`, `50 km/h`, `30 mph`, `10 knots`, `RU:urban`. `none`, `signals`,
    /// `variable` and anything else is nil (no limit to warn against).
    static func parse(_ tag: String?) -> Double? {
        guard let tag = tag?.trimmingCharacters(in: .whitespaces), !tag.isEmpty else { return nil }
        if let kmh = implicit[tag] {
            return kmh / Speedometer.kmh
        }
        let parts = tag.lowercased().split(separator: " ", omittingEmptySubsequences: true)
        guard let first = parts.first, let number = Double(first), number > 0 else { return nil }
        switch parts.dropFirst().first {
        case nil, "km/h", "kmh", "kph": return number / Speedometer.kmh
        case "mph": return number / Speedometer.mph
        case "knots": return number * 0.514_444
        default: return nil
        }
    }
}

/// Roads with a known limit near a route, matched to the driver's position.
struct SpeedLimits: Equatable {
    struct Way: Equatable {
        var limit: Double // m/s
        var line: [CLLocationCoordinate2D]

        static func == (lhs: Way, rhs: Way) -> Bool {
            lhs.limit == rhs.limit && lhs.line.count == rhs.line.count
                && zip(lhs.line, rhs.line).allSatisfy { $0.latitude == $1.latitude && $0.longitude == $1.longitude }
        }
    }

    /// A fix further than this from every known road has no limit: a parallel
    /// street or service road would give the wrong one.
    static let maxDistance = 25.0 // metres

    var ways: [Way] = []

    /// The limit of the closest road within `maxDistance`.
    /// A linear scan over every way per fix; grid-index it if routes get long.
    func limit(near point: CLLocationCoordinate2D) -> Double? {
        var best: (distance: Double, limit: Double)?
        for way in ways {
            guard let match = Geo.project(point, onto: way.line), match.distance <= Self.maxDistance,
                  match.distance < best?.distance ?? .infinity else { continue }
            best = (match.distance, way.limit)
        }
        return best?.limit
    }
}

/// Fetches `maxspeed` ways along a route from the public Overpass API (no
/// key). The route geometry is rounded to 3 decimals (about 110 m) and
/// thinned before it leaves the device; the live position never does.
enum Overpass {
    typealias Fetch = (URLRequest) async throws -> (Data, URLResponse)

    static let baseURL = URL(string: "https://overpass-api.de/api/interpreter")!
    /// Covers the rounding error plus the road's offset from the route line.
    static let around = 120.0 // metres
    /// Keeps the query and the answer bounded on a long route.
    static let maxPoints = 800

    static func fetch(
        along line: [CLLocationCoordinate2D],
        fetch: Fetch = { try await URLSession.shared.data(for: $0) }
    ) async throws -> SpeedLimits {
        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.setValue(HTTP.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        // Encode everything but unreserved characters: a bare `;` splits the field on the server.
        let unreserved = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let encoded = query(along: line).addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
        request.httpBody = Data("data=\(encoded)".utf8)
        let (data, response) = try await fetch(request)
        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            throw RouterError.http(status: http.statusCode)
        }
        return try parse(data)
    }

    /// Route points rounded to 3 decimals, with repeats dropped, at most `maxPoints`.
    static func thin(_ line: [CLLocationCoordinate2D]) -> [(lat: Double, lon: Double)] {
        var points: [(lat: Double, lon: Double)] = []
        for point in line {
            let rounded = ((point.latitude * 1000).rounded() / 1000, (point.longitude * 1000).rounded() / 1000)
            if points.last.map({ $0 != rounded }) ?? true {
                points.append(rounded)
            }
        }
        let stride = max(1, Int((Double(points.count) / Double(maxPoints)).rounded(.up)))
        return points.indices.compactMap { $0 % stride == 0 || $0 == points.count - 1 ? points[$0] : nil }
    }

    static func query(along line: [CLLocationCoordinate2D]) -> String {
        let points = thin(line).map { String(format: "%.3f,%.3f", $0.lat, $0.lon) }.joined(separator: ",")
        return "[out:json][timeout:25];way[maxspeed][highway](around:\(Int(around)),\(points));out geom;"
    }

    /// Ways without a parsable limit are dropped alone.
    static func parse(_ data: Data) throws -> SpeedLimits {
        let response = try JSONDecoder().decode(Response.self, from: data)
        let ways = (response.elements ?? []).compactMap { lossy -> SpeedLimits.Way? in
            guard let way = lossy.value, let limit = SpeedLimit.parse(way.tags?["maxspeed"]) else { return nil }
            let line = (way.geometry ?? []).map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
            return line.count >= 2 ? SpeedLimits.Way(limit: limit, line: line) : nil
        }
        return SpeedLimits(ways: ways)
    }

    struct Response: Decodable {
        let elements: [HTTP.Lossy<Element>]?
    }

    struct Element: Decodable {
        let tags: [String: String]?
        let geometry: [Point]?
    }

    struct Point: Decodable {
        let lat: Double
        let lon: Double
    }
}

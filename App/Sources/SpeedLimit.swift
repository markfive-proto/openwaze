import CoreLocation
import Foundation

/// Parses OSM `maxspeed` values into km/h. Nil means "show no limit":
/// none, signals, walk, unknown zones and garbage are not guessed at.
enum Maxspeed {
    static let kmhPerMph = 1.609344

    /// Implicit Malaysian limits. Source: Road Transport Act 1987, National
    /// Speed Limit Rules 1989 (expressway 110, federal and state roads 90,
    /// municipal roads 60), via secondary sources. Unverified against the
    /// gazette; the OSM wiki has no Malaysia row yet.
    static let zones: [String: Double] = [
        "MY:motorway": 110,
        "MY:rural": 90,
        "MY:urban": 60,
    ]

    static func kmh(_ raw: String?) -> Double? {
        guard let raw else { return nil }
        // "50;60": several values, take the lower (the safe one).
        let values = raw.split(separator: ";").compactMap { single(String($0)) }
        return values.min()
    }

    private static func single(_ raw: String) -> Double? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        if let zone = zones[text] {
            return zone
        }
        let lower = text.lowercased()
        let units: [(suffix: String, factor: Double)] = [
            ("mph", kmhPerMph), ("km/h", 1), ("kmh", 1), ("kph", 1), ("", 1),
        ]
        for unit in units where lower.hasSuffix(unit.suffix) {
            let number = lower.dropLast(unit.suffix.count).trimmingCharacters(in: .whitespaces)
            guard let value = Double(number), value > 0, value < 300 else { return nil }
            return value * unit.factor
        }
        return nil
    }
}

/// A ~1 km grid cell (0.01 degree). Speed limits are fetched per tile, so a
/// third party learns only which cell the user is in, never the position.
struct SpeedTile: Hashable, Codable {
    /// Tiles per degree. Dividing by it keeps edges exact ("3.15", not "3.1500000000000004").
    static let perDegree = 100.0

    let row: Int
    let column: Int

    init(row: Int, column: Int) {
        self.row = row
        self.column = column
    }

    init(_ coordinate: CLLocationCoordinate2D) {
        row = Int((coordinate.latitude * Self.perDegree).rounded(.down))
        column = Int((coordinate.longitude * Self.perDegree).rounded(.down))
    }

    var key: String {
        "\(row)_\(column)"
    }

    /// [south, west, north, east] in degrees, the Overpass bbox order.
    var bounds: [Double] {
        [row, column, row + 1, column + 1].map { Double($0) / Self.perDegree }
    }
}

/// A drivable OSM way: raw `maxspeed` (nil when untagged) and its geometry.
struct SpeedWay: Codable, Equatable {
    var maxspeed: String?
    var points: [Point]

    struct Point: Codable, Equatable {
        var lat: Double
        var lon: Double
    }

    var line: Geo.Line {
        points.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
    }
}

enum OverpassError: Error, Equatable {
    case http(status: Int)
}

/// OSM speed limits from the Overpass API, one tile per request.
enum Overpass {
    typealias Fetch = (URLRequest) async throws -> (Data, URLResponse)

    static let baseURL = URL(string: "https://overpass-api.de/api/interpreter")!
    /// Drivable roads. Untagged ways are fetched too, so the user is matched
    /// to the road they are on (and shown no limit) rather than to a tagged
    /// road next to it.
    static let highways = "motorway|trunk|primary|secondary|tertiary|unclassified|residential|living_street|service"
        + "|motorway_link|trunk_link|primary_link|secondary_link|tertiary_link"

    static func ways(
        in tile: SpeedTile,
        fetch: Fetch = { try await URLSession.shared.data(for: $0) }
    ) async throws -> [SpeedWay] {
        let (data, response) = try await fetch(request(for: tile))
        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            throw OverpassError.http(status: http.statusCode)
        }
        return try parse(data)
    }

    static func query(for tile: SpeedTile) -> String {
        let box = tile.bounds.map { String($0) }.joined(separator: ",")
        return "[out:json][timeout:25];way[\"highway\"~\"^(\(highways))$\"]"
            + "(\(box));out tags geom;"
    }

    static func request(for tile: SpeedTile) -> URLRequest {
        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.setValue(HTTP.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [URLQueryItem(name: "data", value: query(for: tile))]
        request.httpBody = form.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
            .data(using: .utf8)
        return request
    }

    /// Ways with fewer than two points or a broken shape are dropped alone.
    static func parse(_ data: Data) throws -> [SpeedWay] {
        try JSONDecoder().decode(Response.self, from: data).elements.compactMap { lossy in
            guard let element = lossy.value, element.type == "way",
                  let geometry = element.geometry, geometry.count >= 2 else { return nil }
            return SpeedWay(maxspeed: element.tags?["maxspeed"], points: geometry)
        }
    }

    struct Response: Decodable {
        let elements: [HTTP.Lossy<Element>]
    }

    struct Element: Decodable {
        let type: String
        let tags: [String: String]?
        let geometry: [SpeedWay.Point]?
    }

    /// Wait after the n-th failure in a row: 30 s, 60 s... up to 15 min.
    /// 429 and 504 are Overpass saying "too busy", so start at 2 min.
    static func backoff(after failures: Int, status: Int?) -> TimeInterval {
        let base: TimeInterval = [429, 504].contains(status) ? 120 : 30
        return min(900, base * pow(2, Double(max(0, failures - 1))))
    }
}

enum SpeedMatch {
    /// Further than this from every way: not on a known road.
    static let maxDistance = 25.0 // metres
    /// Segments more than this off the driving direction are cross streets.
    static let maxAngle = 45.0 // degrees
    /// Below this, GPS course is noise.
    static let minSpeedForCourse = 2.0 // m/s

    /// The way the user is most likely on: nearest segment within
    /// `maxDistance` whose direction (either way) matches the course.
    static func nearest(_ ways: [SpeedWay], to point: CLLocationCoordinate2D, course: Double?) -> SpeedWay? {
        var best: (way: SpeedWay, distance: Double)?
        for way in ways {
            let line = way.line
            for segment in 0 ..< max(0, line.count - 1) {
                guard let hit = Geo.project(point, onto: line, from: segment, to: segment),
                      hit.distance <= maxDistance, hit.distance < best?.distance ?? .infinity else { continue }
                if let course, angle(course, bearing(line[segment], line[segment + 1])) > maxAngle {
                    continue
                }
                best = (way, hit.distance)
            }
        }
        return best?.way
    }

    /// Degrees clockwise from north.
    static func bearing(_ start: CLLocationCoordinate2D, _ end: CLLocationCoordinate2D) -> Double {
        let delta = Geo.offset(end, from: start)
        let degrees = atan2(delta.east, delta.north) * 180 / .pi
        return degrees < 0 ? degrees + 360 : degrees
    }

    /// 0...90: how far a road at `bearing` is from `course`, ignoring which
    /// way along it (ponytail: oneway and maxspeed:forward/backward are not read).
    static func angle(_ course: Double, _ bearing: Double) -> Double {
        let diff = abs(course - bearing).truncatingRemainder(dividingBy: 180)
        return min(diff, 180 - diff)
    }
}

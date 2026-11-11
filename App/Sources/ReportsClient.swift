import CoreLocation
import Foundation

/// Crowd report categories. Raw values are the server's `type` enum.
enum ReportType: String, CaseIterable, Codable, Identifiable {
    case police, accident, hazard, traffic, closure, flood

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .police: String(localized: "Police")
        case .accident: String(localized: "Accident")
        case .hazard: String(localized: "Hazard")
        case .traffic: String(localized: "Traffic")
        case .closure: String(localized: "Closure")
        case .flood: String(localized: "Flood")
        }
    }

    /// SF Symbol name; the UI layer renders it.
    var symbol: String {
        switch self {
        case .police: "shield.lefthalf.filled"
        case .accident: "car.side.rear.and.collision.and.car.side.front"
        case .hazard: "exclamationmark.triangle.fill"
        case .traffic: "car.2.fill"
        case .closure: "xmark.octagon.fill"
        case .flood: "water.waves"
        }
    }

    /// Colour token name; the UI layer maps it to a colour.
    var colorToken: String {
        "report" + rawValue.prefix(1).uppercased() + rawValue.dropFirst()
    }

    /// Mirrors the server's lifetimes, for optimistic inserts only.
    var lifetime: TimeInterval {
        switch self {
        case .traffic: 30 * 60
        case .flood: 120 * 60
        default: 60 * 60
        }
    }
}

struct Report: Identifiable, Equatable, Decodable {
    let id: String
    let type: ReportType
    let lat: Double
    let lng: Double
    let createdAt: Date
    var expiresAt: Date
    var upvotes: Int
    var downvotes: Int

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }

    /// ID prefix of an optimistic report the server hasn't confirmed yet.
    static let draftPrefix = "local-"

    var isDraft: Bool {
        id.hasPrefix(Self.draftPrefix)
    }
}

/// Map area to query. The server caps each axis at 2 degrees.
struct BBox: Equatable {
    var minLat: Double
    var minLng: Double
    var maxLat: Double
    var maxLng: Double

    static let maxSpan = 2.0

    /// A box the server accepts: each axis at most `maxSpan` around its
    /// centre (so a zoomed-out map still gets the middle instead of a 400),
    /// shifted to lie inside ±90 / ±180, never inverted.
    ///
    /// Longitude: a box crossing the antimeridian (`minLng > maxLng`, or a
    /// map that reports longitudes past ±180) is unwrapped, then shifted to
    /// the side its centre is on.
    /// ponytail: that drops reports just across the antimeridian (Fiji,
    /// Chukotka); split into two queries if the app ever drives there.
    var clamped: BBox {
        let lat = Self.fit(min(minLat, maxLat), max(minLat, maxLat), within: -90 ... 90)
        var (west, east) = (minLng, maxLng)
        if west > east {
            east += 360
        }
        let mid = (west + east) / 2
        let wrap = (mid + 180).truncatingRemainder(dividingBy: 360)
        let shift = (wrap < 0 ? wrap + 360 : wrap) - 180 - mid // brings the centre into -180..<180
        let lng = Self.fit(west + shift, east + shift, within: -180 ... 180)
        return BBox(minLat: lat.low, minLng: lng.low, maxLat: lat.high, maxLng: lng.high)
    }

    private static func fit(
        _ low: Double, _ high: Double, within limit: ClosedRange<Double>
    ) -> (low: Double, high: Double) {
        var (low, high) = (low, high)
        if high - low > maxSpan {
            let mid = (low + high) / 2
            (low, high) = (mid - maxSpan / 2, mid + maxSpan / 2)
        }
        if low < limit.lowerBound {
            (low, high) = (limit.lowerBound, high + limit.lowerBound - low)
        }
        if high > limit.upperBound {
            (low, high) = (max(limit.lowerBound, low - (high - limit.upperBound)), limit.upperBound)
        }
        return (low, high)
    }

    /// Plain comparisons, not a ClosedRange, so a bad box can't trap.
    func contains(_ point: CLLocationCoordinate2D) -> Bool {
        point.latitude >= minLat && point.latitude <= maxLat
            && point.longitude >= minLng && point.longitude <= maxLng
    }
}

enum ReportsError: Error, Equatable {
    case rateLimited // 429
    case notFound // 404: unknown or expired report
    case conflict // 409: already voted, or own report
    case http(status: Int, message: String?)
    /// This build has no OPENWAZE_API_URL (Release must set it).
    case notConfigured
    /// The Keychain is locked (before first unlock); try again later.
    case noDeviceID
}

/// Client for the OpenWaze reports server (server/README.md).
struct ReportsClient {
    typealias Fetch = (URLRequest) async throws -> (Data, URLResponse)

    /// From the `OPENWAZE_API_URL` build setting via Info.plist. Debug
    /// defaults to the local dev server; Release has no default, so a
    /// missing value is a loud failure, never a silent call to loopback.
    static let baseURL: URL? = {
        let url = Self.url(from: Bundle.main.object(forInfoDictionaryKey: "OPENWAZE_API_URL") as? String)
        if url == nil {
            assertionFailure("OPENWAZE_API_URL is not set for this build configuration")
        }
        return url
    }()

    var baseURL = Self.baseURL
    var deviceID: () -> String? = { DeviceID.shared.value }
    var fetch: Fetch = { try await URLSession.shared.data(for: $0) }

    /// A usable http(s) URL, or nil when unset, blank or an unexpanded `$(…)`.
    static func url(from setting: String?) -> URL? {
        guard let setting, let url = URL(string: setting), ["http", "https"].contains(url.scheme),
              url.host() != nil else { return nil }
        return url
    }

    func create(_ type: ReportType, at coordinate: CLLocationCoordinate2D) async throws -> Report {
        let body: [String: Any] = try [
            "type": type.rawValue, "lat": coordinate.latitude, "lng": coordinate.longitude, "deviceId": device(),
        ]
        return try await Self.decode(Report.self, send(post("reports", body)))
    }

    func list(_ bbox: BBox) async throws -> [Report] {
        var components = try URLComponents(url: endpoint("reports"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "minLat", value: String(bbox.minLat)),
            URLQueryItem(name: "minLng", value: String(bbox.minLng)),
            URLQueryItem(name: "maxLat", value: String(bbox.maxLat)),
            URLQueryItem(name: "maxLng", value: String(bbox.maxLng)),
        ]
        return try await Self.parse(send(URLRequest(url: components.url!)))
    }

    func traffic(_ bbox: BBox) async throws -> [TrafficReading] {
        var components = try URLComponents(url: endpoint("traffic"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "minLat", value: String(bbox.minLat)),
            URLQueryItem(name: "minLng", value: String(bbox.minLng)),
            URLQueryItem(name: "maxLat", value: String(bbox.maxLat)),
            URLQueryItem(name: "maxLng", value: String(bbox.maxLng)),
        ]
        return try await Traffic.parse(send(URLRequest(url: components.url!)))
    }

    func vote(_ id: String, stillThere: Bool) async throws -> Report {
        let request = try post("reports/\(id)/vote", ["deviceId": device(), "stillThere": stillThere])
        return try await Self.decode(Report.self, send(request))
    }

    /// Parses a report list. Malformed reports (or unknown types from a newer
    /// server) are skipped rather than failing the whole response.
    static func parse(_ data: Data) throws -> [Report] {
        try decode([HTTP.Lossy<Report>].self, data).compactMap(\.value)
    }

    /// ISO 8601 with or without fractional seconds: the server sends whole
    /// seconds today, but a millisecond timestamp must not drop every report.
    static func decode<T: Decodable>(_: T.Type, _ data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            let styles = [Date.ISO8601FormatStyle(), Date.ISO8601FormatStyle(includingFractionalSeconds: true)]
            if let date = styles.lazy.compactMap({ try? $0.parse(text) }).first {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not an ISO 8601 date: \(text)")
        }
        return try decoder.decode(T.self, from: data)
    }

    private func device() throws -> String {
        guard let id = deviceID() else { throw ReportsError.noDeviceID }
        return id
    }

    private func endpoint(_ path: String) throws -> URL {
        guard let baseURL else { throw ReportsError.notConfigured }
        return baseURL.appending(path: path)
    }

    private func post(_ path: String, _ body: [String: Any]) throws -> URLRequest {
        var request = try URLRequest(url: endpoint(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func send(_ request: URLRequest) async throws -> Data {
        var request = request
        request.setValue(HTTP.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await fetch(request)
        guard let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) else { return data }
        switch http.statusCode {
        case 429: throw ReportsError.rateLimited
        case 404: throw ReportsError.notFound
        case 409: throw ReportsError.conflict
        default:
            let message = try? JSONDecoder().decode([String: String].self, from: data)["error"]
            throw ReportsError.http(status: http.statusCode, message: message)
        }
    }
}

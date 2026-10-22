import CoreLocation
import Foundation

/// Crowd report categories. Raw values are the server's `type` enum.
enum ReportType: String, CaseIterable, Codable {
    case police, accident, hazard, traffic, closure, flood

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
        case .police: "light.beacon.max.fill"
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
}

/// Map area to query. The server caps each axis at 2 degrees.
struct BBox: Equatable {
    var minLat: Double
    var minLng: Double
    var maxLat: Double
    var maxLng: Double

    static let maxSpan = 2.0

    /// Shrinks each axis to `maxSpan` around its centre, so a zoomed-out map
    /// still gets the reports around the middle instead of a 400.
    var clamped: BBox {
        func clamp(_ low: Double, _ high: Double, _ limit: ClosedRange<Double>) -> (Double, Double) {
            let mid = (low + high) / 2, half = Self.maxSpan / 2
            let (low, high) = high - low > Self.maxSpan ? (mid - half, mid + half) : (low, high)
            return (max(limit.lowerBound, low), min(limit.upperBound, high))
        }
        let lat = clamp(minLat, maxLat, -90 ... 90), lng = clamp(minLng, maxLng, -180 ... 180)
        return BBox(minLat: lat.0, minLng: lng.0, maxLat: lat.1, maxLng: lng.1)
    }
}

enum ReportsError: Error, Equatable {
    case rateLimited // 429
    case notFound // 404: unknown or expired report
    case conflict // 409: already voted, or own report
    case http(status: Int, message: String?)
}

/// Client for the OpenWaze reports server (server/README.md).
struct ReportsClient {
    typealias Fetch = (URLRequest) async throws -> (Data, URLResponse)

    static let defaultBaseURL = URL(string: "http://localhost:8787/")!
    /// From the `OPENWAZE_API_URL` build setting via Info.plist.
    static let baseURL = url(from: Bundle.main.object(forInfoDictionaryKey: "OPENWAZE_API_URL") as? String)

    var baseURL = Self.baseURL
    var deviceID = DeviceID.current
    var fetch: Fetch = { try await URLSession.shared.data(for: $0) }

    static func url(from setting: String?) -> URL {
        guard let setting, let url = URL(string: setting), url.scheme != nil, url.host() != nil else {
            return defaultBaseURL
        }
        return url
    }

    func create(_ type: ReportType, at coordinate: CLLocationCoordinate2D) async throws -> Report {
        let body: [String: Any] = [
            "type": type.rawValue, "lat": coordinate.latitude, "lng": coordinate.longitude, "deviceId": deviceID,
        ]
        return try await Self.decoder.decode(Report.self, from: send(post("reports", body)))
    }

    func list(_ bbox: BBox) async throws -> [Report] {
        var components = URLComponents(url: baseURL.appending(path: "reports"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "minLat", value: String(bbox.minLat)),
            URLQueryItem(name: "minLng", value: String(bbox.minLng)),
            URLQueryItem(name: "maxLat", value: String(bbox.maxLat)),
            URLQueryItem(name: "maxLng", value: String(bbox.maxLng)),
        ]
        return try await Self.parse(send(URLRequest(url: components.url!)))
    }

    func vote(_ id: String, stillThere: Bool) async throws -> Report {
        let request = try post("reports/\(id)/vote", ["deviceId": deviceID, "stillThere": stillThere])
        return try await Self.decoder.decode(Report.self, from: send(request))
    }

    /// Parses a report list. Malformed reports (or unknown types from a newer
    /// server) are skipped rather than failing the whole response.
    static func parse(_ data: Data) throws -> [Report] {
        try decoder.decode([Photon.Lossy<Report>].self, from: data).compactMap(\.value)
    }

    static let decoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private func post(_ path: String, _ body: [String: Any]) throws -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func send(_ request: URLRequest) async throws -> Data {
        var request = request
        request.setValue(Photon.userAgent, forHTTPHeaderField: "User-Agent")
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

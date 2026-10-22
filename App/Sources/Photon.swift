import CoreLocation
import Foundation

/// A place the user can navigate to.
struct Destination: Identifiable, Equatable {
    let id: String
    let name: String
    let address: String
    let latitude: Double
    let longitude: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

enum PhotonError: Error, Equatable {
    case http(status: Int)
}

/// Keyless geocoding via Photon (OpenStreetMap data, hosted by Komoot).
enum Photon {
    typealias Fetch = (URLRequest) async throws -> (Data, URLResponse)

    static let baseURL = URL(string: "https://photon.komoot.io/api/")!
    static let userAgent = "OpenWaze/0.1 (+https://github.com/markfive-proto/openwaze)"
    static let limit = 8

    static func search(
        _ query: String,
        near: CLLocationCoordinate2D?,
        fetch: Fetch = { try await URLSession.shared.data(for: $0) }
    ) async throws -> [Destination] {
        var request = URLRequest(url: url(query: query, near: near))
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await fetch(request)
        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            throw PhotonError.http(status: http.statusCode)
        }
        return try parse(data)
    }

    /// Location bias is rounded to 2 decimals (~1 km) so the exact position
    /// never leaves the device.
    static func url(query: String, near: CLLocationCoordinate2D?) -> URL {
        var items = [URLQueryItem(name: "q", value: query)]
        if let near {
            items.append(URLQueryItem(name: "lat", value: rounded(near.latitude)))
            items.append(URLQueryItem(name: "lon", value: rounded(near.longitude)))
        }
        items.append(URLQueryItem(name: "limit", value: String(limit)))
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = items
        // URLComponents leaves "+" alone, which servers read as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }

    static func rounded(_ degrees: Double) -> String {
        String((degrees * 100).rounded() / 100)
    }

    /// Parses a Photon FeatureCollection. Malformed or unidentifiable
    /// features are skipped rather than failing the whole response.
    static func parse(_ data: Data) throws -> [Destination] {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase // osm_id -> osmId
        return try decoder.decode(Response.self, from: data).features.compactMap { lossy in
            guard let feature = lossy.value,
                  let osmType = clean(feature.properties.osmType),
                  let osmId = feature.properties.osmId,
                  feature.geometry.coordinates.count >= 2 else { return nil }
            let props = feature.properties
            let street = [props.housenumber, props.street].compactMap(clean).joined(separator: " ")
            guard let name = clean(props.name) ?? clean(street) else { return nil }
            return Destination(
                id: "\(osmType)\(osmId)",
                name: name,
                address: shortAddress(name: name, street: street, props: props),
                latitude: feature.geometry.coordinates[1],
                longitude: feature.geometry.coordinates[0]
            )
        }
    }

    /// "10 Bayfront Avenue, Singapore": street line, then the most specific
    /// place name, then country, skipping blanks and repeats of earlier parts.
    static func shortAddress(name: String, street: String, props: Properties) -> String {
        var seen: Set<String> = [name]
        let place = clean(props.city) ?? clean(props.district) ?? clean(props.locality)
        return [clean(street), place, clean(props.country)]
            .compactMap(\.self)
            .filter { seen.insert($0).inserted }
            .joined(separator: ", ")
    }

    /// Trimmed value, or nil when missing or blank.
    static func clean(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespaces), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    struct Response: Decodable {
        let features: [Lossy<Feature>]
    }

    /// Decodes to nil instead of throwing, so one bad element is dropped alone.
    struct Lossy<Value: Decodable>: Decodable {
        let value: Value?

        init(from decoder: Decoder) throws {
            value = try? Value(from: decoder)
        }
    }

    struct Feature: Decodable {
        let properties: Properties
        let geometry: Geometry
    }

    struct Geometry: Decodable {
        let coordinates: [Double]
    }

    struct Properties: Decodable {
        var osmType: String?
        var osmId: Int?
        var name: String?
        var housenumber: String?
        var street: String?
        var locality: String?
        var district: String?
        var city: String?
        var country: String?
    }
}

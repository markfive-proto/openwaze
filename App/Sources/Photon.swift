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

/// Keyless geocoding via Photon (OpenStreetMap data, hosted by Komoot).
enum Photon {
    static let baseURL = URL(string: "https://photon.komoot.io/api/")!
    static let userAgent = "OpenWaze/0.1 (+https://github.com/markfive-proto/openwaze)"
    static let limit = 8

    static func search(_ query: String, near: CLLocationCoordinate2D?) async throws -> [Destination] {
        var request = URLRequest(url: url(query: query, near: near))
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: request)
        return try parse(data)
    }

    static func url(query: String, near: CLLocationCoordinate2D?) -> URL {
        var items = [URLQueryItem(name: "q", value: query)]
        if let near {
            items.append(URLQueryItem(name: "lat", value: String(near.latitude)))
            items.append(URLQueryItem(name: "lon", value: String(near.longitude)))
        }
        items.append(URLQueryItem(name: "limit", value: String(limit)))
        return baseURL.appending(queryItems: items)
    }

    static func parse(_ data: Data) throws -> [Destination] {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase // osm_id -> osmId
        return try decoder.decode(Response.self, from: data).features.compactMap { feature in
            let props = feature.properties
            let coords = feature.geometry.coordinates
            guard coords.count >= 2 else { return nil }
            let street = join([props.housenumber, props.street], " ")
            guard let name = props.name ?? street.nilIfEmpty else { return nil }
            return Destination(
                id: "\(props.osmType ?? "")\(props.osmId ?? 0)",
                name: name,
                address: shortAddress(name: name, street: street, props: props),
                latitude: coords[1],
                longitude: coords[0]
            )
        }
    }

    /// "10 Bayfront Avenue, Singapore": street line, then the most specific
    /// place name, then country, skipping blanks and repeats of earlier parts.
    static func shortAddress(name: String, street: String, props: Properties) -> String {
        var seen: Set<String> = [name]
        let parts = [street, props.city ?? props.district ?? props.locality, props.country]
            .compactMap { $0?.nilIfEmpty }
            .filter { seen.insert($0).inserted }
        return parts.joined(separator: ", ")
    }

    private static func join(_ parts: [String?], _ separator: String) -> String {
        parts.compactMap { $0?.nilIfEmpty }.joined(separator: separator)
    }

    struct Response: Decodable {
        let features: [Feature]
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

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}

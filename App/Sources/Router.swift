import CoreLocation
import Foundation

/// A drivable route with turn-by-turn steps.
struct Route {
    struct Step: Equatable {
        var type: String
        var modifier: String?
        var exit: Int?
        var name = ""
        var destinations: String?
        var latitude: Double
        var longitude: Double
        var distance: Double = 0 // metres to the next step's maneuver
        var duration: Double = 0 // seconds to the next step's maneuver
    }

    let id = UUID() // lets the map tell routes apart cheaply
    let coordinates: [CLLocationCoordinate2D]
    let steps: [Step]
    let distance: Double
    let duration: Double
    /// Metres from the start to each coordinate.
    let along: [Double]
    /// Metres from the start to each step's maneuver.
    let stepStart: [Double]

    init(coordinates: [CLLocationCoordinate2D], steps: [Step], distance: Double, duration: Double) {
        self.coordinates = coordinates
        self.steps = steps
        self.distance = distance
        self.duration = duration
        along = Geo.cumulative(coordinates)
        guard !coordinates.isEmpty else {
            stepStart = steps.map { _ in 0 }
            return
        }
        // OSRM puts each maneuver on a geometry vertex; match them in order,
        // each after the previous one, so a route that loops back over a
        // junction (or re-enters a roundabout) keeps its steps apart. Only a
        // zero-length step may share its vertex with the next.
        var vertex = 0
        var starts: [Double] = []
        for (index, step) in steps.enumerated() {
            let point = CLLocationCoordinate2D(latitude: step.latitude, longitude: step.longitude)
            let from = index == 0 || steps[index - 1].distance == 0 ? vertex : vertex + 1
            vertex = Geo.firstVertex(near: point, in: coordinates, from: from)
            starts.append(along[vertex])
        }
        stepStart = starts
    }
}

enum RouterError: Error, Equatable {
    case http(status: Int)
    /// OSRM answered but found nothing, e.g. "NoRoute" or "NoSegment".
    case noRoute(code: String)
}

/// Driving routes from an OSRM server.
enum Router {
    typealias Fetch = (URLRequest) async throws -> (Data, URLResponse)

    /// The public OSRM demo server: development only (rate limited, no SLA).
    /// Swap this for a self-hosted router before release.
    static let baseURL = URL(string: "https://router.project-osrm.org/")!

    static func route(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        fetch: Fetch = { try await URLSession.shared.data(for: $0) }
    ) async throws -> Route {
        var request = URLRequest(url: url(from: origin, to: destination))
        request.setValue(HTTP.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await fetch(request)
        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            // OSRM reports "no route" as a 400 with a JSON code.
            if let code = try? JSONDecoder().decode(Response.self, from: data).code {
                throw RouterError.noRoute(code: code)
            }
            throw RouterError.http(status: http.statusCode)
        }
        return try parse(data)
    }

    static func url(from origin: CLLocationCoordinate2D, to destination: CLLocationCoordinate2D) -> URL {
        let points = [origin, destination].map { "\($0.longitude),\($0.latitude)" }.joined(separator: ";")
        let path = "route/v1/driving/\(points)"
        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "steps", value: "true"),
            URLQueryItem(name: "overview", value: "full"),
            URLQueryItem(name: "geometries", value: "geojson"),
            URLQueryItem(name: "annotations", value: "false"),
        ]
        return components.url!
    }

    /// Parses the first route of an OSRM response. Malformed points and
    /// steps are skipped rather than failing the whole route.
    static func parse(_ data: Data) throws -> Route {
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard response.code == "Ok", let route = response.routes?.first?.value else {
            throw RouterError.noRoute(code: response.code ?? "Unknown")
        }
        let coordinates = route.geometry.coordinates.compactMap { pair -> CLLocationCoordinate2D? in
            guard pair.count >= 2 else { return nil }
            return CLLocationCoordinate2D(latitude: pair[1], longitude: pair[0])
        }
        guard coordinates.count >= 2 else { throw RouterError.noRoute(code: "NoGeometry") }
        let steps = (route.legs ?? []).flatMap { $0.steps ?? [] }.compactMap { lossy -> Route.Step? in
            guard let step = lossy.value, step.maneuver.location.count >= 2 else { return nil }
            return Route.Step(
                type: step.maneuver.type,
                modifier: step.maneuver.modifier,
                exit: step.maneuver.exit,
                name: Photon.clean(step.name) ?? "",
                destinations: Photon.clean(step.destinations),
                latitude: step.maneuver.location[1],
                longitude: step.maneuver.location[0],
                distance: step.distance ?? 0,
                duration: step.duration ?? 0
            )
        }
        let (distance, duration) = (route.distance ?? 0, route.duration ?? 0)
        return Route(coordinates: coordinates, steps: steps, distance: distance, duration: duration)
    }

    struct Response: Decodable {
        let code: String?
        let routes: [HTTP.Lossy<RouteDTO>]?
    }

    struct RouteDTO: Decodable {
        let geometry: Geometry
        let legs: [Leg]?
        let distance: Double?
        let duration: Double?
    }

    struct Geometry: Decodable {
        let coordinates: [[Double]]
    }

    struct Leg: Decodable {
        let steps: [HTTP.Lossy<StepDTO>]?
    }

    struct StepDTO: Decodable {
        let maneuver: Maneuver
        let name: String?
        let destinations: String?
        let distance: Double?
        let duration: Double?
    }

    struct Maneuver: Decodable {
        let type: String
        let modifier: String?
        let exit: Int?
        let location: [Double]
    }
}

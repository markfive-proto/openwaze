import CoreLocation

/// Small-distance geometry on a local flat projection, good to well under
/// a metre over the few hundred metres between route vertices.
enum Geo {
    typealias Coordinate = CLLocationCoordinate2D

    static let earthRadius = 6_371_000.0

    /// Metres east and north of `origin`.
    static func offset(_ point: Coordinate, from origin: Coordinate) -> (east: Double, north: Double) {
        let radians = Double.pi / 180
        let east = (point.longitude - origin.longitude) * radians * cos(origin.latitude * radians) * earthRadius
        let north = (point.latitude - origin.latitude) * radians * earthRadius
        return (east, north)
    }

    static func distance(_ start: Coordinate, _ end: Coordinate) -> Double {
        let delta = offset(end, from: start)
        return hypot(delta.east, delta.north)
    }

    /// Metres from the start to each point of a polyline.
    static func cumulative(_ line: [Coordinate]) -> [Double] {
        var total = 0.0
        return line.indices.map { index in
            if index > 0 {
                total += distance(line[index - 1], line[index])
            }
            return total
        }
    }

    /// Closest vertex to `point` at or after `start`.
    static func nearestVertex(to point: Coordinate, in line: [Coordinate], from start: Int) -> Int {
        guard start < line.count else { return max(0, line.count - 1) }
        return (start ..< line.count).min { distance(point, line[$0]) < distance(point, line[$1]) } ?? start
    }

    struct Projection: Equatable {
        /// Index of the segment from `line[segment]` to `line[segment + 1]`.
        var segment: Int
        /// Fraction 0...1 along that segment.
        var fraction: Double
        /// Metres from `point` to the line.
        var distance: Double
    }

    /// Closest point on a polyline, searching segments at or after `start`
    /// so progress never jumps back to an earlier pass over the same road.
    /// ponytail: linear scan of the rest of the route, fine for a few
    /// thousand vertices per fix; window it if routes get much longer.
    static func project(_ point: Coordinate, onto line: [Coordinate], from start: Int = 0) -> Projection? {
        guard line.count >= 2 else { return nil }
        var best: Projection?
        for segment in max(0, start) ..< line.count - 1 {
            // With `point` as the origin, find the closest point on head + t * (tail - head).
            let head = offset(line[segment], from: point)
            let tail = offset(line[segment + 1], from: point)
            let east = tail.east - head.east, north = tail.north - head.north
            let lengthSquared = east * east + north * north
            let raw = lengthSquared == 0 ? 0 : -(head.east * east + head.north * north) / lengthSquared
            let fraction = min(1, max(0, raw))
            let distance = hypot(head.east + fraction * east, head.north + fraction * north)
            if distance < best?.distance ?? .infinity {
                best = Projection(segment: segment, fraction: fraction, distance: distance)
            }
        }
        return best
    }
}

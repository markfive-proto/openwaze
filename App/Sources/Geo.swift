import CoreLocation

/// Small-distance geometry on a local flat projection, good to well under
/// a metre over the few hundred metres between route vertices.
enum Geo {
    typealias Coordinate = CLLocationCoordinate2D
    typealias Line = [Coordinate]

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

    /// First vertex at or after `start` within `tolerance` metres of `point`
    /// (OSRM maneuvers sit exactly on a vertex), else the closest one after
    /// `start`. Taking the first match keeps a later pass over the same
    /// junction from stealing the step.
    static func firstVertex(near point: Coordinate, in line: [Coordinate], from start: Int) -> Int {
        let tolerance = 1.0 // metres
        guard start < line.count else { return max(0, line.count - 1) }
        let candidates = start ..< line.count
        return candidates.first { distance(point, line[$0]) <= tolerance }
            ?? candidates.min { distance(point, line[$0]) < distance(point, line[$1]) }
            ?? start
    }

    struct Projection: Equatable {
        /// Index of the segment from `line[segment]` to `line[segment + 1]`.
        var segment: Int
        /// Fraction 0...1 along that segment.
        var fraction: Double
        /// Metres from `point` to the line.
        var distance: Double
    }

    /// Closest point on a polyline over segments `start...end`, so progress
    /// never jumps back to an earlier pass over the same road, nor too far
    /// ahead to a later one.
    static func project(_ point: Coordinate, onto line: Line, from start: Int = 0, to end: Int = .max) -> Projection? {
        guard line.count >= 2 else { return nil }
        let first = min(max(0, start), line.count - 2)
        let last = max(first, min(end, line.count - 2))
        var best: Projection?
        for segment in first ... last {
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

import CoreLocation

enum Zoom {
    static let min = 3.0
    static let max = 17.0

    /// Zoom level that keeps a GPS fix's uncertainty circle visible on screen.
    /// Each zoom step halves the metres shown; ~10 m accuracy maps to zoom 17.
    static func level(forAccuracy metres: CLLocationAccuracy) -> Double {
        guard metres > 0, metres.isFinite else { return min }
        return Swift.min(max, Swift.max(min, max - log2(metres / 10)))
    }
}

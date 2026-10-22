import CoreLocation

enum Zoom {
    static let min = 3.0
    static let max = 17.0
    static let maxFixAge: TimeInterval = 10
    static let maxFixAccuracy: CLLocationAccuracy = 500

    /// Zoom level that keeps a GPS fix's uncertainty circle visible on screen.
    /// Each zoom step halves the metres shown; ~10 m accuracy maps to zoom 17.
    static func level(forAccuracy metres: CLLocationAccuracy) -> Double {
        guard metres >= 0, metres.isFinite else { return min }
        return Swift.min(max, Swift.max(min, max - log2(metres / 10)))
    }

    /// Whether a fix is fresh and accurate enough to zoom to. Cached or
    /// cell-tower fixes would otherwise set a bad initial zoom.
    static func isUsableFirstFix(_ location: CLLocation, now: Date = Date()) -> Bool {
        let accuracy = location.horizontalAccuracy
        return now.timeIntervalSince(location.timestamp) <= maxFixAge
            && accuracy >= 0 && accuracy <= maxFixAccuracy
    }
}

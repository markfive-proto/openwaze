import CoreLocation

/// "Still there?" prompts: the next crowd report on the route ahead, asked
/// about once per report per trip. Make a new value for each trip.
struct StillThere {
    /// How far ahead along the route a report triggers the prompt.
    static let ahead = 300.0 // metres
    /// How far off the route line a report still counts as on it (GPS error,
    /// the far carriageway).
    static let lateral = 30.0 // metres

    private(set) var asked: Set<String> = []

    /// The report to ask about now, if any, marking it asked.
    mutating func next(on route: Route, at progress: RouteProgress, reports: [Report]) -> Report? {
        guard let report = Self.nextAhead(on: route, at: progress, reports: reports.filter { !asked.contains($0.id) })
        else { return nil }
        asked.insert(report.id)
        return report
    }

    /// The closest report within `ahead` metres further along the route and
    /// within `lateral` metres of it. Reports behind the driver, or only near
    /// a later pass over the same road, are ignored.
    static func nextAhead(on route: Route, at progress: RouteProgress, reports: [Report]) -> Report? {
        let along = route.along
        guard along.count >= 2, let total = along.last else { return nil }
        let travelled = total - progress.remainingDistance
        let start = min(max(0, progress.segment), along.count - 2)
        // Last segment that starts within reach.
        let end = (along.indices.first { along[$0] > travelled + ahead } ?? along.count) - 1
        return reports
            .compactMap { report -> (Report, Double)? in
                guard let match = Geo.project(report.coordinate, onto: route.coordinates, from: start, to: end),
                      match.distance <= lateral else { return nil }
                let base = along[match.segment]
                let gap = base + (along[match.segment + 1] - base) * match.fraction - travelled
                return gap > 0 && gap <= ahead ? (report, gap) : nil
            }
            .min { $0.1 < $1.1 }?.0
    }
}

import CoreLocation
import Foundation

/// Where the driver is along a route.
struct RouteProgress: Equatable {
    /// Segment the driver was matched to; the next search starts here.
    var segment: Int
    /// Index of the upcoming maneuver in `route.steps`.
    var nextStep: Int
    var distanceToManeuver: Double
    var remainingDistance: Double
    var remainingDuration: Double
    /// Metres from the driver to the route line.
    var offRouteBy: Double
}

enum Guidance {
    static let offRouteDistance = 50.0 // metres
    static let offRouteDelay: TimeInterval = 5
    static let arrivalDistance = 25.0 // metres
    /// Spoken prompts, in metres before a maneuver; each is spoken once.
    static let announceAt = [500.0, 50.0]

    static func progress(on route: Route, at point: CLLocationCoordinate2D, from segment: Int = 0) -> RouteProgress? {
        guard let match = Geo.project(point, onto: route.coordinates, from: segment) else { return nil }
        let start = route.along[match.segment]
        let travelled = start + (route.along[match.segment + 1] - start) * match.fraction
        let total = route.along.last ?? 0
        // Upcoming maneuver: first step strictly ahead. Step 0 is depart.
        let next = route.stepStart.indices.dropFirst().first { route.stepStart[$0] > travelled }
            ?? max(0, route.steps.count - 1)
        let maneuverAt = route.stepStart.indices.contains(next) ? route.stepStart[next] : total
        let distanceToManeuver = max(0, maneuverAt - travelled)
        return RouteProgress(
            segment: match.segment,
            nextStep: next,
            distanceToManeuver: distanceToManeuver,
            remainingDistance: max(0, total - travelled),
            remainingDuration: remainingDuration(on: route, nextStep: next, distanceToManeuver: distanceToManeuver),
            offRouteBy: match.distance
        )
    }

    /// Whole steps still ahead, plus the unfinished share of the current one.
    static func remainingDuration(on route: Route, nextStep: Int, distanceToManeuver: Double) -> Double {
        guard nextStep > 0, nextStep <= route.steps.count else { return route.duration }
        let current = route.steps[nextStep - 1]
        let share = current.distance > 0 ? min(1, distanceToManeuver / current.distance) : 0
        return current.duration * share + route.steps[nextStep...].reduce(0) { $0 + $1.duration }
    }

    static func hasArrived(_ progress: RouteProgress) -> Bool {
        progress.remainingDistance <= arrivalDistance
    }

    /// A spoken prompt: one per maneuver per threshold.
    struct Announcement: Hashable {
        var step: Int
        var threshold: Double
    }

    /// The prompt due now, if any. Crossing several thresholds at once (e.g.
    /// a reroute that starts 30 m from a turn) speaks only the nearest one.
    static func announcement(for progress: RouteProgress, spoken: Set<Announcement>) -> Announcement? {
        guard let threshold = announceAt.filter({ progress.distanceToManeuver <= $0 }).min() else { return nil }
        let due = Announcement(step: progress.nextStep, threshold: threshold)
        return spoken.contains(due) ? nil : due
    }

    /// Thresholds now passed for this step, so they are never spoken late.
    static func markSpoken(_ announcement: Announcement) -> [Announcement] {
        announceAt.filter { $0 >= announcement.threshold }.map { Announcement(step: announcement.step, threshold: $0) }
    }

    /// Tracks how long the driver has been off route.
    struct OffRouteTimer {
        private(set) var since: Date?

        /// True once the driver has been off route for `offRouteDelay`.
        mutating func update(offRouteBy metres: Double, at now: Date) -> Bool {
            guard metres > offRouteDistance else {
                since = nil
                return false
            }
            let start = since ?? now
            since = start
            return now.timeIntervalSince(start) >= offRouteDelay
        }

        mutating func reset() {
            since = nil
        }
    }
}

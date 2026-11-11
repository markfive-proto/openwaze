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
    /// Fixes vaguer than this never count towards going off route.
    static let maxFixAccuracy = 50.0 // metres
    /// How far along the route one fix may move progress. Stops a later
    /// pass over the same road (a loop, a flyover) from stealing the match.
    static let maxJump = 1000.0 // metres

    static func progress(on route: Route, at point: CLLocationCoordinate2D, from segment: Int = 0) -> RouteProgress? {
        guard route.along.count >= 2 else { return nil }
        let start = min(max(0, segment), route.along.count - 2)
        let limit = route.along.indices.first { route.along[$0] > route.along[start] + maxJump } ?? .max
        guard let match = Geo.project(point, onto: route.coordinates, from: start, to: limit) else { return nil }
        let base = route.along[match.segment]
        let travelled = base + (route.along[match.segment + 1] - base) * match.fraction
        let total = route.along.last ?? 0
        let next = upcomingStep(on: route, after: travelled)
        let maneuverAt = route.stepStart.indices.contains(next.show) ? route.stepStart[next.show] : total
        let distanceToManeuver = max(0, maneuverAt - travelled)
        return RouteProgress(
            segment: match.segment,
            nextStep: next.show,
            distanceToManeuver: distanceToManeuver,
            remainingDistance: max(0, total - travelled),
            remainingDuration: remainingDuration(on: route, nextStep: next.first, left: distanceToManeuver),
            offRouteBy: match.distance
        )
    }

    /// The maneuver to show: the first step strictly ahead (step 0 is depart).
    /// When zero-length steps share its vertex, the first one that asks the
    /// driver to act wins, so a turn isn't hidden behind a "new name".
    /// `first` is the first step at that vertex, for timing.
    static func upcomingStep(on route: Route, after travelled: Double) -> (show: Int, first: Int) {
        let starts = route.stepStart
        guard let first = starts.indices.dropFirst().first(where: { starts[$0] > travelled }) else {
            let last = max(0, route.steps.count - 1)
            return (last, last)
        }
        let tied = starts.indices[first...].prefix { starts[$0] - starts[first] < 1 }
        return (tied.first { !isPassive(route.steps[$0]) } ?? first, first)
    }

    /// Steps that ask nothing of the driver: renames, carrying straight on, arriving.
    static func isPassive(_ step: Route.Step) -> Bool {
        switch step.type {
        case "new name", "arrive": true
        case "continue", "notification": step.modifier == nil || step.modifier == "straight"
        default: false
        }
    }

    /// Whole steps still ahead, plus the unfinished share of the current one.
    /// Scaled up by the route's traffic delay, spread evenly over the trip.
    static func remainingDuration(on route: Route, nextStep: Int, left distanceToManeuver: Double) -> Double {
        let scale = route.duration > 0 ? route.eta / route.duration : 1
        guard nextStep > 0, nextStep <= route.steps.count else { return route.eta }
        let current = route.steps[nextStep - 1]
        let share = current.distance > 0 ? min(1, distanceToManeuver / current.distance) : 0
        return (current.duration * share + route.steps[nextStep...].reduce(0) { $0 + $1.duration }) * scale
    }

    /// Near the end and on the road: a parallel street 80 m away doesn't count.
    static func hasArrived(_ progress: RouteProgress) -> Bool {
        progress.remainingDistance <= arrivalDistance && progress.offRouteBy <= offRouteDistance
    }

    /// Spoken prompts per maneuver: an early one ("In 600 m, turn left") and a
    /// late one ("Turn left"), each about `lead` seconds ahead at the current
    /// speed but never closer than `floor` metres.
    static let prompts: [(lead: TimeInterval, floor: Double)] = [(20, 500), (2.5, 50)]

    /// Metres before a maneuver at which each prompt is due, at `speed` m/s.
    static func announceAt(speed: Double) -> [Double] {
        prompts.map { max($0.floor, $0.lead * max(0, speed)) }
    }

    /// A spoken prompt: one per maneuver per tier (0 early, 1 late).
    struct Announcement: Hashable {
        var step: Int
        var tier: Int
    }

    /// The prompt due now, if any. Crossing several thresholds at once (e.g. a
    /// reroute that starts 30 m from a turn) speaks only the latest tier.
    static func due(_ progress: RouteProgress, speed: Double = 0, spoken: Set<Announcement>) -> Announcement? {
        let thresholds = announceAt(speed: speed)
        guard let tier = thresholds.indices.last(where: { progress.distanceToManeuver <= thresholds[$0] })
        else { return nil }
        let due = Announcement(step: progress.nextStep, tier: tier)
        return spoken.contains(due) ? nil : due
    }

    /// Tiers now passed for this step, so earlier ones are never spoken late.
    static func markSpoken(_ announcement: Announcement) -> [Announcement] {
        (0 ... announcement.tier).map { Announcement(step: announcement.step, tier: $0) }
    }

    /// Seconds before reroute attempt `attempt + 1`: 5, 10, 20, 40, then 60.
    static func retryDelay(after attempt: Int) -> TimeInterval {
        min(60, 5 * pow(2, Double(max(0, attempt - 1))))
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

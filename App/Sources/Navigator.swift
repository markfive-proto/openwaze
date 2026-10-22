import CoreLocation

/// Drives a trip: fetch a route, preview it, then guide along it with
/// spoken prompts, rerouting when the driver leaves it.
@MainActor
@Observable
final class Navigator {
    enum Phase: Equatable {
        case idle, routing, preview, navigating, arrived
        case failed(String)
    }

    typealias FetchRoute = (CLLocationCoordinate2D, CLLocationCoordinate2D) async throws -> Route
    typealias Sleep = (TimeInterval) async throws -> Void

    private(set) var phase = Phase.idle
    private(set) var route: Route?
    private(set) var progress: RouteProgress?
    private(set) var destination: Destination?

    @ObservationIgnored private let fetchRoute: FetchRoute
    @ObservationIgnored private let speech: Speaking
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let sleep: Sleep
    @ObservationIgnored private let feed: LocationFeed?

    /// Bumped when a trip starts or ends: a response for an older trip is dropped.
    @ObservationIgnored private var trip = 0
    /// Bumped per route, so prompts for a replaced route count as stale.
    @ObservationIgnored private var routeVersion = 0
    @ObservationIgnored private var spoken: Set<Guidance.Announcement> = []
    @ObservationIgnored private var greeted = false
    @ObservationIgnored private var offRoute = Guidance.OffRouteTimer()
    @ObservationIgnored private var rerouting = false
    @ObservationIgnored private var lastFix: CLLocation?
    /// The latest background job (delayed recheck or reroute); tests await it.
    @ObservationIgnored private(set) var work: Task<Void, Never>?

    init(
        fetchRoute: @escaping FetchRoute = { try await Router.route(from: $0, to: $1) },
        speech: Speaking = Speech(),
        now: @escaping () -> Date = Date.init,
        sleep: @escaping Sleep = { try await Task.sleep(for: .seconds($0)) },
        feed: LocationFeed? = LocationFeed()
    ) {
        self.fetchRoute = fetchRoute
        self.speech = speech
        self.now = now
        self.sleep = sleep
        self.feed = feed
    }

    /// Upcoming maneuver while navigating.
    var nextStep: Route.Step? {
        guard phase == .navigating, let route, let progress else { return nil }
        return route.steps.indices.contains(progress.nextStep) ? route.steps[progress.nextStep] : nil
    }

    func preview(to destination: Destination, from origin: CLLocationCoordinate2D?) async {
        trip += 1
        let trip = trip
        self.destination = destination
        route = nil
        progress = nil
        guard let origin else {
            phase = .failed(String(localized: "Current location unavailable"))
            return
        }
        phase = .routing
        do {
            let found = try await fetchRoute(origin, destination.coordinate)
            guard trip == self.trip else { return } // a newer trip or End won
            use(found, at: origin)
            phase = .preview
        } catch {
            guard trip == self.trip else { return }
            phase = .failed(isUnavailable(error)
                ? String(localized: "Routing unavailable, check connection")
                : String(localized: "No route found"))
        }
    }

    func start() {
        guard phase == .preview else { return }
        phase = .navigating
        spoken = []
        greeted = false
        offRoute.reset()
        feed?.start { [weak self] location in
            MainActor.assumeIsolated { self?.update(location) }
        }
    }

    func end() {
        trip += 1
        feed?.stop()
        work?.cancel()
        work = nil
        rerouting = false
        lastFix = nil
        speech.stop()
        phase = .idle
        route = nil
        progress = nil
        destination = nil
    }

    func update(_ location: CLLocation) {
        guard phase == .navigating, let route, location.horizontalAccuracy >= 0,
              let current = Guidance.progress(on: route, at: location.coordinate, from: progress?.segment ?? 0)
        else { return }
        lastFix = location
        progress = current
        if Guidance.hasArrived(current) {
            arrive(route)
            return
        }
        let onRoute = current.offRouteBy <= Guidance.offRouteDistance
        // A vague fix (urban canyon, tunnel exit) can't say we left the road.
        guard location.horizontalAccuracy <= Guidance.maxFixAccuracy else {
            if onRoute {
                announce(current, speed: location.speed)
            }
            return
        }
        let wasOff = offRoute.since != nil
        if offRoute.update(offRouteBy: current.offRouteBy, at: now()) {
            reroute(from: location.coordinate)
        } else if offRoute.since != nil, !wasOff {
            // A stopped car gets no new fixes, so look again once the delay is up.
            let trip = trip
            work = Task { [weak self] in
                try? await self?.sleep(Guidance.offRouteDelay + 0.1)
                guard let self, trip == self.trip, lastFix === location else { return } // newer fixes took over
                update(location)
            }
        } else if onRoute {
            announce(current, speed: location.speed)
        }
    }

    private func arrive(_ route: Route) {
        phase = .arrived
        feed?.stop()
        work?.cancel()
        if let last = route.steps.last {
            speech.say(Instruction.text(for: last), key: PromptKey(route: routeVersion, step: route.steps.count))
        }
    }

    private func announce(_ progress: RouteProgress, speed: Double) {
        guard let step = nextStep else { return }
        let key = PromptKey(route: routeVersion, step: progress.nextStep)
        if let due = Guidance.due(progress, speed: speed, spoken: spoken) {
            let text = Instruction.spoken(for: step, distance: progress.distanceToManeuver, early: due.tier == 0)
            speech.say(text, key: key)
            spoken.formUnion(Guidance.markSpoken(due))
        } else if !greeted {
            speech.say(Instruction.spoken(for: step, distance: progress.distanceToManeuver, early: true), key: key)
        }
        greeted = true
    }

    /// Fetches a new route, retrying with backoff (5, 10, 20... 60 s) while
    /// still off route. At most one request is in flight.
    private func reroute(from origin: CLLocationCoordinate2D) {
        guard !rerouting, let destination else { return }
        rerouting = true
        let trip = trip
        work = Task { [weak self] in
            var origin = origin
            var attempt = 0
            while let self, trip == self.trip {
                do {
                    let found = try await fetchRoute(origin, destination.coordinate)
                    guard trip == self.trip, phase == .navigating else { return }
                    use(found, at: origin)
                    rerouting = false
                    return
                } catch {
                    attempt += 1
                    try? await sleep(Guidance.retryDelay(after: attempt))
                    // Back on route, ended, or a newer trip: stop retrying.
                    guard trip == self.trip, phase == .navigating, offRoute.since != nil, let fix = lastFix else {
                        if trip == self.trip {
                            rerouting = false
                        }
                        return
                    }
                    origin = fix.coordinate
                }
            }
        }
    }

    private func use(_ found: Route, at origin: CLLocationCoordinate2D) {
        route = found
        routeVersion += 1
        progress = Guidance.progress(on: found, at: origin)
        spoken = []
        greeted = false
        offRoute.reset()
    }

    /// Rate limits and server or network failures, as opposed to "no road there".
    private func isUnavailable(_ error: Error) -> Bool {
        if case .noRoute = error as? RouterError {
            return false
        }
        return true
    }
}

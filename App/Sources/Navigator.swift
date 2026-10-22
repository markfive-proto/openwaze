import CoreLocation

/// Drives a trip: fetch a route, preview it, then guide along it with
/// spoken prompts, rerouting when the driver leaves it.
/// A route found while driving that beats the current one.
struct FasterRoute {
    let route: Route
    /// Seconds saved over staying on the current route.
    let saves: Double
}

@MainActor
@Observable
final class Navigator {
    enum Phase: Equatable {
        case idle, routing, preview, navigating, arrived
        case failed(String)
    }

    typealias Offer = FasterRoute
    typealias FetchRoutes = (CLLocationCoordinate2D, CLLocationCoordinate2D) async throws -> [Route]
    typealias Sleep = (TimeInterval) async throws -> Void

    /// How often a trip looks for a faster route.
    static let recheckInterval: TimeInterval = 120
    /// A faster route is offered only if it saves at least this many seconds.
    static let minSaving: TimeInterval = 60

    private(set) var phase = Phase.idle
    private(set) var route: Route?
    /// The routes to pick from in preview, fastest first; `route` is one of them.
    private(set) var alternatives: [Route] = []
    private(set) var progress: RouteProgress?
    private(set) var destination: Destination?
    private(set) var faster: Offer?

    @ObservationIgnored private let fetchRoutes: FetchRoutes
    @ObservationIgnored private let traffic: Traffic.Fetch?
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
    @ObservationIgnored private var checking = false
    @ObservationIgnored private var lastFix: CLLocation?
    /// The latest background job (delayed recheck or reroute); tests await it.
    @ObservationIgnored private(set) var work: Task<Void, Never>?
    /// The latest faster-route check; tests await it.
    @ObservationIgnored private(set) var check: Task<Void, Never>?
    @ObservationIgnored private var nextCheck = Date.distantFuture
    @ObservationIgnored private var previewOrigin: CLLocationCoordinate2D?

    init(
        fetchRoutes: @escaping FetchRoutes = { try await Router.routes(from: $0, to: $1) },
        traffic: Traffic.Fetch? = nil,
        speech: Speaking = Speech(),
        now: @escaping () -> Date = Date.init,
        sleep: @escaping Sleep = { try await Task.sleep(for: .seconds($0)) },
        feed: LocationFeed? = LocationFeed()
    ) {
        self.fetchRoutes = fetchRoutes
        self.traffic = traffic
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
        alternatives = []
        faster = nil
        previewOrigin = nil
        progress = nil
        guard let origin else {
            phase = .failed(String(localized: "Current location unavailable"))
            return
        }
        phase = .routing
        do {
            let found = try await bestFirst(fetchRoutes(origin, destination.coordinate))
            guard trip == self.trip, let best = found.first else { return } // a newer trip or End won
            alternatives = found
            previewOrigin = origin
            use(best, at: origin)
            phase = .preview
        } catch {
            guard trip == self.trip else { return }
            phase = .failed(isUnavailable(error)
                ? String(localized: "Routing unavailable, check connection")
                : String(localized: "No route found"))
        }
    }

    /// Picks one of the previewed routes.
    func select(_ index: Int) {
        guard phase == .preview, alternatives.indices.contains(index), let origin = previewOrigin else { return }
        use(alternatives[index], at: origin)
    }

    func start() {
        guard phase == .preview else { return }
        phase = .navigating
        spoken = []
        greeted = false
        offRoute.reset()
        alternatives = []
        nextCheck = now().addingTimeInterval(Self.recheckInterval)
        feed?.start { [weak self] location in
            MainActor.assumeIsolated { self?.update(location) }
        }
    }

    func end() {
        trip += 1
        feed?.stop()
        work?.cancel()
        work = nil
        check?.cancel()
        check = nil
        checking = false
        faster = nil
        alternatives = []
        nextCheck = .distantFuture
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
        checkForFasterRoute(from: location)
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
        check?.cancel()
        checking = false
        faster = nil
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
                    let found = try await bestFirst(fetchRoutes(origin, destination.coordinate))
                    guard trip == self.trip, phase == .navigating, let best = found.first else { return }
                    use(best, at: origin)
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

    /// Every 2 minutes of driving (counted on the fixes that arrive), look for
    /// a route that saves a minute or more, and offer it. At most one request
    /// is in flight; the answer is dropped if the trip ended or the route changed.
    private func checkForFasterRoute(from fix: CLLocation) {
        guard !checking, !rerouting, offRoute.since == nil, now() >= nextCheck,
              fix.horizontalAccuracy <= Guidance.maxFixAccuracy, let destination, let current = route
        else { return }
        checking = true
        nextCheck = now().addingTimeInterval(Self.recheckInterval)
        let (trip, version, origin) = (trip, routeVersion, fix.coordinate)
        check = Task { [weak self] in
            // The current route rides along so both are priced with the same fresh traffic.
            let found = try? await self?.fetchRoutes(origin, destination.coordinate)
            guard let self, let found, !found.isEmpty else {
                if let self, trip == self.trip {
                    checking = false
                }
                return
            }
            let priced = await Traffic.adjusted([current] + found, using: traffic)
            guard trip == self.trip else { return } // ended or restarted; end() reset the flag
            checking = false
            guard version == routeVersion, phase == .navigating, let repriced = priced.first,
                  let best = priced.dropFirst().min(by: { $0.eta < $1.eta }) else { return }
            let remaining = Guidance.progress(on: repriced, at: origin, from: progress?.segment ?? 0)?
                .remainingDuration ?? repriced.eta
            let saves = remaining - best.eta
            faster = saves >= Self.minSaving ? Offer(route: best, saves: saves) : nil
        }
    }

    /// Takes the offered route, from where the driver is now.
    func acceptFaster() {
        guard phase == .navigating, let offer = faster, let fix = lastFix else { return }
        use(offer.route, at: fix.coordinate)
    }

    func dismissFaster() {
        faster = nil
    }

    private func bestFirst(_ routes: [Route]) async -> [Route] {
        await Traffic.fastestFirst(routes, using: traffic)
    }

    private func use(_ found: Route, at origin: CLLocationCoordinate2D) {
        route = found
        faster = nil
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

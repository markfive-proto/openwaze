import AVFoundation
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

    private(set) var phase = Phase.idle
    private(set) var route: Route?
    private(set) var progress: RouteProgress?
    private(set) var destination: Destination?

    private var spoken: Set<Guidance.Announcement> = []
    private var greeted = false
    private var offRoute = Guidance.OffRouteTimer()
    private var rerouting = false
    private var lastFix: CLLocation?
    private var updates: Task<Void, Never>?
    @ObservationIgnored private let speech = Speech()

    /// Upcoming maneuver while navigating.
    var nextStep: Route.Step? {
        guard phase == .navigating, let route, let progress else { return nil }
        return route.steps.indices.contains(progress.nextStep) ? route.steps[progress.nextStep] : nil
    }

    func preview(to destination: Destination, from origin: CLLocationCoordinate2D?) async {
        self.destination = destination
        guard let origin else {
            phase = .failed(String(localized: "Current location unavailable"))
            return
        }
        phase = .routing
        do {
            let found = try await Router.route(from: origin, to: destination.coordinate)
            guard phase == .routing, self.destination == destination else { return } // cancelled meanwhile
            route = found
            progress = Guidance.progress(on: found, at: origin)
            phase = .preview
        } catch RouterError.noRoute {
            phase = .failed(String(localized: "No route found"))
        } catch {
            phase = .failed(String(localized: "Routing unavailable, check connection"))
        }
    }

    func start() {
        guard phase == .preview else { return }
        phase = .navigating
        spoken = []
        greeted = false
        offRoute.reset()
        updates = Task { [weak self] in
            do {
                for try await update in CLLocationUpdate.liveUpdates(.automotiveNavigation) {
                    guard let self, !Task.isCancelled else { return }
                    if let location = update.location {
                        self.update(location)
                    }
                }
            } catch {} // stream ended; nothing to clean up
        }
    }

    func end() {
        updates?.cancel()
        updates = nil
        speech.stop()
        phase = .idle
        route = nil
        progress = nil
        destination = nil
    }

    func update(_ location: CLLocation) {
        guard phase == .navigating, let route, location.horizontalAccuracy >= 0,
              let now = Guidance.progress(on: route, at: location.coordinate, from: progress?.segment ?? 0)
        else { return }
        lastFix = location
        progress = now
        if Guidance.hasArrived(now) {
            phase = .arrived
            updates?.cancel()
            updates = nil
            if let last = route.steps.last {
                speech.say(Instruction.text(for: last))
            }
            return
        }
        let wasOff = offRoute.since != nil
        if offRoute.update(offRouteBy: now.offRouteBy, at: .now) {
            reroute(from: location.coordinate)
        } else if offRoute.since != nil, !wasOff {
            // A stopped car gets no new fixes, so look again once the delay is up.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(Guidance.offRouteDelay + 0.1))
                guard let self, lastFix === location else { return } // newer fixes took over
                update(location)
            }
        } else if now.offRouteBy <= Guidance.offRouteDistance {
            announce(now)
        }
    }

    private func announce(_ progress: RouteProgress) {
        guard let step = nextStep else { return }
        if let due = Guidance.announcement(for: progress, spoken: spoken) {
            speech.say(Instruction.spoken(for: step, distance: progress.distanceToManeuver, threshold: due.threshold))
            spoken.formUnion(Guidance.markSpoken(due))
        } else if !greeted {
            speech.say(Instruction.spoken(for: step, distance: progress.distanceToManeuver, threshold: .infinity))
        }
        greeted = true
    }

    private func reroute(from origin: CLLocationCoordinate2D) {
        guard !rerouting, let destination else { return } // max one request in flight
        rerouting = true
        Task {
            defer { rerouting = false }
            do {
                let found = try await Router.route(from: origin, to: destination.coordinate)
                guard phase == .navigating, self.destination == destination else { return }
                route = found
                progress = Guidance.progress(on: found, at: origin)
                spoken = []
                greeted = false
            } catch {
                // Keep the old route; the timer restarts so we retry in 5 s, not every fix.
            }
            offRoute.reset()
        }
    }
}

/// Spoken prompts that duck other audio (music, podcasts) while talking.
final class Speech: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func say(_ text: String) {
        let session = AVAudioSession.sharedInstance()
        let options: AVAudioSession.CategoryOptions = [.duckOthers, .interruptSpokenAudioAndMixWithOthers]
        try? session.setCategory(.playback, mode: .voicePrompt, options: options)
        try? session.setActive(true)
        synthesizer.stopSpeaking(at: .immediate) // newer prompt wins
        synthesizer.speak(AVSpeechUtterance(string: text))
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish _: AVSpeechUtterance) {
        guard !synthesizer.isSpeaking else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

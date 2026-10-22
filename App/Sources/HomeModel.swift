import CoreLocation
import SwiftData

/// Home screen state: which bottom panel and floating controls show, and the
/// actions that move between them. Kept out of the view so it can be tested.
@MainActor
@Observable
final class HomeModel {
    enum Panel: Equatable {
        case search
        case place(Destination)
        case trip // routing, preview, arrived, failed
        case driving
    }

    let navigator: Navigator
    var destination: Destination?
    /// The search sheet is expanded.
    var searching = false
    /// While navigating: whether the camera follows the user.
    var following = true
    /// Bumped to snap the camera back to the user when not navigating.
    private(set) var recenter = 0
    /// A save or load failure to show the user.
    var problem: String?

    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let origin: () -> CLLocationCoordinate2D?
    /// The latest route request; tests await it.
    @ObservationIgnored private(set) var preview: Task<Void, Never>?

    init(navigator: Navigator, context: ModelContext, origin: @escaping () -> CLLocationCoordinate2D?) {
        self.navigator = navigator
        self.context = context
        self.origin = origin
    }

    var guiding: Bool {
        [.navigating, .arrived].contains(navigator.phase)
    }

    var panel: Panel {
        switch navigator.phase {
        case .navigating: .driving
        case .idle: destination.map(Panel.place) ?? .search
        default: .trip
        }
    }

    /// Speed, re-centre and report. Hidden while searching and in route
    /// preview, where they would cover the results or the route.
    var showsControls: Bool {
        !searching && [.idle, .navigating, .arrived].contains(navigator.phase)
    }

    var showsMenu: Bool {
        !searching && !guiding
    }

    var showsRecenter: Bool {
        navigator.phase == .navigating ? !following : navigator.phase == .idle
    }

    func pick(_ place: Destination) {
        searching = false
        destination = place
    }

    /// Records a recent and previews the route.
    func go(_ place: Destination) {
        searching = false
        destination = place
        attempt { try Places.recordRecent(place, in: context) }
        preview?.cancel() // Navigator also drops stale answers via its trip counter
        let navigator = navigator
        let from = origin()
        preview = Task { await navigator.preview(to: place, from: from) }
    }

    func retry() {
        navigator.destination.map(go)
    }

    func start() {
        navigator.start()
        following = true
    }

    /// Close on a trip card: back to the place card, or home once guiding.
    func closeTrip() {
        if guiding {
            endTrip()
        } else {
            preview?.cancel()
            navigator.end()
        }
    }

    func endTrip() {
        preview?.cancel()
        navigator.end()
        destination = nil
        searching = false
        following = true
    }

    func recentre() {
        if navigator.phase == .navigating {
            following = true
        } else {
            recenter += 1
        }
    }

    func save(_ place: Destination, as role: Place.Role) {
        attempt { try Places.save(place, as: role, in: context) }
    }

    func remove(_ place: Place) {
        attempt { try Places.remove(place, in: context) }
    }

    private func attempt(_ work: () throws -> Void) {
        do {
            try work()
        } catch {
            problem = String(localized: "Couldn't save the place. Try again.")
        }
    }
}

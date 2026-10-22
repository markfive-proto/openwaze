import SwiftData
import SwiftUI

@main
struct OpenWazeApp: App {
    var body: some Scene {
        WindowGroup {
            HomeView()
                .fontDesign(.rounded)
                .tint(Theme.accent)
        }
        .modelContainer(for: Place.self)
    }
}

/// Map with floating chrome: the bottom panel follows the trip phase
/// (search sheet, place card, route preview, driving bar).
struct HomeView: View {
    private enum Sheet: String, Identifiable {
        case report, settings
        var id: String {
            rawValue
        }
    }

    @Environment(\.modelContext) private var context
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var location = LocationAuthorization()
    @State private var destination: Destination?
    @State private var navigator = Navigator()
    @State private var following = true
    @State private var recenter = 0
    @State private var searching = false
    @State private var sheet: Sheet?
    @State private var reports = 0
    @State private var bottomInset: CGFloat = 0

    private var guiding: Bool {
        [.navigating, .arrived].contains(navigator.phase)
    }

    var body: some View {
        MapView(
            destination: destination, route: navigator.route,
            navigating: navigator.phase == .navigating, following: following,
            onUnfollow: { following = false }, recenter: recenter, bottomInset: searching ? 0 : bottomInset
        )
        .ignoresSafeArea()
        .overlay(alignment: .top) { top }
        .overlay(alignment: .bottom) { bottom }
        .animation(Theme.spring, value: navigator.phase)
        .animation(Theme.spring, value: destination)
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .report: ReportSheet(onPick: { _ in reports += 1 }) // posting to the API is #11
            case .settings: SettingsView()
            }
        }
        .sensoryFeedback(trigger: navigator.phase) { _, phase in
            switch phase {
            case .arrived: .success
            case .failed: .error
            default: .impact(weight: .medium)
            }
        }
        .sensoryFeedback(.success, trigger: reports)
        .onChange(of: navigator.phase) { following = true }
        .onAppear { location.request() }
    }

    @ViewBuilder private var top: some View {
        if guiding {
            if let step = navigator.nextStep, let progress = navigator.progress {
                ManeuverBanner(step: step, distance: progress.distanceToManeuver)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        } else if !searching {
            HStack {
                Button(String(localized: "Menu"), systemImage: "line.3.horizontal") { sheet = .settings }
                    .buttonStyle(RoundButtonStyle())
                Spacer()
            }
            .padding(.horizontal, Theme.Space.large)
        }
    }

    private var bottom: some View {
        VStack(spacing: 0) {
            // Hidden while searching and in route preview, where they would cover the route.
            if !searching, [.idle, .navigating, .arrived].contains(navigator.phase) {
                controls
                    .padding(.horizontal, Theme.Space.large)
                    // Leaves a strip for the map's logo and attribution.
                    .padding(.bottom, 36)
                    .transition(.opacity)
            }
            panel
                .transition(Theme.rise(reduceMotion: reduceMotion))
                .onGeometryChange(for: CGFloat.self, of: \.size.height) { bottomInset = $0 }
        }
    }

    private var controls: some View {
        HStack(alignment: .bottom) {
            SpeedBubble()
            Spacer()
            VStack(spacing: Theme.Space.medium) {
                if navigator.phase == .navigating ? !following : navigator.phase == .idle {
                    Button(String(localized: "Re-centre"), systemImage: "location.fill") {
                        if navigator.phase == .navigating {
                            following = true
                        } else {
                            recenter += 1
                        }
                    }
                    .buttonStyle(RoundButtonStyle())
                    .transition(.scale.combined(with: .opacity))
                }
                Button(String(localized: "Report"), systemImage: "exclamationmark.bubble.fill") { sheet = .report }
                    .buttonStyle(RoundButtonStyle(size: Theme.fab, filled: true))
            }
        }
    }

    @ViewBuilder private var panel: some View {
        if navigator.phase == .navigating, let progress = navigator.progress {
            NavigationBar(progress: progress, onEnd: endTrip)
        } else if navigator.phase != .idle {
            TripCard(navigator: navigator, onRetry: { navigator.destination.map(go) }, onClose: {
                if guiding {
                    endTrip()
                } else {
                    navigator.end() // back to the place card
                }
            })
        } else if let destination {
            DestinationCard(
                destination: destination, onGo: go,
                onSave: { try? Places.save(destination, as: $0, in: context) },
                onClose: { self.destination = nil }
            )
        } else {
            VStack(spacing: Theme.Space.medium) {
                if location.isDenied, !searching {
                    LocationHint()
                }
                SearchView(
                    near: { location.coordinate },
                    onPick: { destination = $0 },
                    onGo: go,
                    expanded: $searching
                )
            }
        }
    }

    /// Records a recent and previews the route.
    private func go(_ place: Destination) {
        destination = place
        try? Places.recordRecent(place, in: context)
        Task { await navigator.preview(to: place, from: location.coordinate) }
    }

    private func endTrip() {
        navigator.end()
        destination = nil
    }
}

/// Current speed; a placeholder until speed and limits land (#15).
struct SpeedBubble: View {
    private var unit: String {
        Locale.current.measurementSystem == .us ? String(localized: "mph") : String(localized: "km/h")
    }

    var body: some View {
        VStack(spacing: -2) {
            Text(verbatim: "–").font(.title2.weight(.heavy)).monospacedDigit()
            Text(unit).font(.caption2.weight(.bold)).foregroundStyle(.secondary)
        }
        .frame(width: Theme.fab, height: Theme.fab)
        .background(Theme.surface, in: Circle())
        .overlay(Circle().strokeBorder(Color.primary.opacity(0.85), lineWidth: 3))
        .shadow(color: Theme.shadow, radius: 10, y: 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Speed unavailable"))
    }
}

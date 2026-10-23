import SwiftData
import SwiftUI

@main
struct OpenWazeApp: App {
    private let store = Places.makeContainer()

    var body: some Scene {
        WindowGroup {
            HomeView(context: store.container.mainContext, storeFailed: store.error != nil)
                .fontDesign(.rounded)
                .tint(Theme.accent)
        }
        .modelContainer(store.container)
    }
}

/// Map with floating chrome: the bottom panel follows `HomeModel.panel`
/// (search sheet, place card, route preview, driving bar).
struct HomeView: View {
    private enum Sheet: String, Identifiable {
        case report, settings
        var id: String {
            rawValue
        }
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.scenePhase) private var scenePhase
    @State private var location: LocationAuthorization
    @State private var model: HomeModel
    @State private var sheet: Sheet?
    /// Height of the collapsed bottom chrome, for the map's route fit and attribution.
    @State private var bottomInset: CGFloat = 0
    @State private var reports = ReportsStore()
    /// Reports already asked about this trip.
    @State private var stillThere = StillThere()
    /// The "Still there?" card showing, if any.
    @State private var prompt: Report?
    /// A failed report or vote, shown briefly at the top.
    @State private var toast: String?
    /// Bumped after a report is accepted, for the success haptic.
    @State private var reported = 0
    /// The previewed route passes a toll plaza (#30); recomputed per route, not per render.
    @State private var tolls: Bool?

    init(context: ModelContext, storeFailed: Bool) {
        let location = LocationAuthorization()
        let model = HomeModel(navigator: Navigator(), context: context, origin: { location.coordinate })
        if storeFailed {
            model.problem = String(localized: "Saved places couldn't be opened. Changes won't be kept.")
        }
        _location = State(initialValue: location)
        _model = State(initialValue: model)
    }

    private var navigator: Navigator {
        model.navigator
    }

    var body: some View {
        ZStack {
            MapView(
                destination: model.destination, route: navigator.route,
                navigating: navigator.phase == .navigating, following: model.following,
                onUnfollow: { model.following = false }, recenter: model.recenter, bottomInset: bottomInset,
                reports: reports.reports, onRegion: { reports.setRegion($0) }
            )
            .ignoresSafeArea()
            VStack(spacing: Theme.Space.medium) {
                if let toast {
                    Toast(text: toast)
                        .transition(Theme.slide(.top, reduceMotion: reduceMotion))
                }
                top
                Spacer(minLength: 0)
                bottom
            }
        }
        .animation(Theme.motion(reduceMotion), value: navigator.phase)
        .animation(Theme.motion(reduceMotion), value: model.destination)
        .animation(Theme.motion(reduceMotion), value: model.searching)
        .animation(Theme.motion(reduceMotion), value: toast)
        .animation(Theme.motion(reduceMotion), value: prompt?.id)
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .report: ReportSheet(onPick: post)
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
        .alert(
            String(localized: "Something went wrong"),
            isPresented: Binding(get: { model.problem != nil }, set: {
                if !$0 {
                    model.problem = nil
                }
            }),
            actions: { Button("OK") {} },
            message: { Text(model.problem ?? "") }
        )
        .sensoryFeedback(.success, trigger: reported)
        .onChange(of: navigator.phase) { _, phase in
            model.following = true
            if phase != .navigating {
                prompt = nil
                stillThere = StillThere() // the next trip asks afresh
            }
        }
        .onChange(of: navigator.progress) { askAboutReportAhead() }
        .onChange(of: navigator.route?.id, initial: true) {
            tolls = navigator.route.map { !Tolls.plazas(on: $0.coordinates).isEmpty }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active {
                reports.start()
            } else {
                reports.stop()
            }
        }
        .task(id: toast) {
            guard toast != nil, await (try? Task.sleep(for: .seconds(4))) != nil else { return }
            toast = nil
        }
        .task(id: prompt?.id) {
            guard prompt != nil, await (try? Task.sleep(for: .seconds(20))) != nil else { return }
            prompt = nil // unanswered: passed it, or not looking
        }
        .onAppear { location.request() }
    }

    @ViewBuilder private var top: some View {
        if model.guiding {
            if let step = navigator.nextStep, let progress = navigator.progress {
                ManeuverBanner(step: step, distance: progress.distanceToManeuver)
                    .transition(Theme.slide(.top, reduceMotion: reduceMotion))
            }
            if let prompt {
                StillThereCard(report: prompt) { answer(prompt, stillThere: $0) }
                    .transition(Theme.slide(.top, reduceMotion: reduceMotion))
            }
        } else if model.showsMenu {
            HStack {
                Button(String(localized: "Menu"), systemImage: "line.3.horizontal") { sheet = .settings }
                    .buttonStyle(RoundButtonStyle())
                Spacer()
            }
            .padding(.horizontal, Theme.Space.large)
        }
    }

    /// Posts at the user's position; the haptic waits for the server's yes.
    private func post(_ type: ReportType) {
        guard let here = location.coordinate else {
            toast = String(localized: "Current location unavailable")
            return
        }
        Task {
            do {
                try await reports.report(type, at: here)
                reported += 1
            } catch {
                toast = reportProblem(error)
            }
        }
    }

    private func askAboutReportAhead() {
        guard prompt == nil, navigator.phase == .navigating,
              let route = navigator.route, let progress = navigator.progress else { return }
        prompt = stillThere.next(on: route, at: progress, reports: reports.votable, mine: reports.mine)
    }

    private func answer(_ report: Report, stillThere: Bool) {
        prompt = nil
        Task {
            do {
                try await reports.vote(report.id, stillThere: stillThere)
            } catch {
                toast = reportProblem(error)
            }
        }
    }

    private var bottom: some View {
        VStack(spacing: 0) {
            if model.showsControls {
                controls
                    .padding(.horizontal, Theme.Space.large)
                    // Leaves a strip for the map's logo and attribution.
                    .padding(.bottom, 36)
                    .transition(.opacity)
            }
            panel
                .transition(Theme.slide(.bottom, reduceMotion: reduceMotion))
                .onGeometryChange(for: CGFloat.self, of: \.size.height) { height in
                    // The expanded search sheet covers the map; keep the collapsed inset.
                    if !model.searching {
                        bottomInset = height
                    }
                }
        }
    }

    private var controls: some View {
        HStack(alignment: .bottom) {
            SpeedBubble()
            Spacer()
            // Stacked, or side by side at accessibility sizes to leave room for the map.
            let buttons = typeSize.isAccessibilitySize
                ? AnyLayout(HStackLayout(alignment: .bottom, spacing: Theme.Space.medium))
                : AnyLayout(VStackLayout(spacing: Theme.Space.medium))
            buttons {
                if model.showsRecenter {
                    Button(String(localized: "Re-centre"), systemImage: "location.fill", action: model.recentre)
                        .buttonStyle(RoundButtonStyle())
                        .transition(reduceMotion ? .opacity : .scale.combined(with: .opacity))
                }
                Button(String(localized: "Report"), systemImage: "exclamationmark.bubble.fill") { sheet = .report }
                    .buttonStyle(RoundButtonStyle(size: Theme.fab, filled: true))
            }
        }
    }

    @ViewBuilder private var panel: some View {
        switch model.panel {
        case .driving:
            if let progress = navigator.progress {
                NavigationBar(progress: progress, onEnd: model.endTrip)
            }
        case .trip:
            TripCard(navigator: navigator, tolls: tolls,
                     onStart: model.start, onRetry: model.retry, onClose: model.closeTrip)
        case let .place(destination):
            DestinationCard(
                destination: destination, onGo: model.go,
                onSave: { model.save(destination, as: $0) },
                onClose: { model.destination = nil }
            )
        case .search:
            VStack(spacing: Theme.Space.medium) {
                if location.isDenied, !model.searching {
                    LocationHint()
                }
                SearchView(
                    near: { location.coordinate },
                    onPick: model.pick,
                    onGo: model.go,
                    onSave: model.save,
                    onRemove: model.remove,
                    expanded: $model.searching
                )
            }
        }
    }
}

/// Current speed; a placeholder until speed and limits land (#15).
struct SpeedBubble: View {
    @Scaled private var size: CGFloat = Theme.fab

    private var unit: String {
        Locale.current.measurementSystem == .metric ? String(localized: "km/h") : String(localized: "mph")
    }

    var body: some View {
        VStack(spacing: -2) {
            Text(verbatim: "–").font(.title2.weight(.heavy)).monospacedDigit()
            Text(unit).font(.caption2.weight(.bold)).foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .frame(width: size, height: size)
        .background(Theme.surface, in: Circle())
        .overlay(Circle().strokeBorder(Color.primary.opacity(0.85), lineWidth: 3))
        .shadow(color: Theme.shadow, radius: 10, y: 4)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge) // glyph inside a fixed disc
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Speed unavailable"))
    }
}

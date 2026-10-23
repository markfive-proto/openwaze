import AudioToolbox
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
            SpeedBubble(speed: navigator.speed, limit: navigator.speedLimit)
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
            TripCard(navigator: navigator, onStart: model.start, onRetry: model.retry, onClose: model.closeTrip)
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

/// Current speed, the road's limit, and red plus a chime when over the
/// limit by the margin set in Settings.
struct SpeedBubble: View {
    static let marginKey = "speedWarningMargin"
    static let marginChoices = [0, 5, 10, 15, 20] // in the locale's unit

    var speed: Double?
    var limit: Double?
    @AppStorage(marginKey) private var margin = 5
    @Scaled private var size: CGFloat = Theme.fab

    private var over: Bool {
        Speedometer.isOver(speed: speed, limit: limit, margin: Double(margin) / Speedometer.unitFactor())
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: Theme.Space.small) {
            VStack(spacing: -2) {
                Text(verbatim: Speedometer.display(speed) ?? "–").font(.title2.weight(.heavy)).monospacedDigit()
                Text(Speedometer.unitName()).font(.caption2.weight(.bold)).foregroundStyle(.secondary)
            }
            .frame(width: size, height: size)
            .foregroundStyle(over ? Color.white : Color.primary)
            .background(over ? Color.red : Theme.surface, in: Circle())
            .overlay(Circle().strokeBorder(over ? Color.red : Color.primary.opacity(0.85), lineWidth: 3))
            if let limit = Speedometer.display(limit) {
                Text(verbatim: limit).font(.headline.weight(.heavy)).monospacedDigit()
                    .frame(width: size * 0.7, height: size * 0.7)
                    .background(Color.white, in: Circle())
                    .overlay(Circle().strokeBorder(Color.red, lineWidth: 4))
                    .foregroundStyle(Color.black)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .shadow(color: Theme.shadow, radius: 10, y: 4)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge) // glyph inside a fixed disc
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .animation(.default, value: over)
        .animation(.default, value: limit)
        .sensoryFeedback(.warning, trigger: over) { _, over in over }
        .onChange(of: over) { _, over in
            if over {
                AudioServicesPlaySystemSound(1057) // short "tink"
            }
        }
    }

    private var label: String {
        guard let speed = Speedometer.display(speed) else { return String(localized: "Speed unavailable") }
        let unit = Speedometer.unitName()
        if let limit = Speedometer.display(limit) {
            return over
                ? String(localized: "\(speed) \(unit), over the \(limit) limit")
                : String(localized: "\(speed) \(unit), limit \(limit)")
        }
        return "\(speed) \(unit)"
    }
}

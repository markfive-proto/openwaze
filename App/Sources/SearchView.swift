import CoreLocation
import SwiftData
import SwiftUI

/// Bottom 'Where to?' sheet: search field, Home/Work shortcuts and recents.
/// Focusing the field expands it to full height for results.
struct SearchView: View {
    let near: () -> CLLocationCoordinate2D?
    /// Shows a search result's card.
    let onPick: (Destination) -> Void
    /// Routes straight to a saved or recent place.
    let onGo: (Destination) -> Void
    let onSave: (Destination, Place.Role) -> Void
    let onRemove: (Place) -> Void
    @Binding var expanded: Bool

    private enum Status { case idle, loading, done, failed }

    /// Collapsed sheet cap, so the map stays visible; taller content scrolls.
    private var collapsedMaxHeight: CGFloat {
        typeSize.isAccessibilitySize ? 200 : 320
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @Query(sort: \Place.usedAt, order: .reverse) private var places: [Place]
    @State private var query = ""
    @State private var results: [Destination] = []
    @State private var status = Status.idle
    /// Set by tapping an unset Home/Work: the next pick is saved as it.
    @State private var settingRole: Place.Role?
    @State private var collapsedHeight: CGFloat = 0
    @FocusState private var focused: Bool

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespaces)
    }

    private func saved(_ role: Place.Role) -> Place? {
        places.first { $0.role == role.rawValue }
    }

    private var recents: [Place] {
        places.filter { $0.role == Place.Role.recent.rawValue }
    }

    var body: some View {
        VStack(spacing: Theme.Space.medium) {
            Capsule()
                .fill(.tertiary)
                .frame(width: 40, height: 5)
                .accessibilityHidden(true)
            HStack(spacing: Theme.Space.small) {
                field
                if expanded {
                    Button("Cancel", action: collapse)
                        .font(.headline)
                        .foregroundStyle(Theme.accent)
                        .frame(minHeight: Theme.tap)
                        .transition(Theme.slide(.trailing, reduceMotion: reduceMotion))
                }
            }
            if expanded {
                ScrollView {
                    VStack(spacing: 0) {
                        if trimmedQuery.isEmpty {
                            shortcuts.padding(.bottom, Theme.Space.medium)
                            recentRows(recents)
                        } else {
                            resultsView
                        }
                    }
                }
                .scrollDismissesKeyboard(.interactively)
            } else {
                ScrollView {
                    collapsedContent
                        .onGeometryChange(for: CGFloat.self, of: \.size.height) { collapsedHeight = $0 }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: min(collapsedHeight, collapsedMaxHeight))
            }
        }
        .padding(.horizontal, Theme.Space.large)
        .padding(.top, Theme.Space.small)
        .padding(.bottom, Theme.Space.small)
        .frame(maxHeight: expanded ? .infinity : nil, alignment: .top)
        .background(
            UnevenRoundedRectangle(topLeadingRadius: Theme.Radius.sheet, topTrailingRadius: Theme.Radius.sheet,
                                   style: .continuous)
                .fill(Theme.surface)
                .shadow(color: Theme.shadow, radius: 20, y: -2)
                .ignoresSafeArea(edges: .bottom)
        )
        .animation(Theme.motion(reduceMotion), value: expanded)
        .onChange(of: focused) {
            if focused {
                expanded = true
            }
        }
        // .task(id:) cancels the previous run on each keystroke, which both
        // debounces (the sleep throws) and cancels the in-flight request.
        .task(id: query) { await search() }
    }

    private var field: some View {
        HStack(spacing: Theme.Space.medium) {
            Image(systemName: "magnifyingglass")
                .font(.title3.weight(.bold))
                .foregroundStyle(Theme.accent)
                .accessibilityHidden(true)
            TextField(prompt, text: $query)
                .font(.title3.weight(.semibold))
                .accessibilityLabel(Text("Search destination"))
                .focused($focused)
                .submitLabel(.search)
                .onSubmit { results.first.map(select) }
                .autocorrectionDisabled()
            if !query.isEmpty {
                Button(String(localized: "Clear search"), systemImage: "xmark.circle.fill") { query = "" }
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 44, minHeight: 44)
            }
        }
        .padding(.horizontal, Theme.Space.large)
        .frame(minHeight: Theme.tap)
        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
    }

    private var prompt: String {
        switch settingRole {
        case .home: String(localized: "Search for your home address")
        case .work: String(localized: "Search for your work address")
        default: String(localized: "Where to?")
        }
    }

    private var collapsedContent: some View {
        VStack(spacing: Theme.Space.medium) {
            shortcuts
            recentRows(Array(recents.prefix(2)))
        }
    }

    private var shortcuts: some View {
        // Side by side, or stacked at accessibility text sizes.
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: Theme.Space.medium))
            : AnyLayout(HStackLayout(spacing: Theme.Space.medium))
        return layout {
            shortcut(.home, title: String(localized: "Home"), icon: "house.fill")
            shortcut(.work, title: String(localized: "Work"), icon: "briefcase.fill")
        }
    }

    private func shortcut(_ role: Place.Role, title: String, icon: String) -> some View {
        let place = saved(role)
        return Button {
            if let place {
                collapse()
                onGo(place.destination)
            } else {
                settingRole = role
                focused = true
            }
        } label: {
            HStack(spacing: Theme.Space.medium) {
                IconDisc(icon: icon, foreground: .white, background: Theme.accentFill)
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(.headline).foregroundStyle(.primary)
                    Text(place?.name ?? String(localized: "Set location"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
                }
                Spacer(minLength: 0)
            }
            .padding(Theme.Space.small)
            .frame(minHeight: Theme.tap + 8)
            .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityHint(place == nil ? Text("Search for an address to save") : Text("Starts a route"))
    }

    private func recentRows(_ recents: [Place]) -> some View {
        ForEach(recents) { place in
            PlaceRow(icon: "clock.arrow.circlepath", title: place.name, subtitle: place.address) {
                collapse()
                onGo(place.destination)
            }
            .contextMenu {
                Button(String(localized: "Remove"), systemImage: "trash", role: .destructive) { onRemove(place) }
            }
            .accessibilityAction(named: Text("Remove")) { onRemove(place) }
        }
    }

    @ViewBuilder private var resultsView: some View {
        switch status {
        case .done where !results.isEmpty:
            ForEach(results) { result in
                PlaceRow(icon: "mappin.and.ellipse", title: result.name, subtitle: result.address) { select(result) }
                    .contextMenu {
                        Button(String(localized: "Set as Home"), systemImage: "house") { onSave(result, .home) }
                        Button(String(localized: "Set as Work"), systemImage: "briefcase") { onSave(result, .work) }
                    }
                    .accessibilityAction(named: Text("Set as Home")) { onSave(result, .home) }
                    .accessibilityAction(named: Text("Set as Work")) { onSave(result, .work) }
            }
        case .loading, .idle:
            message { ProgressView(); Text("Searching…") }
        case .failed:
            message {
                Image(systemName: "wifi.exclamationmark").accessibilityHidden(true)
                Text("Search unavailable, check connection")
            }
        default:
            message { Image(systemName: "mappin.slash").accessibilityHidden(true); Text("No results") }
        }
    }

    private func message(@ViewBuilder _ content: () -> some View) -> some View {
        HStack(spacing: Theme.Space.medium) { content() }
            .font(.headline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: Theme.tap * 2)
    }

    private func select(_ result: Destination) {
        if let settingRole {
            onSave(result, settingRole)
        }
        collapse()
        onPick(result)
    }

    private func collapse() {
        focused = false
        query = ""
        settingRole = nil
        expanded = false
    }

    private func search() async {
        results = [] // stale for the new query
        let trimmed = trimmedQuery
        guard !trimmed.isEmpty else {
            status = .idle
            return
        }
        status = .loading
        do {
            try await Task.sleep(for: .milliseconds(300))
            let found = try await Photon.search(trimmed, near: near())
            guard !Task.isCancelled else { return }
            results = found
            status = .done
        } catch {
            if !Task.isCancelled {
                status = .failed
            }
        }
    }
}

/// One tappable list row: tinted icon disc, title, subtitle.
struct PlaceRow: View {
    let icon: String
    let title: String
    let subtitle: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.medium) {
                IconDisc(icon: icon, foreground: Theme.accent, background: Theme.surfaceRaised)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline).foregroundStyle(.primary).lineLimit(2)
                    if !subtitle.isEmpty {
                        Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, Theme.Space.small)
            .frame(minHeight: Theme.tap)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Decorative icon in a filled circle that grows with Dynamic Type.
struct IconDisc: View {
    let icon: String
    let foreground: Color
    let background: Color
    @Scaled private var size: CGFloat = 40

    var body: some View {
        Image(systemName: icon)
            .font(.headline)
            .foregroundStyle(foreground)
            .frame(width: size, height: size)
            .background(background, in: Circle())
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge) // glyph stays inside the capped disc
            .accessibilityHidden(true)
    }
}

import SwiftUI

/// A picked search result: name, address, save as Home/Work, Go.
struct DestinationCard: View {
    let destination: Destination
    /// Fetches and previews a route. Nil shows Go disabled.
    let onGo: ((Destination) -> Void)?
    let onSave: (Place.Role) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.large) {
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: Theme.Space.tiny) {
                    Text(destination.name).font(.title2.weight(.bold)).lineLimit(2)
                    Text(destination.address).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: Theme.Space.small)
                Menu {
                    Button(String(localized: "Set as Home"), systemImage: "house") { onSave(.home) }
                    Button(String(localized: "Set as Work"), systemImage: "briefcase") { onSave(.work) }
                } label: {
                    Image(systemName: "star")
                        .font(.body.weight(.bold))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 36, height: 36)
                        .background(Theme.surfaceRaised, in: Circle())
                        .frame(width: Theme.tap, height: Theme.tap)
                }
                .accessibilityLabel(Text("Save place"))
                CloseButton(action: onClose)
            }
            Button { onGo?(destination) } label: {
                Label("Go", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(onGo == nil)
        }
        .padding(.leading, Theme.Space.huge)
        .padding([.trailing, .top], Theme.Space.small)
        .padding(.bottom, Theme.Space.huge)
        .card()
        .padding(.horizontal, Theme.Space.medium)
    }
}

/// Bottom card for the trip phases before and after driving: routing,
/// preview, arrived, failed.
struct TripCard: View {
    let navigator: Navigator
    /// Route uses toll roads; nil hides the badge until the router reports it (#30).
    var tolls: Bool?
    let onRetry: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.large) {
            switch navigator.phase {
            case .preview:
                preview
            case .arrived:
                header(icon: "flag.checkered", title: Text("You have arrived"))
                Button("Done", action: onClose).buttonStyle(PrimaryButtonStyle())
            case let .failed(message):
                header(icon: "exclamationmark.triangle.fill", title: Text(message), tint: Theme.danger)
                Button(action: onRetry) { Label("Try again", systemImage: "arrow.clockwise") }
                    .buttonStyle(PrimaryButtonStyle())
            default: // routing; navigating has its own bar
                HStack(spacing: Theme.Space.medium) {
                    ProgressView().controlSize(.large)
                    Text("Finding route…").font(.headline).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    CloseButton(action: onClose)
                }
                .frame(minHeight: Theme.tap * 2)
            }
        }
        .padding(.leading, Theme.Space.huge)
        .padding([.trailing, .top], Theme.Space.small)
        .padding(.bottom, Theme.Space.huge)
        .card()
        .padding(.horizontal, Theme.Space.medium)
    }

    @ViewBuilder private var preview: some View {
        if let progress = navigator.progress {
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: Theme.Space.tiny) {
                    Text(Format.duration(progress.remainingDuration))
                        .font(.largeTitle.weight(.heavy))
                        .foregroundStyle(Theme.accent)
                    Text("\(Format.distance(progress.remainingDistance)) · \(arrival(progress))")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    if let name = navigator.destination?.name {
                        Text("To \(name)").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .padding(.top, Theme.Space.medium)
                .accessibilityElement(children: .combine)
                Spacer(minLength: Theme.Space.small)
                if tolls == true {
                    TollBadge().padding(.top, Theme.Space.large)
                }
                CloseButton(action: onClose)
            }
            Button { navigator.start() } label: {
                Label("Start", systemImage: "location.north.fill")
            }
            .buttonStyle(PrimaryButtonStyle())
        }
    }

    private func header(icon: String, title: Text, tint: Color = Theme.accentFill) -> some View {
        HStack(spacing: Theme.Space.large) {
            Image(systemName: icon)
                .font(.title2.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: Theme.tap, height: Theme.tap)
                .background(tint, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                title.font(.title3.weight(.bold))
                if let name = navigator.destination?.name {
                    Text(name).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.top, Theme.Space.large)
        .accessibilityElement(children: .combine)
    }
}

/// "Arrive 08:45" style clock time for the remaining duration.
private func arrival(_ progress: RouteProgress) -> String {
    Date.now.addingTimeInterval(progress.remainingDuration).formatted(date: .omitted, time: .shortened)
}

struct TollBadge: View {
    var body: some View {
        Label("Toll", systemImage: "dollarsign.circle.fill")
            .font(.subheadline.weight(.bold))
            .foregroundStyle(Color(hex: 0x8A5A00))
            .padding(.horizontal, Theme.Space.medium)
            .padding(.vertical, Theme.Space.tiny + 2)
            .background(Color(hex: 0xFFE4A8), in: Capsule())
    }
}

/// Bottom bar while driving: arrival time, time and distance left, End.
struct NavigationBar: View {
    let progress: RouteProgress
    let onEnd: () -> Void

    private var remaining: String {
        "\(Format.duration(progress.remainingDuration)) · \(Format.distance(progress.remainingDistance))"
    }

    var body: some View {
        HStack(spacing: Theme.Space.large) {
            VStack(alignment: .leading, spacing: 0) {
                Text(arrival(progress))
                    .font(.title.weight(.heavy))
                    .monospacedDigit()
                Text(remaining)
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Arrive at \(arrival(progress)), \(remaining) left"))
            Spacer(minLength: 0)
            Button(role: .destructive, action: onEnd) { Text("End") }
                .buttonStyle(PrimaryButtonStyle(fill: Theme.danger))
                .fixedSize()
        }
        .padding(.horizontal, Theme.Space.huge)
        .padding(.vertical, Theme.Space.large)
        .card()
        .padding(.horizontal, Theme.Space.medium)
    }
}

/// Next-maneuver banner shown at the top while navigating.
struct ManeuverBanner: View {
    let step: Route.Step
    let distance: Double

    var body: some View {
        HStack(spacing: Theme.Space.large) {
            Image(systemName: Instruction.icon(for: step))
                .font(.system(size: 52, weight: .heavy))
                .frame(width: 72, height: 72)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(Format.distance(distance))
                    .font(.largeTitle.weight(.heavy))
                    .monospacedDigit()
                Text(Instruction.text(for: step))
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(Theme.Space.large)
        .background(Theme.accentFill, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .shadow(color: Theme.shadow, radius: 16, y: 6)
        .padding(.horizontal, Theme.Space.medium)
        .accessibilityElement(children: .combine)
    }
}

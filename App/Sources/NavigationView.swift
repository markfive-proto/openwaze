import SwiftUI

/// Bottom card for each trip phase after Go: routing, preview, guiding, arrived.
struct TripCard: View {
    let navigator: Navigator
    let onClose: () -> Void

    var body: some View {
        HStack {
            switch navigator.phase {
            case .routing:
                ProgressView()
                Text("Finding route…").foregroundStyle(.secondary)
                Spacer()
                closeButton
            case .preview, .navigating:
                if let progress = navigator.progress {
                    summary(progress)
                }
                Spacer()
                if navigator.phase == .preview {
                    Button("Start") { navigator.start() }
                        .buttonStyle(.borderedProminent)
                    closeButton
                } else {
                    Button("End", role: .destructive, action: onClose)
                        .buttonStyle(.borderedProminent)
                }
            case .arrived:
                Label("You have arrived", systemImage: "flag.checkered").font(.headline)
                Spacer()
                Button("Done", action: onClose).buttonStyle(.borderedProminent)
            case let .failed(message):
                Text(message).foregroundStyle(.secondary)
                Spacer()
                closeButton
            case .idle:
                EmptyView()
            }
        }
        .frame(minHeight: 44)
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding()
    }

    private var closeButton: some View {
        Button("Close", systemImage: "xmark", action: onClose)
            .labelStyle(.iconOnly)
            .buttonStyle(.bordered)
    }

    /// "12 min" over "4.3 km · 08:45".
    private func summary(_ progress: RouteProgress) -> some View {
        VStack(alignment: .leading) {
            Text(Format.duration(progress.remainingDuration)).font(.title2.bold())
            Text("\(Format.distance(progress.remainingDistance)) · \(arrivalTime(progress))")
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func arrivalTime(_ progress: RouteProgress) -> String {
        Date.now.addingTimeInterval(progress.remainingDuration).formatted(date: .omitted, time: .shortened)
    }
}

/// Next-maneuver banner shown at the top while navigating.
struct ManeuverBanner: View {
    let step: Route.Step
    let distance: Double

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: Instruction.icon(for: step))
                .font(.system(size: 40, weight: .bold))
                .frame(width: 56)
            VStack(alignment: .leading) {
                Text(Format.distance(distance)).font(.title.bold())
                Text(Instruction.text(for: step)).font(.headline).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding()
        .background(Color.green.gradient, in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal)
        .accessibilityElement(children: .combine)
    }
}

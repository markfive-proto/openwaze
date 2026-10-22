import CoreLocation
import SwiftUI

/// Search bar with a results list. Picking a result sets `destination`.
struct SearchView: View {
    @Binding var destination: Destination?
    let near: () -> CLLocationCoordinate2D?

    @State private var query = ""
    @State private var results: [Destination] = []
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            TextField("Where to?", text: $query)
                .focused($focused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .padding(12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))

            if focused, !results.isEmpty {
                List(results) { result in
                    Button {
                        destination = result
                        query = result.name
                        focused = false
                    } label: {
                        VStack(alignment: .leading) {
                            Text(result.name).foregroundStyle(.primary)
                            Text(result.address).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .listStyle(.plain)
                .frame(maxHeight: 320)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.top, 4)
            }
        }
        .padding(.horizontal)
        // .task(id:) cancels the previous run on each keystroke, which both
        // debounces (the sleep throws) and cancels the in-flight request.
        .task(id: query) {
            let trimmed = query.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else {
                results = []
                return
            }
            do {
                try await Task.sleep(for: .milliseconds(300))
                results = try await Photon.search(trimmed, near: near())
            } catch {
                // Cancelled or offline: keep showing the last results.
            }
        }
    }
}

struct DestinationCard: View {
    let destination: Destination
    let onGo: (Destination) -> Void
    let onClose: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(destination.name).font(.headline)
                Text(destination.address).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Go") { onGo(destination) }
                .buttonStyle(.borderedProminent)
            Button("Close", systemImage: "xmark", action: onClose)
                .labelStyle(.iconOnly)
                .buttonStyle(.bordered)
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding()
    }
}

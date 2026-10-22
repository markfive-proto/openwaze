import CoreLocation
import SwiftUI

/// Search bar with a results list. Picking a result sets `destination`.
struct SearchView: View {
    @Binding var destination: Destination?
    let near: () -> CLLocationCoordinate2D?

    private enum Status { case idle, loading, done, failed }

    @State private var query = ""
    @State private var results: [Destination] = []
    @State private var status = Status.idle
    @State private var skipNextSearch = false
    @FocusState private var focused: Bool

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespaces)
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Where to?", text: $query)
                .accessibilityLabel("Search destination")
                .focused($focused)
                .submitLabel(.search)
                .onSubmit { results.first.map(select) }
                .autocorrectionDisabled()
                .padding(12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .toolbar {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("Done") { focused = false }
                    }
                }

            if !trimmedQuery.isEmpty, status != .idle {
                resultsView
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.top, 4)
            }
        }
        .padding(.horizontal)
        // .task(id:) cancels the previous run on each keystroke, which both
        // debounces (the sleep throws) and cancels the in-flight request.
        .task(id: query) { await search() }
    }

    @ViewBuilder private var resultsView: some View {
        switch status {
        case .done where !results.isEmpty:
            List(results) { result in
                Button { select(result) } label: {
                    VStack(alignment: .leading) {
                        Text(result.name).foregroundStyle(.primary)
                        Text(result.address).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.plain)
            .frame(maxHeight: 320)
        case .loading:
            row { ProgressView(); Text("Searching…") }
        case .failed:
            row { Text("Search unavailable, check connection") }
        default:
            row { Text("No results") }
        }
    }

    private func row(@ViewBuilder _ content: () -> some View) -> some View {
        HStack { content() }
            .foregroundStyle(.secondary)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial)
    }

    private func select(_ result: Destination) {
        destination = result
        if query != result.name {
            skipNextSearch = true // setting the query below must not search again
            query = result.name
        }
        status = .idle
        focused = false
    }

    private func search() async {
        if skipNextSearch {
            skipNextSearch = false
            return
        }
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

struct DestinationCard: View {
    static let height: CGFloat = 110 // approx, used to keep map attribution visible

    let destination: Destination
    /// Starts navigation. Nil until routing (#10) lands; Go shows disabled.
    let onGo: ((Destination) -> Void)?
    let onClose: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(destination.name).font(.headline)
                Text(destination.address).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Go") { onGo?(destination) }
                .buttonStyle(.borderedProminent)
                .disabled(onGo == nil)
            Button("Close", systemImage: "xmark", action: onClose)
                .labelStyle(.iconOnly)
                .buttonStyle(.bordered)
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding()
    }
}

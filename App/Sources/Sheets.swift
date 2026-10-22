import SwiftUI

/// Grid of report categories; `onPick` posts it (HomeView).
struct ReportSheet: View {
    let onPick: (ReportType) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    /// Measured content height, so the sheet fits the grid with no empty space.
    @State private var height: CGFloat = 400
    @Scaled private var disc: CGFloat = 64

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.large) {
                HStack {
                    Text("Report").font(.title.weight(.heavy)).accessibilityAddTraits(.isHeader)
                    Spacer()
                    CloseButton { dismiss() }
                }
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: Theme.Space.medium),
                                   count: typeSize.isAccessibilitySize ? 2 : 3),
                    spacing: Theme.Space.medium
                ) {
                    ForEach(ReportType.allCases) { category in
                        Button {
                            onPick(category)
                            dismiss()
                        } label: {
                            tile(category)
                        }
                        .buttonStyle(TileButtonStyle())
                        .accessibilityLabel(Text("Report \(category.title)"))
                    }
                }
            }
            .padding(.horizontal, Theme.Space.huge)
            .padding(.top, Theme.Space.huge)
            .padding(.bottom, Theme.Space.small)
            .onGeometryChange(for: CGFloat.self, of: \.size.height) { height = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .presentationDetents([.height(height)])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(Theme.Radius.sheet)
        .presentationBackground(Theme.surface)
    }

    private func tile(_ category: ReportType) -> some View {
        VStack(spacing: Theme.Space.medium) {
            Image(systemName: category.symbol)
                .font(.system(size: disc * 0.44, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: disc, height: disc)
                .background(category.color, in: Circle())
                .accessibilityHidden(true)
            Text(category.title)
                .font(.headline)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        }
        .padding(.vertical, Theme.Space.large)
        .padding(.horizontal, Theme.Space.tiny)
        .frame(maxWidth: .infinity, minHeight: 128)
        .background(category.color.opacity(0.14),
                    in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
    }
}

private struct TileButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
            .opacity(configuration.isPressed && reduceMotion ? 0.8 : 1)
            .animation(Theme.motion(reduceMotion), value: configuration.isPressed)
    }
}

/// Settings stub; real options (voice, units, avoid tolls, dark map) are #22.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    soon("Voice guidance", icon: "speaker.wave.2.fill")
                    soon("Units", icon: "ruler.fill")
                    soon("Avoid tolls", icon: "dollarsign.circle.fill")
                    soon("Dark map", icon: "moon.fill")
                } header: {
                    Text("Driving")
                }
                Section {
                    LabeledContent(String(localized: "Version"), value: version)
                    if let url = URL(string: "https://www.openstreetmap.org/copyright") {
                        Link(destination: url) {
                            Label("Map data © OpenStreetMap contributors", systemImage: "map.fill")
                        }
                    }
                    if let url = URL(string: "https://github.com/markfive-proto/openwaze") {
                        Link(destination: url) {
                            Label("Source code", systemImage: "chevron.left.forwardslash.chevron.right")
                        }
                    }
                } header: {
                    Text("About")
                }
            }
            .navigationTitle(Text("Settings"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.fontWeight(.bold)
                }
            }
        }
        .tint(Theme.accent)
    }

    private func soon(_ title: LocalizedStringKey, icon: String) -> some View {
        LabeledContent {
            Text("Coming soon")
        } label: {
            Label(title, systemImage: icon)
        }
    }
}

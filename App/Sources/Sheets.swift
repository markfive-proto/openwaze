import SwiftUI

/// Raw values match the reports API `type` field.
enum ReportType: String, CaseIterable, Identifiable {
    case police, accident, hazard, traffic, closure, flood

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .police: String(localized: "Police")
        case .accident: String(localized: "Accident")
        case .hazard: String(localized: "Hazard")
        case .traffic: String(localized: "Traffic")
        case .closure: String(localized: "Closure")
        case .flood: String(localized: "Flood")
        }
    }

    var icon: String {
        switch self {
        case .police: "shield.lefthalf.filled"
        case .accident: "car.side.rear.and.collision.and.car.side.front"
        case .hazard: "exclamationmark.triangle.fill"
        case .traffic: "car.2.fill"
        case .closure: "xmark.octagon.fill"
        case .flood: "water.waves"
        }
    }

    /// Each dark enough for a white icon (>= 3:1).
    var color: Color {
        switch self {
        case .police: Color(hex: 0x2563EB)
        case .accident: Color(hex: 0xDC2626)
        case .hazard: Color(hex: 0xC26A00)
        case .traffic: Color(hex: 0xEA580C)
        case .closure: Color(hex: 0x475569)
        case .flood: Color(hex: 0x0E7490)
        }
    }
}

/// Grid of report categories. Posting to the reports API is #11.
struct ReportSheet: View {
    let onPick: (ReportType) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.large) {
            HStack {
                Text("Report").font(.title.weight(.heavy)).accessibilityAddTraits(.isHeader)
                Spacer()
                CloseButton { dismiss() }
            }
            ScrollView {
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
            .scrollBounceBehavior(.basedOnSize)
        }
        .padding(.horizontal, Theme.Space.huge)
        .padding(.top, Theme.Space.large)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(Theme.Radius.sheet)
        .presentationBackground(Theme.surface)
    }

    private func tile(_ category: ReportType) -> some View {
        VStack(spacing: Theme.Space.medium) {
            Image(systemName: category.icon)
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 64, height: 64)
                .background(category.color, in: Circle())
            Text(category.title)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, minHeight: 128)
        .background(category.color.opacity(0.14),
                    in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
    }
}

private struct TileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(Theme.spring, value: configuration.isPressed)
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
                    Link(destination: URL(string: "https://www.openstreetmap.org/copyright")!) {
                        Label("Map data © OpenStreetMap contributors", systemImage: "map.fill")
                    }
                    Link(destination: URL(string: "https://github.com/markfive-proto/openwaze")!) {
                        Label("Source code", systemImage: "chevron.left.forwardslash.chevron.right")
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

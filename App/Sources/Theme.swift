import SwiftUI

/// Design tokens. One accent (violet) drives every primary action; report
/// categories get their own hues. Text uses system styles (Dynamic Type) in
/// the rounded design, set once at the root.
enum Theme {
    // MARK: Colour

    /// Tint for text and icons on surfaces; lighter in dark mode to keep contrast.
    static let accent = Color(light: 0x4F3BF0, dark: 0x9C8FFF)
    /// Fill behind white text (buttons, maneuver banner): same in both modes, 6.6:1 with white.
    static let accentFill = Color(hex: 0x4F3BF0)
    static let danger = Color(hex: 0xD92D3A)
    static let surface = Color(light: 0xFFFFFF, dark: 0x1B1A22)
    static let surfaceRaised = Color(light: 0xF1F0F6, dark: 0x2B2935)
    static let shadow = Color.black.opacity(0.18)
    /// Fill behind white text for a secondary choice (slate, 7.6:1 with white).
    static let neutralFill = Color(hex: 0x475569)
    /// Report categories by `ReportType.colorToken`; each dark enough for a white icon (>= 3:1).
    static let reportColors: [String: Color] = [
        "reportPolice": Color(hex: 0x2563EB),
        "reportAccident": Color(hex: 0xDC2626),
        "reportHazard": Color(hex: 0xC26A00),
        "reportTraffic": Color(hex: 0xEA580C),
        "reportClosure": Color(hex: 0x475569),
        "reportFlood": Color(hex: 0x0E7490),
    ]

    // MARK: Size

    /// Minimum height and width of a driving control.
    static let tap: CGFloat = 56
    static let fab: CGFloat = 64

    enum Space {
        static let tiny: CGFloat = 4
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let large: CGFloat = 16
        static let huge: CGFloat = 24
    }

    enum Radius {
        static let sheet: CGFloat = 32
        static let card: CGFloat = 28
        static let tile: CGFloat = 24
        static let field: CGFloat = 20
    }

    // MARK: Motion

    static let spring = Animation.spring(duration: 0.4, bounce: 0.25)

    /// The spring, or no animation with Reduce Motion on.
    static func motion(_ reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : spring
    }

    /// Slide in from `edge`, or just fade with Reduce Motion on.
    static func slide(_ edge: Edge, reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .move(edge: edge).combined(with: .opacity)
    }
}

/// A size that grows with Dynamic Type, capped so map controls never swallow the map.
@propertyWrapper
struct Scaled: DynamicProperty {
    @ScaledMetric private var value: CGFloat
    private let cap: CGFloat

    init(wrappedValue base: CGFloat, max factor: CGFloat = 1.25) {
        _value = ScaledMetric(wrappedValue: base, relativeTo: .body)
        cap = base * factor
    }

    var wrappedValue: CGFloat {
        min(value, cap)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(uiColor: UIColor(hex: hex))
    }

    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// Floating card: solid surface, continuous corners, soft drop shadow.
struct CardBackground: ViewModifier {
    var radius = Theme.Radius.card

    func body(content: Content) -> some View {
        content
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .shadow(color: Theme.shadow, radius: 16, y: 6)
    }
}

extension View {
    func card(radius: CGFloat = Theme.Radius.card) -> some View {
        modifier(CardBackground(radius: radius))
    }
}

/// Full-width capsule for the one main action on a card (Go, Start, End).
struct PrimaryButtonStyle: ButtonStyle {
    var fill = Theme.accentFill
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.title3.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, Theme.Space.huge)
            .frame(minHeight: Theme.tap)
            .frame(maxWidth: .infinity)
            .background(fill.opacity(isEnabled ? 1 : 0.4), in: Capsule())
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .opacity(configuration.isPressed && reduceMotion ? 0.8 : 1)
            .animation(Theme.motion(reduceMotion), value: configuration.isPressed)
    }
}

/// Circular map control: surface or accent filled, 56 pt or larger.
struct RoundButtonStyle: ButtonStyle {
    var size = Theme.tap
    var filled = false

    func makeBody(configuration: Configuration) -> some View {
        RoundButton(configuration: configuration, filled: filled, size: size)
    }
}

private struct RoundButton: View {
    let configuration: ButtonStyleConfiguration
    let filled: Bool
    @Scaled var size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(configuration: ButtonStyleConfiguration, filled: Bool, size: CGFloat) {
        self.configuration = configuration
        self.filled = filled
        _size = Scaled(wrappedValue: size)
    }

    var body: some View {
        configuration.label
            .labelStyle(.iconOnly)
            .font(.system(size: size * 0.4, weight: .bold))
            .foregroundStyle(filled ? Color.white : Color.primary)
            .frame(width: size, height: size)
            .background(filled ? Theme.accentFill : Theme.surface, in: Circle())
            .shadow(color: Theme.shadow, radius: 10, y: 4)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.9 : 1)
            .opacity(configuration.isPressed && reduceMotion ? 0.8 : 1)
            .animation(Theme.motion(reduceMotion), value: configuration.isPressed)
            .contentShape(Circle())
    }
}

/// Small round close (x) button, still a 56 pt target.
struct CloseButton: View {
    let action: () -> Void
    @Scaled private var disc: CGFloat = 36
    @Scaled private var target: CGFloat = Theme.tap

    var body: some View {
        Button(String(localized: "Close"), systemImage: "xmark", action: action)
            .labelStyle(.iconOnly)
            .font(.body.weight(.bold))
            .foregroundStyle(.secondary)
            .frame(width: disc, height: disc)
            .background(Theme.surfaceRaised, in: Circle())
            .frame(width: target, height: target)
            .contentShape(Rectangle())
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge) // glyph stays inside the capped disc
    }
}

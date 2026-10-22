import Foundation

/// Metric display text (Malaysia drives in km): "40 m", "300 m", "1.2 km", "12 km".
enum Format {
    static func distance(_ metres: Double, locale: Locale = .current) -> String {
        let metres = max(0, metres)
        // Coarser steps further out, like road signs.
        let step: Double = metres < 100 ? 10 : 50
        let rounded = (metres / step).rounded() * step
        if rounded < 1000 {
            return measurement(rounded, .meters, digits: 0, locale: locale)
        }
        let kilometres = metres / 1000
        return measurement(kilometres, .kilometers, digits: kilometres < 9.95 ? 1 : 0, locale: locale)
    }

    /// "8 min", "1 hr, 5 min". Under a minute rounds up to "1 min".
    static func duration(_ seconds: Double, locale: Locale = .current) -> String {
        let minutes = max(1, (seconds / 60).rounded())
        let style = Duration.UnitsFormatStyle(allowedUnits: [.hours, .minutes], width: .abbreviated)
        return Duration.seconds(minutes * 60).formatted(style.locale(locale))
    }

    private static func measurement(_ value: Double, _ unit: UnitLength, digits: Int, locale: Locale) -> String {
        let number = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(digits))
        let style = Measurement<UnitLength>.FormatStyle(
            width: .abbreviated, usage: .asProvided, numberFormatStyle: number
        )
        return Measurement(value: value, unit: unit).formatted(style.locale(locale))
    }
}

import Foundation

/// Human-readable maneuvers from OSRM steps. Phrases are composed from
/// small localised pieces ("Turn %@", "%1$@ onto %2$@") so a translation
/// can reorder them; see Localizable.xcstrings.
enum Instruction {
    static func text(for step: Route.Step, locale: Locale = .current) -> String {
        switch step.type {
        case "depart":
            return step.name.isEmpty
                ? String(localized: "Start driving")
                : String(localized: "Start on \(step.name)")
        case "arrive":
            switch side(step.modifier) {
            case "left": return String(localized: "Your destination is on the left")
            case "right": return String(localized: "Your destination is on the right")
            default: return String(localized: "You have arrived")
            }
        default:
            let action = action(for: step, locale: locale)
            if !step.name.isEmpty {
                return String(localized: "\(action) onto \(step.name)", comment: "e.g. Turn left onto Jalan Ampang")
            }
            if let towards = step.destinations {
                return String(localized: "\(action) towards \(towards)", comment: "e.g. Take the exit towards KLIA")
            }
            return action
        }
    }

    /// What to say `distance` metres before the maneuver.
    static func spoken(for step: Route.Step, distance: Double, threshold: Double) -> String {
        let text = text(for: step)
        // The nearest prompt is said just before the maneuver: no distance.
        guard threshold > Guidance.announceAt.min() ?? 0, step.type != "arrive" else { return text }
        let lowered = text.prefix(1).lowercased() + text.dropFirst() // "Turn left" -> "turn left"
        return String(localized: "In \(Format.distance(distance)), \(lowered)", comment: "e.g. In 500 m, turn left")
    }

    // swiftlint:disable:next cyclomatic_complexity - one flat case per OSRM maneuver type
    static func action(for step: Route.Step, locale: Locale) -> String {
        if step.modifier == "uturn" {
            return String(localized: "Make a U-turn")
        }
        switch step.type {
        case "roundabout", "rotary":
            guard let exit = step.exit, exit > 0 else { return String(localized: "Enter the roundabout") }
            return String(localized: "At the roundabout, take the \(ordinal(exit, locale: locale)) exit")
        case "exit roundabout", "exit rotary":
            return String(localized: "Exit the roundabout")
        case "on ramp":
            return String(localized: "Take the ramp")
        case "off ramp":
            return String(localized: "Take the exit")
        case "merge":
            return String(localized: "Merge")
        case "fork":
            guard let side = side(step.modifier) else { return String(localized: "Keep straight") }
            return String(localized: "Keep \(direction(side))", comment: "Keep left / Keep right")
        case "new name", "continue":
            guard let side = side(step.modifier) else { return String(localized: "Continue") }
            return String(localized: "Keep \(direction(side))", comment: "Keep left / Keep right")
        default: // turn, end of road, roundabout turn, notification
            guard let modifier = step.modifier, modifier != "straight" else {
                return String(localized: "Continue straight")
            }
            return String(localized: "Turn \(direction(modifier))", comment: "Turn left / Turn slight right")
        }
    }

    /// "left" or "right" from any OSRM modifier, nil for straight or none.
    static func side(_ modifier: String?) -> String? {
        guard let modifier else { return nil }
        if modifier.hasSuffix("left") {
            return "left"
        }
        if modifier.hasSuffix("right") {
            return "right"
        }
        return nil
    }

    static func direction(_ modifier: String) -> String {
        switch modifier {
        case "left": String(localized: "left")
        case "right": String(localized: "right")
        case "slight left": String(localized: "slight left")
        case "slight right": String(localized: "slight right")
        case "sharp left": String(localized: "sharp left")
        case "sharp right": String(localized: "sharp right")
        default: modifier
        }
    }

    static func ordinal(_ number: Int, locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .ordinal
        formatter.locale = locale
        return formatter.string(from: number as NSNumber) ?? String(number)
    }

    /// SF Symbol for the maneuver banner.
    static func icon(for step: Route.Step) -> String {
        switch step.type {
        case "arrive": return "flag.checkered"
        case "roundabout", "rotary", "exit roundabout", "exit rotary": return "arrow.clockwise.circle"
        case "merge": return "arrow.merge"
        default: break
        }
        switch step.modifier {
        case "uturn": return "arrow.uturn.down"
        case "left", "sharp left": return "arrow.turn.up.left"
        case "right", "sharp right": return "arrow.turn.up.right"
        case "slight left": return "arrow.up.left"
        case "slight right": return "arrow.up.right"
        default: return "arrow.up"
        }
    }
}

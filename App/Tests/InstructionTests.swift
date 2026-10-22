@testable import OpenWaze
import XCTest

final class InstructionTests: XCTestCase {
    let english = Locale(identifier: "en_MY")

    func text(_ type: String, _ mod: String? = nil, name: String = "", exit: Int? = nil, via: String? = nil) -> String {
        var step = Route.Step(type: type, modifier: mod, latitude: 0, longitude: 0)
        (step.exit, step.name, step.destinations) = (exit, name, via)
        return Instruction.text(for: step, locale: english)
    }

    func testTurnsAndRoadNames() {
        XCTAssertEqual(text("turn", "left", name: "Jalan Ampang"), "Turn left onto Jalan Ampang")
        XCTAssertEqual(text("turn", "slight right"), "Turn slight right")
        XCTAssertEqual(text("turn", "straight", name: "Jalan Tun Razak"), "Continue straight onto Jalan Tun Razak")
        XCTAssertEqual(text("end of road", "sharp left"), "Turn sharp left")
        XCTAssertEqual(text("turn", "uturn", name: "Jalan Penchala"), "Make a U-turn onto Jalan Penchala")
        XCTAssertEqual(text("new name", "straight", name: "Jalan Sungai Besi"), "Continue onto Jalan Sungai Besi")
        XCTAssertEqual(text("continue", "slight left"), "Keep left")
        XCTAssertEqual(text("notification"), "Continue straight")
    }

    func testHighwayManeuversUseSignpostsWhenUnnamed() {
        XCTAssertEqual(text("on ramp", "straight", via: "E12"), "Take the ramp towards E12")
        XCTAssertEqual(text("off ramp", "slight left", via: "KLIA"), "Take the exit towards KLIA")
        XCTAssertEqual(text("merge", "slight right", name: "Lebuhraya Maju"), "Merge onto Lebuhraya Maju")
        XCTAssertEqual(text("fork", "slight right"), "Keep right")
        XCTAssertEqual(text("fork", "straight"), "Keep straight")
    }

    func testRoundaboutExits() {
        XCTAssertEqual(text("roundabout", "slight left", name: "Jalan KLIA 1", exit: 2),
                       "At the roundabout, take the 2nd exit onto Jalan KLIA 1")
        XCTAssertEqual(text("rotary", exit: 3), "At the roundabout, take the 3rd exit")
        XCTAssertEqual(text("roundabout"), "Enter the roundabout")
        XCTAssertEqual(text("exit roundabout", "straight", name: "Jalan KLIA 1"),
                       "Exit the roundabout onto Jalan KLIA 1")
        XCTAssertEqual(text("roundabout turn", "right", name: "Lorong Utara C"), "Turn right onto Lorong Utara C")
    }

    func testDepartAndArrive() {
        XCTAssertEqual(text("depart", name: "Jalan Ampang"), "Start on Jalan Ampang")
        XCTAssertEqual(text("depart"), "Start driving")
        XCTAssertEqual(text("arrive", "right"), "Your destination is on the right")
        XCTAssertEqual(text("arrive", "slight left"), "Your destination is on the left")
        XCTAssertEqual(text("arrive", "straight"), "You have arrived")
    }

    func testSpokenPrompts() {
        let turn = Route.Step(type: "turn", modifier: "left", name: "Jalan Ampang", latitude: 0, longitude: 0)
        XCTAssertEqual(Instruction.spoken(for: turn, distance: 480, threshold: 500),
                       "In 500 m, turn left onto Jalan Ampang")
        XCTAssertEqual(Instruction.spoken(for: turn, distance: 2300, threshold: .infinity),
                       "In 2.3 km, turn left onto Jalan Ampang")
        XCTAssertEqual(Instruction.spoken(for: turn, distance: 40, threshold: 50), "Turn left onto Jalan Ampang")
    }

    func testIcons() {
        func icon(_ type: String, _ modifier: String?) -> String {
            Instruction.icon(for: Route.Step(type: type, modifier: modifier, latitude: 0, longitude: 0))
        }
        XCTAssertEqual(icon("turn", "left"), "arrow.turn.up.left")
        XCTAssertEqual(icon("off ramp", "slight right"), "arrow.up.right")
        XCTAssertEqual(icon("turn", "uturn"), "arrow.uturn.down")
        XCTAssertEqual(icon("roundabout", "right"), "arrow.clockwise.circle")
        XCTAssertEqual(icon("arrive", nil), "flag.checkered")
        XCTAssertEqual(icon("new name", "straight"), "arrow.up")
    }

    func testMetricDistances() {
        func distance(_ metres: Double) -> String {
            Format.distance(metres, locale: english)
        }
        XCTAssertEqual(distance(-5), "0 m")
        XCTAssertEqual(distance(44), "40 m")
        XCTAssertEqual(distance(312), "300 m")
        XCTAssertEqual(distance(330), "350 m")
        XCTAssertEqual(distance(974), "950 m")
        XCTAssertEqual(distance(980), "1.0 km")
        XCTAssertEqual(distance(1240), "1.2 km")
        XCTAssertEqual(distance(12400), "12 km")
    }

    func testDurations() {
        XCTAssertEqual(Format.duration(20, locale: english), "1 min")
        XCTAssertEqual(Format.duration(8 * 60 + 10, locale: english), "8 min")
        XCTAssertEqual(Format.duration(65 * 60, locale: english), "1 hr, 5 min")
    }
}

import CoreLocation
import MapLibre
import UIKit

/// Rules for the car location puck. Pure, so they are tested without a map.
enum Puck {
    /// Fixes vaguer than this show the plain dot. Approximate-location
    /// authorisation reports kilometres; a cell-tower fix hundreds of metres.
    static let maxCarAccuracy: CLLocationAccuracy = 100
    /// Below this speed the GPS course is noise; the compass heading is used.
    static let minCourseSpeed: CLLocationSpeed = 1
    /// How long a turn of the car animates.
    static let turnDuration: TimeInterval = 0.3

    /// Whether a fix is precise enough to draw the car rather than the dot.
    static func showsCar(accuracy: CLLocationAccuracy) -> Bool {
        accuracy >= 0 && accuracy <= maxCarAccuracy
    }

    /// Degrees clockwise from north the car should face: the GPS course while
    /// driving, the compass heading when stationary, else where it last pointed.
    /// Negative course or heading means CoreLocation does not know.
    static func angle(
        course: CLLocationDirection, speed: CLLocationSpeed, heading: CLLocationDirection?,
        previous: CLLocationDirection
    ) -> CLLocationDirection {
        if speed >= minCourseSpeed, course >= 0 {
            return course
        }
        if let heading, heading >= 0 {
            return heading
        }
        return previous
    }

    /// `target`, unwrapped so a tween from `current` goes the short way round
    /// (350° to 10° becomes 350° to 370°, not a 340° spin the other way).
    static func turn(from current: CLLocationDirection, to target: CLLocationDirection) -> CLLocationDirection {
        var delta = (target - current).truncatingRemainder(dividingBy: 360)
        if delta > 180 {
            delta -= 360
        }
        if delta < -180 {
            delta += 360
        }
        return current + delta
    }

    /// How long to animate a turn: none with Reduce Motion, so the car snaps.
    static func turnDuration(reduceMotion: Bool) -> TimeInterval {
        reduceMotion ? 0 : turnDuration
    }
}

/// The user's position as a shaded top-down car with a soft shadow and an
/// accuracy halo. Rotates with course or heading, lies flat on a pitched map,
/// and falls back to a dot for approximate fixes. Our own drawing.
final class CarPuckView: MLNUserLocationAnnotationView {
    private let halo = CAShapeLayer()
    private let dot = CAShapeLayer()
    private let car = CALayer()
    private let body = CAShapeLayer()
    private let paint = CAGradientLayer()
    private let glass = CAShapeLayer()
    private var angle: CLLocationDirection = 0

    private static let size: CGFloat = 48
    private static let carSize = CGSize(width: 20, height: 38)
    private static let dotRadius: CGFloat = 9

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)
        bounds = CGRect(x: 0, y: 0, width: Self.size, height: Self.size)
        let centre = CGPoint(x: Self.size / 2, y: Self.size / 2)

        halo.position = centre
        halo.lineWidth = 1
        layer.addSublayer(halo)

        dot.path = UIBezierPath(ovalIn: CGRect(
            x: -Self.dotRadius, y: -Self.dotRadius, width: 2 * Self.dotRadius, height: 2 * Self.dotRadius
        )).cgPath
        dot.position = centre
        dot.lineWidth = 3
        dot.strokeColor = UIColor.white.cgColor
        dot.shadowOpacity = 0.3
        dot.shadowRadius = 3
        dot.shadowOffset = CGSize(width: 0, height: 2)
        layer.addSublayer(dot)

        car.bounds = CGRect(origin: .zero, size: Self.carSize)
        car.position = centre
        car.shadowOpacity = 0.35
        car.shadowRadius = 4
        car.shadowOffset = CGSize(width: 0, height: 3)
        car.shadowPath = Self.bodyPath.cgPath
        layer.addSublayer(car)

        // Body: a rounded shell, lit from the top left so it reads as a solid.
        body.path = Self.bodyPath.cgPath
        paint.frame = car.bounds
        paint.startPoint = CGPoint(x: 0, y: 0)
        paint.endPoint = CGPoint(x: 1, y: 1)
        paint.mask = body
        car.addSublayer(paint)

        // Cabin: windscreen and rear window in dark glass, the roof between them.
        let windows = UIBezierPath(roundedRect: CGRect(x: 3, y: 9, width: 14, height: 7), cornerRadius: 2.5)
        windows.append(UIBezierPath(roundedRect: CGRect(x: 4, y: 27, width: 12, height: 5), cornerRadius: 2))
        glass.path = windows.cgPath
        glass.lineWidth = 1
        car.addSublayer(glass)

        isAccessibilityElement = true
        accessibilityLabel = String(localized: "Your location")
        applyColours()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Car outline: wider at the rear, tapered nose, rounded corners.
    private static var bodyPath: UIBezierPath {
        let width = carSize.width, height = carSize.height
        let path = UIBezierPath()
        path.move(to: CGPoint(x: width / 2, y: 0))
        path.addCurve(
            to: CGPoint(x: width, y: 10),
            controlPoint1: CGPoint(x: width * 0.85, y: 0), controlPoint2: CGPoint(x: width, y: 3)
        )
        path.addLine(to: CGPoint(x: width, y: height - 5))
        path.addQuadCurve(to: CGPoint(x: width - 5, y: height), controlPoint: CGPoint(x: width, y: height))
        path.addLine(to: CGPoint(x: 5, y: height))
        path.addQuadCurve(to: CGPoint(x: 0, y: height - 5), controlPoint: CGPoint(x: 0, y: height))
        path.addLine(to: CGPoint(x: 0, y: 10))
        path.addCurve(
            to: CGPoint(x: width / 2, y: 0),
            controlPoint1: CGPoint(x: 0, y: 3), controlPoint2: CGPoint(x: width * 0.15, y: 0)
        )
        path.close()
        return path
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        if previous?.userInterfaceStyle != traitCollection.userInterfaceStyle {
            applyColours()
        }
    }

    /// Theme violets, lit from the top left. Light mode: light tint over the
    /// accent fill. Dark mode: a step brighter, so the car stands out on dark tiles.
    private func applyColours() {
        let tint = UIColor(Theme.accent).resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
        let dark = traitCollection.userInterfaceStyle == .dark
        let top = dark ? UIColor(hex: 0xCFC9FF) : tint // lavender highlight
        let bottom = dark ? tint : UIColor(Theme.accentFill)
        paint.colors = [top.cgColor, bottom.cgColor]
        glass.fillColor = UIColor(white: 0.12, alpha: 1).cgColor
        glass.strokeColor = UIColor(white: 1, alpha: 0.35).cgColor
        dot.fillColor = bottom.cgColor
        halo.fillColor = top.withAlphaComponent(0.15).cgColor
        halo.strokeColor = top.withAlphaComponent(0.4).cgColor
    }

    override func update() {
        guard let mapView, let location = userLocation?.location else { return }
        let showsCar = Puck.showsCar(accuracy: location.horizontalAccuracy)
        let compass = userLocation?.heading.map { $0.trueHeading >= 0 ? $0.trueHeading : $0.magneticHeading }
        let target = Puck.angle(
            course: location.course, speed: location.speed, heading: compass, previous: angle
        )
        let turn = Puck.turn(from: angle, to: target)
        let metersPerPoint = mapView.metersPerPoint(atLatitude: location.coordinate.latitude)
        let radius = max(location.horizontalAccuracy, 0) / metersPerPoint

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        car.isHidden = !showsCar
        dot.isHidden = showsCar
        // Hide the halo once it would sit inside the puck itself.
        halo.isHidden = radius <= Self.size / 2
        halo.path = UIBezierPath(ovalIn: CGRect(x: -radius, y: -radius, width: 2 * radius, height: 2 * radius)).cgPath
        // Counter the map's rotation, then tilt with its pitch so the car lies on the road.
        let flat = CATransform3DMakeRotation(mapView.camera.pitch * .pi / 180, 1, 0, 0)
        layer.sublayerTransform = CATransform3DRotate(flat, -mapView.direction * .pi / 180, 0, 0, 1)
        CATransaction.commit()

        guard turn != angle else { return }
        angle = turn
        let duration = Puck.turnDuration(reduceMotion: UIAccessibility.isReduceMotionEnabled)
        CATransaction.begin()
        CATransaction.setDisableActions(duration == 0)
        CATransaction.setAnimationDuration(duration)
        car.transform = CATransform3DMakeRotation(turn * .pi / 180, 0, 0, 1)
        CATransaction.commit()
    }
}

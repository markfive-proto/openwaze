import UIKit

#if DEBUG
    /// Draws a fading circle at every touch (and a dotted trail for drags) so taps
    /// show in screen recordings. Debug only; enabled by the launch argument
    /// `-ShowTouches YES` (`scripts/demo/record.sh`, #52).
    enum TouchOverlay {
        private static var canvas: UIWindow?

        /// Installs once the app's window exists; a no-op without the launch argument.
        static func install() {
            guard UserDefaults.standard.bool(forKey: "ShowTouches"), canvas == nil else { return }
            guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                  let window = scene.windows.first
            else {
                DispatchQueue.main.async(execute: install) // not attached yet, try after this run loop turn
                return
            }
            // The drawing goes in its own window above alerts and sheets; touches pass through it.
            let overlay = UIWindow(windowScene: scene)
            overlay.windowLevel = .alert + 1
            overlay.isUserInteractionEnabled = false
            overlay.rootViewController = UIViewController()
            overlay.rootViewController?.view.backgroundColor = .clear
            overlay.isHidden = false
            canvas = overlay
            // A recognizer on the window sees every touch in it, including sheets, without claiming them.
            let recognizer = Recognizer()
            recognizer.cancelsTouchesInView = false
            recognizer.delaysTouchesBegan = false
            recognizer.delaysTouchesEnded = false
            window.addGestureRecognizer(recognizer)
        }

        private final class Recognizer: UIGestureRecognizer {
            override func touchesBegan(_ touches: Set<UITouch>, with _: UIEvent) {
                touches.forEach { mark($0, radius: 28, duration: 0.6) }
            }

            override func touchesMoved(_ touches: Set<UITouch>, with _: UIEvent) {
                touches.forEach { mark($0, radius: 10, duration: 0.5) }
            }

            override func touchesEnded(_: Set<UITouch>, with _: UIEvent) {
                state = .failed // never claims the gesture
            }

            override func touchesCancelled(_: Set<UITouch>, with _: UIEvent) {
                state = .failed
            }
        }

        /// A circle that shrinks and fades, then removes itself.
        private static func mark(_ touch: UITouch, radius: CGFloat, duration: Double) {
            guard let canvas, let host = canvas.rootViewController?.view else { return }
            let point = touch.location(in: canvas)
            let dot = CAShapeLayer()
            let box = CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2)
            dot.path = UIBezierPath(ovalIn: box).cgPath
            dot.position = point
            dot.fillColor = UIColor.systemBlue.withAlphaComponent(0.35).cgColor
            dot.strokeColor = UIColor.systemBlue.cgColor
            dot.lineWidth = 2
            host.layer.addSublayer(dot)
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            let shrink = CABasicAnimation(keyPath: "transform.scale")
            shrink.fromValue = 1
            shrink.toValue = 0.6
            let group = CAAnimationGroup()
            group.animations = [fade, shrink]
            group.duration = duration
            group.fillMode = .forwards
            group.isRemovedOnCompletion = false
            CATransaction.begin()
            CATransaction.setCompletionBlock { dot.removeFromSuperlayer() }
            dot.add(group, forKey: "fade")
            CATransaction.commit()
        }
    }
#else
    enum TouchOverlay {
        static func install() {}
    }
#endif

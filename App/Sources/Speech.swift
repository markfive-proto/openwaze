import AVFoundation
import CoreLocation

/// Orders prompts: a newer route, then a later maneuver, is newer.
struct PromptKey: Comparable {
    var route: Int
    var step: Int

    static func < (lhs: PromptKey, rhs: PromptKey) -> Bool {
        (lhs.route, lhs.step) < (rhs.route, rhs.step)
    }
}

/// Speaks prompts; a fake stands in for it in tests.
protocol Speaking: AnyObject {
    func say(_ text: String, key: PromptKey)
    func stop()
}

/// Spoken prompts that duck other audio (music, podcasts) while talking.
/// Prompts queue in order; one for a newer maneuver drops any still
/// waiting (or playing) for an older one, which is no longer true.
final class Speech: NSObject, Speaking, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private struct Queued {
        var utterance: AVSpeechUtterance
        var text: String
        var key: PromptKey
    }

    private var queued: [Queued] = []

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func say(_ text: String, key: PromptKey) {
        let session = AVAudioSession.sharedInstance()
        let options: AVAudioSession.CategoryOptions = [.duckOthers, .interruptSpokenAudioAndMixWithOthers]
        try? session.setCategory(.playback, mode: .voicePrompt, options: options)
        try? session.setActive(true)
        if queued.contains(where: { $0.key < key }) {
            let keep = queued.filter { !($0.key < key) }
            queued = []
            synthesizer.stopSpeaking(at: .immediate) // cancels the whole queue
            keep.forEach { enqueue($0.text, key: $0.key) }
        }
        enqueue(text, key: key)
    }

    func stop() {
        queued = []
        synthesizer.stopSpeaking(at: .immediate)
        deactivate()
    }

    private func enqueue(_ text: String, key: PromptKey) {
        let utterance = AVSpeechUtterance(string: text)
        queued.append(Queued(utterance: utterance, text: text, key: key))
        synthesizer.speak(utterance)
    }

    private func finished(_ utterance: AVSpeechUtterance) {
        queued.removeAll { $0.utterance === utterance }
        if queued.isEmpty {
            deactivate()
        }
    }

    /// Lets ducked audio come back up.
    private func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func speechSynthesizer(_: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        finished(utterance)
    }

    func speechSynthesizer(_: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        finished(utterance)
    }
}

/// GPS fixes for a trip. Keeps running with the screen locked or the app in
/// the background, but only while navigating.
final class LocationFeed: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var onFix: ((CLLocation) -> Void)?

    override init() {
        super.init()
        manager.delegate = self
        manager.activityType = .automotiveNavigation
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
    }

    func start(_ onFix: @escaping (CLLocation) -> Void) {
        self.onFix = onFix
        manager.allowsBackgroundLocationUpdates = true // needs UIBackgroundModes "location"
        manager.pausesLocationUpdatesAutomatically = false
        manager.showsBackgroundLocationIndicator = true
        manager.startUpdatingLocation()
    }

    func stop() {
        onFix = nil
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        manager.pausesLocationUpdatesAutomatically = true
    }

    func locationManager(_: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        locations.forEach { onFix?($0) }
    }
}

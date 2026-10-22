import AudioToolbox
import CoreLocation
import SwiftUI

/// Over-limit state with hysteresis: goes over above limit + margin, and
/// back only once below that by `hysteresis`, so it doesn't flap.
struct OverLimit {
    /// Allowed above the posted limit before warning.
    static let margin = 5.0 // km/h
    static let hysteresis = 3.0 // km/h

    private(set) var isOver = false

    /// True when this sample just went over (time to chime).
    mutating func update(speed: Double?, limit: Double?) -> Bool {
        guard let speed, let limit else {
            isOver = false
            return false
        }
        let threshold = limit + Self.margin
        if isOver {
            isOver = speed > threshold - Self.hysteresis
            return false
        }
        isOver = speed > threshold
        return isOver
    }
}

enum SpeedUnit {
    static var metric: Bool {
        Locale.current.measurementSystem == .metric
    }

    /// Whole number in the display unit.
    static func display(_ kmh: Double, metric: Bool) -> Int {
        Int((metric ? kmh : kmh / Maxspeed.kmhPerMph).rounded())
    }

    static func label(metric: Bool) -> String {
        metric ? String(localized: "km/h") : String(localized: "mph")
    }
}

struct SpeedCache: Codable {
    var fetched: Date
    var ways: [SpeedWay]
}

/// Speed-limit tiles: memory, then a small disk cache (7 days), then
/// Overpass. One request at a time, with backoff after failures, per the
/// Overpass usage policy.
@MainActor
final class SpeedLimitStore {
    static let shared = SpeedLimitStore(
        directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("speed-limits")
    )
    static let ttl: TimeInterval = 7 * 24 * 3600
    static let maxFiles = 200

    private let directory: URL?
    private let fetch: Overpass.Fetch
    private let now: () -> Date
    private var memory: [SpeedTile: SpeedCache] = [:]
    private var loading = false
    private var failures = 0
    private var retryAt = Date.distantPast

    init(
        directory: URL?,
        fetch: @escaping Overpass.Fetch = { try await URLSession.shared.data(for: $0) },
        now: @escaping () -> Date = Date.init
    ) {
        self.directory = directory
        self.fetch = fetch
        self.now = now
    }

    /// Ways for the tile, fetching when missing or stale. Nil while unknown.
    func ways(for tile: SpeedTile) async -> [SpeedWay]? {
        if memory[tile] == nil, let disk = read(tile) {
            memory[tile] = disk
        }
        let cached = memory[tile]
        if let cached, now().timeIntervalSince(cached.fetched) < Self.ttl {
            return cached.ways
        }
        guard !loading, now() >= retryAt else { return cached?.ways }
        loading = true
        defer { loading = false }
        do {
            let ways = try await Overpass.ways(in: tile, fetch: fetch)
            let entry = SpeedCache(fetched: now(), ways: ways)
            memory[tile] = entry
            write(entry, for: tile)
            failures = 0
            return ways
        } catch {
            failures += 1
            var status: Int?
            if case let .http(code)? = error as? OverpassError {
                status = code
            }
            retryAt = now().addingTimeInterval(Overpass.backoff(after: failures, status: status))
            return cached?.ways
        }
    }

    private func file(_ tile: SpeedTile) -> URL? {
        directory?.appendingPathComponent("\(tile.key).json")
    }

    private func read(_ tile: SpeedTile) -> SpeedCache? {
        guard let url = file(tile), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SpeedCache.self, from: data)
    }

    private func write(_ entry: SpeedCache, for tile: SpeedTile) {
        guard let directory, let url = file(tile), let data = try? JSONEncoder().encode(entry) else { return }
        let files = FileManager.default
        try? files.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        // Keep it small: drop the oldest tiles past the cap.
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let all = try? files.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys),
              all.count > Self.maxFiles else { return }
        let date = { (url: URL) in
            (try? url.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
        }
        all.sorted { date($0) < date($1) }.prefix(all.count - Self.maxFiles).forEach { try? files.removeItem(at: $0) }
    }
}

/// Current speed, the road's limit, and the over-limit warning.
@MainActor
@Observable
final class Speedometer {
    /// Weight of a new sample; the rest is the previous value.
    static let smoothing = 0.6
    /// Older fixes are not used to look up the limit.
    static let maxFixAge: TimeInterval = 10

    /// km/h, smoothed. Nil until a valid fix.
    private(set) var speed: Double?
    /// km/h. Nil when not known.
    private(set) var limit: Double?
    private(set) var warning = OverLimit()

    @ObservationIgnored private let store: SpeedLimitStore
    @ObservationIgnored private let chime: () -> Void
    @ObservationIgnored private var feed: SpeedFeed?
    /// Bumped per limit lookup; only the latest one may set `limit`.
    @ObservationIgnored private var lookup = 0
    /// The lookup tests await it.
    @ObservationIgnored private(set) var pending: Task<Void, Never>?

    init(store: SpeedLimitStore = .shared, chime: @escaping () -> Void = Speedometer.playChime) {
        self.store = store
        self.chime = chime
    }

    var isOver: Bool {
        warning.isOver
    }

    func start() {
        guard feed == nil else { return }
        feed = SpeedFeed { [weak self] location in
            MainActor.assumeIsolated { self?.update(location) }
        }
    }

    func stop() {
        feed = nil
    }

    func update(_ location: CLLocation) {
        // Negative speed means CLLocation has no valid speed. speedAccuracy is
        // not checked: simulated and some real fixes report -1 with a good speed.
        guard location.speed >= 0, location.speed.isFinite else { return }
        let kmh = location.speed * 3.6
        speed = speed.map { $0 + Self.smoothing * (kmh - $0) } ?? kmh
        check()
        // A vague or old fix could match a parallel road: keep the last limit.
        guard (0 ... Guidance.maxFixAccuracy).contains(location.horizontalAccuracy),
              -location.timestamp.timeIntervalSinceNow <= Self.maxFixAge else { return }
        let course = location.course >= 0 && location.speed >= SpeedMatch.minSpeedForCourse ? location.course : nil
        lookup += 1
        let lookup = lookup
        pending = Task { [weak self, store] in
            let ways = await store.ways(for: SpeedTile(location.coordinate))
            // A slow tile fetch must not overwrite the limit for a newer fix.
            guard let self, let ways, lookup == self.lookup else { return }
            limit = SpeedMatch.nearest(ways, to: location.coordinate, course: course)
                .flatMap { Maxspeed.kmh($0.maxspeed) }
            check()
        }
    }

    private func check() {
        if warning.update(speed: speed, limit: limit) {
            chime()
        }
    }

    /// A system sound: muted by the Silent switch and mixed with other audio.
    static func playChime() {
        AudioServicesPlaySystemSound(1005)
    }
}

/// Foreground location updates for the speedometer.
final class SpeedFeed: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private let onFix: (CLLocation) -> Void

    init(_ onFix: @escaping (CLLocation) -> Void) {
        self.onFix = onFix
        super.init()
        manager.delegate = self
        manager.activityType = .automotiveNavigation
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.startUpdatingLocation()
    }

    deinit {
        manager.stopUpdatingLocation()
    }

    func locationManager(_: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        locations.forEach(onFix)
    }
}

/// Current speed, red when over the limit, with a round limit sign beside it
/// (white disc, red ring, as on Malaysian signs) when the limit is known.
struct SpeedBubble: View {
    @Scaled private var size: CGFloat = Theme.fab
    @Scaled private var sign: CGFloat = 44
    @State private var meter = Speedometer()

    private let metric = SpeedUnit.metric

    var body: some View {
        HStack(alignment: .bottom, spacing: Theme.Space.small) {
            bubble
            if let limit = meter.limit {
                Text(verbatim: "\(SpeedUnit.display(limit, metric: metric))")
                    .font(.headline.weight(.heavy)).monospacedDigit()
                    .foregroundStyle(.black)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .padding(6)
                    .frame(width: sign, height: sign)
                    .background(.white, in: Circle())
                    .overlay(Circle().strokeBorder(Theme.danger, lineWidth: sign * 0.13))
                    .shadow(color: Theme.shadow, radius: 6, y: 2)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge) // glyphs inside fixed discs
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .onAppear { meter.start() }
        .onDisappear { meter.stop() }
    }

    private var bubble: some View {
        VStack(spacing: -2) {
            Text(verbatim: meter.speed.map { "\(SpeedUnit.display($0, metric: metric))" } ?? "–")
                .font(.title2.weight(.heavy)).monospacedDigit()
            Text(SpeedUnit.label(metric: metric)).font(.caption2.weight(.bold))
                .foregroundStyle(meter.isOver ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
        }
        .foregroundStyle(meter.isOver ? .white : .primary)
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .frame(width: size, height: size)
        .background(meter.isOver ? Theme.danger : Theme.surface, in: Circle())
        .overlay(Circle().strokeBorder(meter.isOver ? Theme.danger : Color.primary.opacity(0.85), lineWidth: 3))
        .shadow(color: Theme.shadow, radius: 10, y: 4)
        .animation(.easeInOut(duration: 0.2), value: meter.isOver)
    }

    private var label: Text {
        guard let speed = meter.speed else { return Text("Speed unavailable") }
        let unit = SpeedUnit.label(metric: metric)
        let current = SpeedUnit.display(speed, metric: metric)
        guard let limit = meter.limit.map({ SpeedUnit.display($0, metric: metric) }) else {
            return Text(verbatim: String(localized: "Speed \(current) \(unit)"))
        }
        return Text(verbatim: meter.isOver
            ? String(localized: "Speed \(current) \(unit), limit \(limit), over the limit")
            : String(localized: "Speed \(current) \(unit), limit \(limit)"))
    }
}

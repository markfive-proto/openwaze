import CoreLocation

/// Crowd reports in the visible map area: refreshed when the map moves
/// (debounced) and every minute, with optimistic posting.
@MainActor
@Observable
final class ReportsStore {
    typealias Sleep = (TimeInterval) async throws -> Void

    static let debounce: TimeInterval = 0.5
    static let refreshInterval: TimeInterval = 60

    /// Active reports in the current area, newest first.
    private(set) var reports: [Report] = []
    /// Why the last refresh failed; cleared by the next success. The previous
    /// reports stay up meanwhile.
    private(set) var lastError: Error?
    /// IDs of reports this device created; the server refuses votes on them.
    private(set) var mine: Set<String> = []

    @ObservationIgnored private let client: ReportsClient
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let sleep: Sleep
    @ObservationIgnored private var bbox: BBox?
    /// The server's answer for `bbox`.
    @ObservationIgnored private var fetched: [Report] = []
    /// Optimistic and freshly created reports, shown until the server lists them.
    @ObservationIgnored private var local: [String: Report] = [:]
    @ObservationIgnored private var timer: Task<Void, Never>?
    /// The latest load; tests await it.
    @ObservationIgnored private(set) var work: Task<Void, Never>?

    init(
        client: ReportsClient = ReportsClient(),
        now: @escaping () -> Date = Date.init,
        sleep: @escaping Sleep = { try await Task.sleep(for: .seconds($0)) }
    ) {
        self.client = client
        self.now = now
        self.sleep = sleep
    }

    /// Reports the driver may vote on ("Still there?").
    var votable: [Report] {
        reports.filter { !mine.contains($0.id) && !$0.id.hasPrefix(Self.localPrefix) }
    }

    /// Call on every map move; loads once the map rests, cancelling any
    /// load for an area the map already left.
    func setRegion(_ bbox: BBox) {
        self.bbox = bbox.clamped
        load(after: Self.debounce)
    }

    /// Refreshes the current area every minute until `stop()`.
    func start() {
        timer?.cancel()
        timer = Task { [weak self, sleep] in
            while true {
                do { try await sleep(Self.refreshInterval) } catch { return }
                self?.load(after: 0)
            }
        }
    }

    func stop() {
        timer?.cancel()
        timer = nil
        work?.cancel()
    }

    /// Shows the report at once and posts it; on failure it is removed again
    /// and the error rethrown for the UI.
    @discardableResult
    func report(_ type: ReportType, at coordinate: CLLocationCoordinate2D) async throws -> Report {
        let created = now()
        let draft = Report(
            id: Self.localPrefix + UUID().uuidString, type: type,
            lat: coordinate.latitude, lng: coordinate.longitude,
            createdAt: created, expiresAt: created.addingTimeInterval(type.lifetime),
            upvotes: 0, downvotes: 0
        )
        local[draft.id] = draft
        rebuild()
        defer {
            local[draft.id] = nil
            rebuild()
        }
        let saved = try await client.create(type, at: coordinate)
        local[saved.id] = saved
        mine.insert(saved.id)
        return saved
    }

    func vote(_ id: String, stillThere: Bool) async throws {
        let updated = try await client.vote(id, stillThere: stillThere)
        fetched = fetched.map { $0.id == id ? updated : $0 }
        if local[id] != nil {
            local[id] = updated
        }
        rebuild()
    }

    private static let localPrefix = "local-"

    private func load(after delay: TimeInterval) {
        guard let bbox else { return }
        work?.cancel()
        work = Task { [weak self, client, sleep] in
            do {
                if delay > 0 {
                    try await sleep(delay)
                }
                let found = try await client.list(bbox)
                try Task.checkCancellation() // the map moved on while this was in flight
                self?.fetched = found
                self?.lastError = nil
                self?.rebuild()
            } catch {
                guard !Task.isCancelled else { return }
                self?.lastError = error
                self?.rebuild() // keep showing what we have, minus anything expired
            }
        }
    }

    /// Server results merged with local ones by ID (the server's copy wins),
    /// minus anything expired or outside the area.
    private func rebuild() {
        let now = now()
        let listed = Set(fetched.map(\.id))
        local = local.filter { !listed.contains($0.key) && $0.value.expiresAt > now }
        // ponytail: an own report downvoted away by others stays until it
        // expires locally; fine while lifetimes are an hour or two.
        let extra = local.values.filter { bbox?.contains($0.coordinate) ?? true }
        reports = (fetched + extra)
            .filter { $0.expiresAt > now }
            .sorted { $0.createdAt > $1.createdAt }
    }
}

extension BBox {
    func contains(_ point: CLLocationCoordinate2D) -> Bool {
        (minLat ... maxLat).contains(point.latitude) && (minLng ... maxLng).contains(point.longitude)
    }
}

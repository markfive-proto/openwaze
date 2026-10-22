import CoreLocation

/// Crowd reports in the visible map area: refreshed when the map moves
/// (debounced) and every minute, with optimistic posting.
@MainActor
@Observable
final class ReportsStore {
    typealias Sleep = (TimeInterval) async throws -> Void

    static let debounce: TimeInterval = 0.5
    static let refreshInterval: TimeInterval = 60
    static let mineKey = "reports.mine"

    /// Active reports in the current area, newest first.
    private(set) var reports: [Report] = []
    /// Why the last refresh failed; cleared by the next success. The previous
    /// reports stay up meanwhile.
    private(set) var lastError: Error?
    /// IDs of reports this device created (the server refuses votes on
    /// them), kept across launches until they expire.
    var mine: Set<String> {
        Set(mineExpiry.keys)
    }

    @ObservationIgnored private let client: ReportsClient
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let sleep: Sleep
    @ObservationIgnored private let defaults: UserDefaults
    private var mineExpiry: [String: Date]
    @ObservationIgnored private var bbox: BBox?
    /// The server's answer for `bbox`.
    @ObservationIgnored private var fetched: [Report] = []
    /// Optimistic and freshly created reports, shown until the server lists them.
    @ObservationIgnored private var local: [String: Report] = [:]
    /// Bumped by every confirmed report or vote, so a list fetched before
    /// one can't overwrite it.
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var timer: Task<Void, Never>?
    /// The latest load; tests await it.
    @ObservationIgnored private(set) var work: Task<Void, Never>?

    init(
        client: ReportsClient = ReportsClient(),
        now: @escaping () -> Date = Date.init,
        sleep: @escaping Sleep = { try await Task.sleep(for: .seconds($0)) },
        defaults: UserDefaults = .standard
    ) {
        self.client = client
        self.now = now
        self.sleep = sleep
        self.defaults = defaults
        let stored = defaults.dictionary(forKey: Self.mineKey) as? [String: Date] ?? [:]
        mineExpiry = stored.filter { $0.value > now() }
        if client.baseURL == nil {
            lastError = ReportsError.notConfigured
        }
    }

    /// Reports the driver may vote on ("Still there?"): not drafts, not own.
    var votable: [Report] {
        reports.filter { !$0.isDraft && mineExpiry[$0.id] == nil }
    }

    /// Call on every map move; loads once the map rests, cancelling any
    /// load for an area the map already left.
    func setRegion(_ bbox: BBox) {
        self.bbox = bbox.clamped
        load(after: Self.debounce)
    }

    /// Refreshes the current area every minute until `stop()` (or until the
    /// store is gone).
    func start() {
        timer?.cancel()
        timer = Task { [weak self, sleep] in
            while true {
                do { try await sleep(Self.refreshInterval) } catch { return }
                guard let self else { return }
                load(after: 0)
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
            id: Report.draftPrefix + UUID().uuidString, type: type,
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
        revision += 1
        local[saved.id] = saved
        mineExpiry[saved.id] = saved.expiresAt
        saveMine()
        return saved
    }

    func vote(_ id: String, stillThere: Bool) async throws {
        let updated = try await client.vote(id, stillThere: stillThere)
        revision += 1
        fetched = fetched.map { $0.id == id ? updated : $0 }
        if local[id] != nil {
            local[id] = updated
        }
        rebuild()
    }

    private func load(after delay: TimeInterval) {
        guard let bbox else { return }
        work?.cancel()
        let started = revision
        work = Task { [weak self, client, sleep] in
            do {
                if delay > 0 {
                    try await sleep(delay)
                }
                let found = try await client.list(bbox)
                try Task.checkCancellation() // the map moved on while this was in flight
                guard let self else { return }
                guard revision == started else { return load(after: 0) } // predates a vote or report
                fetched = found
                lastError = nil
                rebuild()
            } catch {
                guard !Task.isCancelled, let self else { return }
                lastError = error
                rebuild() // keep showing what we have, minus anything expired
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
        // Others' votes can extend an own report; keep it "mine" as long.
        var mine = mineExpiry.filter { $0.value > now }
        for report in reports where mine[report.id] != nil {
            mine[report.id] = max(mine[report.id] ?? report.expiresAt, report.expiresAt)
        }
        if mine != mineExpiry {
            mineExpiry = mine
            saveMine()
        }
    }

    private func saveMine() {
        defaults.set(mineExpiry, forKey: Self.mineKey)
    }
}

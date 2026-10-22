import Foundation
import SwiftData

/// A saved place (Home, Work) or a recent destination, stored on device.
@Model
final class Place {
    enum Role: String, CaseIterable {
        case home, work, recent
    }

    /// "home", "work" or "recent:<Destination.id>": one row per saved slot.
    /// Destination ids are OSM type + id (e.g. "N123"), stable across searches.
    @Attribute(.unique) var key = ""
    /// `Role` raw value; stored as a string so `#Predicate` can filter on it.
    var role = Role.recent.rawValue
    /// `Destination.id`.
    var placeID = ""
    var name = ""
    var address = ""
    var latitude = 0.0
    var longitude = 0.0
    var usedAt = Date.distantPast

    init(_ destination: Destination, role: Role, usedAt: Date) {
        key = Self.key(for: destination, role: role)
        self.role = role.rawValue
        self.usedAt = usedAt
        update(from: destination)
    }

    static func key(for destination: Destination, role: Role) -> String {
        role == .recent ? "recent:\(destination.id)" : role.rawValue
    }

    func update(from destination: Destination) {
        placeID = destination.id
        name = destination.name
        address = destination.address
        latitude = destination.latitude
        longitude = destination.longitude
    }

    var destination: Destination {
        Destination(id: placeID, name: name, address: address, latitude: latitude, longitude: longitude)
    }
}

enum PlacesSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] {
        [Place.self]
    }
}

enum PlacesMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [PlacesSchemaV1.self]
    }

    static var stages: [MigrationStage] {
        []
    }
}

@MainActor
enum Places {
    static let recentLimit = 10

    /// The on-disk store, or an in-memory one if it cannot open (corrupt or
    /// unmigratable), so a bad store never crash-loops the app. `error` is
    /// set in that case so the UI can say saved places won't be kept.
    static func makeContainer() -> (container: ModelContainer, error: Error?) {
        let schema = Schema(versionedSchema: PlacesSchemaV1.self)
        do {
            return try (ModelContainer(for: schema, migrationPlan: PlacesMigrationPlan.self), nil)
        } catch {
            do {
                let memory = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
                return try (ModelContainer(for: schema, configurations: memory), error)
            } catch {
                fatalError("In-memory SwiftData store failed: \(error)")
            }
        }
    }

    /// Most recent first.
    static func all(_ role: Place.Role, in context: ModelContext) throws -> [Place] {
        let raw = role.rawValue
        let descriptor = FetchDescriptor<Place>(
            predicate: #Predicate { $0.role == raw },
            sortBy: [SortDescriptor(\.usedAt, order: .reverse)]
        )
        return try context.fetch(descriptor)
    }

    /// Moves `destination` to the top of recents (once), keeping the newest `recentLimit`.
    static func recordRecent(_ destination: Destination, in context: ModelContext, now: Date = .now) throws {
        try upsert(destination, as: .recent, in: context, now: now)
        try all(.recent, in: context).dropFirst(recentLimit).forEach(context.delete)
        try commit(context)
    }

    /// Replaces the saved Home or Work.
    static func save(_ destination: Destination, as role: Place.Role, in context: ModelContext) throws {
        precondition(role != .recent, "use recordRecent")
        try upsert(destination, as: role, in: context, now: .now)
        try commit(context)
    }

    static func remove(_ place: Place, in context: ModelContext) throws {
        context.delete(place)
        try commit(context)
    }

    private static func upsert(_ place: Destination, as role: Place.Role, in context: ModelContext, now: Date) throws {
        let destination = place
        let key = Place.key(for: destination, role: role)
        let existing = try context.fetch(FetchDescriptor<Place>(predicate: #Predicate { $0.key == key })).first
        if let existing {
            existing.update(from: destination)
            existing.usedAt = now
        } else {
            context.insert(Place(destination, role: role, usedAt: now))
        }
    }

    /// Saves, or undoes the pending changes and rethrows so the caller can say so.
    private static func commit(_ context: ModelContext) throws {
        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }
}

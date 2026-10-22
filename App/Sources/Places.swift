import Foundation
import SwiftData

/// A saved place (Home, Work) or a recent destination, stored on device.
@Model
final class Place {
    enum Role: String, CaseIterable {
        case home, work, recent
    }

    /// `Role` raw value; stored as a string so `#Predicate` can filter on it.
    var role: String
    /// `Destination.id`, used to dedupe recents.
    var placeID: String
    var name: String
    var address: String
    var latitude: Double
    var longitude: Double
    var usedAt: Date

    init(_ destination: Destination, role: Role, usedAt: Date) {
        self.role = role.rawValue
        placeID = destination.id
        name = destination.name
        address = destination.address
        latitude = destination.latitude
        longitude = destination.longitude
        self.usedAt = usedAt
    }

    var destination: Destination {
        Destination(id: placeID, name: name, address: address, latitude: latitude, longitude: longitude)
    }
}

@MainActor
enum Places {
    static let recentLimit = 10

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
        let recents = try all(.recent, in: context)
        let others = recents.filter { $0.placeID != destination.id }
        recents.filter { $0.placeID == destination.id }.forEach(context.delete)
        others.dropFirst(recentLimit - 1).forEach(context.delete)
        context.insert(Place(destination, role: .recent, usedAt: now))
        try context.save()
    }

    /// Replaces the saved Home or Work.
    static func save(_ destination: Destination, as role: Place.Role, in context: ModelContext) throws {
        precondition(role != .recent, "use recordRecent")
        try all(role, in: context).forEach(context.delete)
        context.insert(Place(destination, role: role, usedAt: .now))
        try context.save()
    }
}

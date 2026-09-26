import Foundation

nonisolated enum DriverStatus: String, Codable, Hashable, Sendable {
    case online
    case busy
    case offline
}

nonisolated struct Vehicle: Codable, Hashable, Sendable {
    var colour: String
    var make: String
    var model: String
    var plate: String

    var description: String { "\(colour) \(make) \(model)" }
}

/// A driver on the platform. Pickup portraits come from the asset catalog; missing photos use a neutral figure.
nonisolated struct Driver: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    var phone: String
    var rating: Double
    var trips: Int
    var tier: RideTier
    var vehicle: Vehicle
    var portraitName: String?
    var status: DriverStatus
    var position: GeoPoint
    var memberSince: Int
    /// Compass heading in degrees; derived from movement so idle cars face the way they last drove.
    var heading: Double = 0

    enum CodingKeys: String, CodingKey {
        case id, name, phone, rating, trips, tier, vehicle, portraitName, status, position, memberSince
    }

    var firstName: String {
        String(name.split(separator: " ").first ?? Substring(name))
    }

    var isAvailable: Bool { status == .online }
}

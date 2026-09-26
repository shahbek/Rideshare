import AppIntents
import CoreLocation
import CoreTransferable
import Foundation

// MARK: - Ride tier

/// The five ride options as a Siri-readable enum.
nonisolated enum RideTierValue: String, AppEnum {
    case economy, comfort, premium, bajaji, boda

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Ride Type")

    static let caseDisplayRepresentations: [RideTierValue: DisplayRepresentation] = [
        .economy: DisplayRepresentation(title: "Economy", subtitle: "Hatchback, 4 seats", image: .init(systemName: "car.fill")),
        .comfort: DisplayRepresentation(title: "Comfort", subtitle: "Sedan, 4 seats", image: .init(systemName: "car.fill")),
        .premium: DisplayRepresentation(title: "Premium", subtitle: "Minivan, 6 seats", image: .init(systemName: "car.side.fill")),
        .bajaji: DisplayRepresentation(title: "Bajaji", subtitle: "Three-wheeler, 3 seats", image: .init(systemName: "car.side.fill")),
        .boda: DisplayRepresentation(title: "Boda", subtitle: "Motorcycle, 1 seat", image: .init(systemName: "bicycle")),
    ]

    var tier: RideTier { RideTier(rawValue: rawValue) ?? .economy }

    init(_ tier: RideTier) {
        self = RideTierValue(rawValue: tier.rawValue) ?? .economy
    }
}

// MARK: - Place

/// A destination Siri can name, search, or lift from the screen. Transferable as a place descriptor so
/// Siri can chain it into Maps, Messages or Calendar ("send my destination to Amina").
nonisolated struct PlaceEntity: AppEntity, Transferable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Place")
    static let defaultQuery = PlaceQuery()

    var id: String

    @Property(title: "Name")
    var name: String

    @Property(title: "Address")
    var address: String

    @Property(title: "Latitude")
    var latitude: Double

    @Property(title: "Longitude")
    var longitude: Double

    @Property(title: "Saved as")
    var savedLabel: String?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(address)",
            image: .init(systemName: savedLabel == nil ? "mappin.and.ellipse" : "star.fill")
        )
    }

    var place: Place {
        Place(id: id, name: name, address: address, point: GeoPoint(latitude: latitude, longitude: longitude))
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    init(_ place: Place, savedLabel: String? = nil) {
        id = place.id
        name = place.name
        address = place.address
        latitude = place.point.latitude
        longitude = place.point.longitude
        self.savedLabel = savedLabel
    }

    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(exporting: { entity in
            "\(entity.name), \(entity.address) — https://maps.apple.com/?ll=\(entity.latitude),\(entity.longitude)&q=\(entity.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? entity.name)"
        })
    }
}

/// Resolves places by id, by spoken text (saved labels, catalogue, then Apple Maps), and suggests favourites.
nonisolated struct PlaceQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [PlaceEntity] {
        let env = try IntentEnvironment.resolve()
        return identifiers.compactMap { PlaceResolver.place(id: $0, in: env) }
    }

    @MainActor
    func entities(matching string: String) async throws -> [PlaceEntity] {
        let env = try IntentEnvironment.resolve()
        return await PlaceResolver.search(string, in: env)
    }

    @MainActor
    func suggestedEntities() async throws -> [PlaceEntity] {
        let env = try IntentEnvironment.resolve()
        return PlaceResolver.suggested(in: env)
    }
}

/// Shared lookup rules so intents and queries agree on what "home" or "the airport" means.
enum PlaceResolver {
    static func suggested(in env: AppEnvironment) -> [PlaceEntity] {
        let saved = env.store.savedPlaces.map { PlaceEntity($0.place, savedLabel: $0.label) }
        let recents = env.store.recents.map { PlaceEntity($0.place) }
        var seen: Set<String> = []
        return (saved + recents).filter { seen.insert($0.name.lowercased()).inserted }
    }

    static func place(id: String, in env: AppEnvironment) -> PlaceEntity? {
        if let saved = env.store.savedPlaces.first(where: { $0.id == id || $0.place.id == id }) {
            return PlaceEntity(saved.place, savedLabel: saved.label)
        }
        if let recent = env.store.recents.first(where: { $0.place.id == id }) {
            return PlaceEntity(recent.place)
        }
        if let catalogue = DemoPlaces.catalogue.first(where: { $0.id == id }) {
            return PlaceEntity(catalogue)
        }
        for trip in env.store.history {
            if trip.destination.id == id { return PlaceEntity(trip.destination) }
            if trip.pickup.id == id { return PlaceEntity(trip.pickup) }
        }
        return nil
    }

    static func search(_ text: String, in env: AppEnvironment) async -> [PlaceEntity] {
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return suggested(in: env) }

        var results: [PlaceEntity] = []
        // Saved labels first: "home", "work", "nyumbani", "kazini" or a custom label.
        for saved in env.store.savedPlaces {
            let aliases = [saved.label.lowercased(), saved.kind.rawValue] + kindAliases(saved.kind)
            if aliases.contains(where: { $0.contains(needle) || needle.contains($0) }) {
                results.append(PlaceEntity(saved.place, savedLabel: saved.label))
            }
        }
        results += DemoPlaces.search(needle).map { PlaceEntity($0) }
        results += env.store.recents.filter { $0.place.name.lowercased().contains(needle) }.map { PlaceEntity($0.place) }

        if results.isEmpty, needle.count >= 3 {
            let service = PlaceSearchService()
            await service.search(text)
            results += service.results.prefix(5).map { PlaceEntity($0) }
        }
        var seen: Set<String> = []
        return results.filter { seen.insert($0.name.lowercased()).inserted }
    }

    private static func kindAliases(_ kind: SavedPlaceKind) -> [String] {
        switch kind {
        case .home: ["home", "nyumbani", "house", "my place"]
        case .work: ["work", "kazini", "office", "ofisi"]
        case .other: []
        }
    }
}

// MARK: - Fare quote

/// A priced option returned by the quote step and accepted by the request step, so Siri can chain
/// "how much to the airport" → "book the comfort one".
nonisolated struct FareQuoteEntity: TransientAppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Fare Quote")

    @Property(title: "Ride type")
    var tier: RideTierValue

    @Property(title: "Fare (TZS)")
    var fare: Int

    @Property(title: "Pickup in (minutes)")
    var pickupEtaMinutes: Int

    @Property(title: "Journey (minutes)")
    var durationMinutes: Int

    @Property(title: "Distance (km)")
    var distanceKm: Double

    @Property(title: "Drivers nearby")
    var hasDriversNearby: Bool

    @Property(title: "Destination")
    var destination: PlaceEntity

    @Property(title: "Pickup")
    var pickup: PlaceEntity

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(RideTierValue.caseDisplayRepresentations[tier]?.title ?? "Ride") · \(Format.tzs(fare))",
            subtitle: hasDriversNearby
                ? "Pickup in \(pickupEtaMinutes) min · \(durationMinutes) min to \(destination.name)"
                : "No drivers nearby right now",
            image: .init(systemName: tier == .boda ? "bicycle" : "car.fill")
        )
    }

    init() {
        tier = .economy
        fare = 0
        pickupEtaMinutes = 0
        durationMinutes = 0
        distanceKm = 0
        hasDriversNearby = false
        destination = PlaceEntity(DemoPlaces.home)
        pickup = PlaceEntity(DemoPlaces.home)
    }

    init(_ quote: FareQuote, pickup: Place, destination: Place) {
        tier = RideTierValue(quote.tier)
        fare = quote.fare
        pickupEtaMinutes = quote.pickupEtaMinutes
        durationMinutes = quote.durationMinutes
        distanceKm = quote.distanceKm
        hasDriversNearby = quote.hasDriversNearby
        self.destination = PlaceEntity(destination)
        self.pickup = PlaceEntity(pickup)
    }
}

// MARK: - Trip

/// A ride — live or past — Siri can read from the screen, ask about, share or act on.
nonisolated struct TripEntity: AppEntity, Transferable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Trip")
    static let defaultQuery = TripQuery()

    var id: String

    @Property(title: "Destination")
    var destinationName: String

    @Property(title: "Pickup")
    var pickupName: String

    @Property(title: "Status")
    var status: String

    @Property(title: "Ride type")
    var tier: RideTierValue

    @Property(title: "Fare (TZS)")
    var fare: Int

    @Property(title: "Driver")
    var driverName: String?

    @Property(title: "Vehicle")
    var vehicle: String?

    @Property(title: "Plate")
    var plate: String?

    @Property(title: "Start code")
    var ridePIN: String?

    @Property(title: "Minutes until pickup")
    var pickupEtaMinutes: Int?

    @Property(title: "Minutes remaining")
    var remainingMinutes: Int?

    @Property(title: "Date")
    var date: Date

    @Property(title: "Is live")
    var isLive: Bool

    @Property(title: "Destination place")
    var destination: PlaceEntity

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(destinationName)",
            subtitle: "\(status) · \(Format.tzs(fare))",
            image: .init(systemName: isLive ? "location.fill" : "clock.arrow.circlepath")
        )
    }

    @MainActor
    init(_ trip: Trip, env: AppEnvironment) {
        id = trip.id
        destinationName = trip.destination.name
        pickupName = trip.pickup.name
        status = TripEntity.statusText(trip, env: env)
        tier = RideTierValue(trip.tier)
        fare = trip.phase == .cancelled ? (trip.cancellation?.fee ?? 0) : trip.totalDue
        let driver = env.drivers.driver(id: trip.driverID)
        driverName = driver?.name
        vehicle = driver?.vehicle.description
        plate = driver.map { Format.plate($0.vehicle.plate) }
        ridePIN = trip.phase == .driverAssigned || trip.phase == .driverArrived ? trip.ridePIN : nil
        let isCurrent = env.trips.activeTrip?.id == trip.id
        pickupEtaMinutes = isCurrent && trip.phase == .driverAssigned ? max(env.trips.driverEtaMinutes, 1) : nil
        remainingMinutes = isCurrent && trip.phase == .inTrip ? max(env.trips.remainingTripMinutes, 1) : nil
        date = trip.createdAt
        isLive = trip.phase.isLive
        destination = PlaceEntity(trip.destination)
    }

    @MainActor
    private static func statusText(_ trip: Trip, env: AppEnvironment) -> String {
        let isCurrent = env.trips.activeTrip?.id == trip.id
        switch trip.phase {
        case .searching: return "Finding a driver"
        case .noDrivers: return "No drivers nearby"
        case .driverAssigned: return isCurrent ? "Driver arriving in \(max(env.trips.driverEtaMinutes, 1)) min" : "Driver on the way"
        case .driverArrived: return "Driver has arrived"
        case .inTrip: return isCurrent ? "\(max(env.trips.remainingTripMinutes, 1)) min remaining" : "In progress"
        case .completed, .paymentPending: return "Awaiting payment"
        case .paymentConfirmed: return "Paid"
        case .rated: return "Completed"
        case .cancelled: return "Cancelled"
        }
    }

    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(exporting: { entity in
            var lines = ["Zuri ride \(entity.id) to \(entity.destinationName) from \(entity.pickupName)", entity.status]
            if let driverName = entity.driverName { lines.append("Driver: \(driverName)") }
            if let vehicle = entity.vehicle, let plate = entity.plate { lines.append("\(vehicle) · \(plate)") }
            lines.append("Fare: \(Format.tzs(entity.fare))")
            return lines.joined(separator: "\n")
        })
    }
}

/// Finds trips by id or by destination name; suggests the live trip first, then recent history.
nonisolated struct TripQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [TripEntity] {
        let env = try IntentEnvironment.resolve()
        return identifiers.compactMap { id in
            if let active = env.trips.activeTrip, active.id == id { return TripEntity(active, env: env) }
            return env.store.trip(id: id).map { TripEntity($0, env: env) }
        }
    }

    @MainActor
    func entities(matching string: String) async throws -> [TripEntity] {
        let env = try IntentEnvironment.resolve()
        let needle = string.lowercased()
        var trips: [Trip] = []
        if let active = env.trips.activeTrip { trips.append(active) }
        trips += env.store.history
        return trips
            .filter { $0.destination.name.lowercased().contains(needle) || $0.id.lowercased().contains(needle) }
            .map { TripEntity($0, env: env) }
    }

    @MainActor
    func suggestedEntities() async throws -> [TripEntity] {
        let env = try IntentEnvironment.resolve()
        var trips: [Trip] = []
        if let active = env.trips.activeTrip { trips.append(active) }
        trips += env.store.history.prefix(5)
        return trips.map { TripEntity($0, env: env) }
    }
}

// MARK: - Driver

/// A favourite driver, for "book Hassan again" and on-screen questions about the assigned driver.
nonisolated struct DriverEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Driver")
    static let defaultQuery = DriverQuery()

    var id: String

    @Property(title: "Name")
    var name: String

    @Property(title: "Ride type")
    var tier: RideTierValue

    @Property(title: "Vehicle")
    var vehicle: String

    @Property(title: "Plate")
    var plate: String

    @Property(title: "Rating")
    var rating: Double

    @Property(title: "Available now")
    var isAvailable: Bool

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(vehicle) · \(plate) · \(isAvailable ? "Online" : "Unavailable")",
            image: .init(systemName: "person.crop.circle")
        )
    }

    init(_ driver: Driver) {
        id = driver.id
        name = driver.name
        tier = RideTierValue(driver.tier)
        vehicle = driver.vehicle.description
        plate = Format.plate(driver.vehicle.plate)
        rating = driver.rating
        isAvailable = driver.isAvailable
    }
}

nonisolated struct DriverQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [DriverEntity] {
        let env = try IntentEnvironment.resolve()
        return env.drivers.drivers(ids: identifiers).map { DriverEntity($0) }
    }

    @MainActor
    func entities(matching string: String) async throws -> [DriverEntity] {
        let env = try IntentEnvironment.resolve()
        let needle = string.lowercased()
        return env.drivers.drivers
            .filter { $0.name.lowercased().contains(needle) }
            .map { DriverEntity($0) }
    }

    @MainActor
    func suggestedEntities() async throws -> [DriverEntity] {
        let env = try IntentEnvironment.resolve()
        return env.drivers.favourites(ids: env.store.favouriteDriverIDs).map { DriverEntity($0) }
    }
}

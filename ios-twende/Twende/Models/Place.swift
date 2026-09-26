import Foundation

/// A resolved location with a display name and address line.
nonisolated struct Place: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    var address: String
    var point: GeoPoint
    /// Kind of venue when known (from Apple Maps); otherwise inferred from the name.
    var category: PlaceCategory?

    init(id: String = UUID().uuidString, name: String, address: String, point: GeoPoint, category: PlaceCategory? = nil) {
        self.id = id
        self.name = name
        self.address = address
        self.point = point
        self.category = category
    }

    var isInServiceZone: Bool {
        DarEsSalaam.isInServiceZone(point)
    }

    /// Icon that tells at a glance what the place is: school, gym, food spot, or the red push pin.
    var icon3D: Icon3D {
        (category ?? PlaceCategory.infer(name: name, address: address))?.icon3D ?? .pin
    }
}

/// Venue types with their own 3D icon.
nonisolated enum PlaceCategory: String, Codable, Hashable, Sendable, CaseIterable {
    case school, gym, sports, food, hospital, cafe, hotel, beach, bus, bank, worship, fuel, bar, airport, shopping

    var icon3D: Icon3D {
        switch self {
        case .school: .school
        case .gym: .gym
        case .sports: .sports
        case .food: .food
        case .hospital: .hospital
        case .cafe: .cafe
        case .hotel: .hotel
        case .beach: .beach
        case .bus: .bus
        case .bank: .bank
        case .worship: .worship
        case .fuel: .fuel
        case .bar: .bar
        case .airport: .plane
        case .shopping: .shoppingBag
        }
    }

    private static let keywords: [(PlaceCategory, [String])] = [
        (.airport, ["airport", "jnia", "terminal 3", "uwanja wa ndege"]),
        (.hospital, ["hospital", "clinic", "hospitali", "zahanati", "medical", "pharmacy", "dispensary"]),
        (.school, ["school", "shule", "university", "chuo", "college", "academy", "udsm"]),
        (.gym, ["gym", "fitness", "crossfit"]),
        (.sports, ["stadium", "uwanja", "sports", "football", "golf", "arena"]),
        (.bus, ["bus", "stendi", "brt", "dart", "ferry", "station"]),
        (.cafe, ["cafe", "café", "coffee", "kahawa"]),
        (.bar, ["bar", "lounge", "club", "pub"]),
        (.food, ["restaurant", "mgahawa", "grill", "kfc", "pizza", "chips", "nyama", "food", "kitchen", "burger"]),
        (.hotel, ["hotel", "lodge", "hoteli", "resort", "inn", "serena", "hyatt"]),
        (.beach, ["beach", "ufukwe"]),
        (.bank, ["bank", "benki", "crdb", "nmb", "atm"]),
        (.worship, ["church", "kanisa", "mosque", "msikiti", "cathedral", "temple", "mandir"]),
        (.fuel, ["petrol", "fuel", "puma", "oryx", "sheli"]),
        (.shopping, ["mall", "market", "soko", "supermarket", "shoppers", "mlimani city", "shop"]),
    ]

    /// Best guess from the name, then the address. Whole-word matches only.
    static func infer(name: String, address: String) -> PlaceCategory? {
        for text in [name, address] {
            let words = Set(text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
            let padded = " " + words.sorted().joined(separator: " ") + " "
            let lower = " " + text.lowercased() + " "
            for (category, keys) in keywords {
                let hit = keys.contains { key in
                    key.contains(" ") ? lower.contains(key) : (words.contains(key) || padded.contains(" " + key + " "))
                }
                if hit { return category }
            }
        }
        return nil
    }
}

/// Saved-place slots shown as chips on Home.
nonisolated enum SavedPlaceKind: String, Codable, CaseIterable, Hashable, Sendable {
    case home
    case work
    case other

    var symbol: String {
        switch self {
        case .home: "house.fill"
        case .work: "briefcase.fill"
        case .other: "mappin.and.ellipse"
        }
    }

    var icon3D: Icon3D {
        switch self {
        case .home: .house
        case .work: .briefcase
        case .other: .pin
        }
    }
}

nonisolated struct SavedPlace: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var kind: SavedPlaceKind
    var label: String
    var place: Place

    init(id: String = UUID().uuidString, kind: SavedPlaceKind, label: String, place: Place) {
        self.id = id
        self.kind = kind
        self.label = label
        self.place = place
    }
}

/// A recent destination with the time it was last used.
nonisolated struct RecentPlace: Codable, Hashable, Identifiable, Sendable {
    var place: Place
    var lastUsed: Date

    var id: String { place.id }
}

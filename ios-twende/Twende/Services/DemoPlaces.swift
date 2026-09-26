import Foundation

/// Well-known Dar es Salaam places used for search suggestions and demo seeding.
nonisolated enum DemoPlaces {
    static let home = Place(
        id: "place-upanga",
        name: "Upanga",
        address: "Ali Hassan Mwinyi Rd, Upanga",
        point: DarEsSalaam.upanga
    )
    static let work = Place(
        id: "place-posta",
        name: "Posta",
        address: "Samora Ave, City Centre",
        point: GeoPoint(latitude: -6.8160, longitude: 39.2900)
    )
    static let mikocheni = Place(
        id: "place-mikocheni",
        name: "Mikocheni",
        address: "Old Bagamoyo Rd, Mikocheni B",
        point: DarEsSalaam.mikocheni
    )
    static let mlimaniCity = Place(
        id: "place-mlimani",
        name: "Mlimani City",
        address: "Sam Nujoma Rd, Ubungo",
        point: GeoPoint(latitude: -6.7717, longitude: 39.2372)
    )
    static let kariakoo = Place(
        id: "place-kariakoo",
        name: "Kariakoo Market",
        address: "Mkunguni St, Kariakoo",
        point: GeoPoint(latitude: -6.8195, longitude: 39.2760)
    )
    static let airport = Place(
        id: "place-jnia",
        name: "JNIA Terminal 3",
        address: "Julius Nyerere International Airport",
        point: GeoPoint(latitude: -6.8781, longitude: 39.2026)
    )
    static let masaki = Place(
        id: "place-masaki",
        name: "Masaki",
        address: "Haile Selassie Rd, Msasani Peninsula",
        point: GeoPoint(latitude: -6.7500, longitude: 39.2790)
    )
    static let ubungo = Place(
        id: "place-ubungo",
        name: "Ubungo Bus Terminal",
        address: "Morogoro Rd, Ubungo",
        point: GeoPoint(latitude: -6.7925, longitude: 39.2115)
    )
    static let kigamboni = Place(
        id: "place-kigamboni",
        name: "Kigamboni Ferry",
        address: "Kivukoni Front, Kigamboni",
        point: GeoPoint(latitude: -6.8290, longitude: 39.3080)
    )
    static let oysterBay = Place(
        id: "place-oysterbay",
        name: "Coco Beach",
        address: "Toure Dr, Oyster Bay",
        point: GeoPoint(latitude: -6.7680, longitude: 39.2780)
    )
    static let muhimbili = Place(
        id: "place-muhimbili",
        name: "Muhimbili National Hospital",
        address: "United Nations Rd, Upanga",
        point: GeoPoint(latitude: -6.8040, longitude: 39.2710)
    )
    static let slipway = Place(
        id: "place-slipway",
        name: "Slipway",
        address: "Yacht Club Rd, Msasani",
        point: GeoPoint(latitude: -6.7535, longitude: 39.2690)
    )
    static let bagamoyo = Place(
        id: "place-bagamoyo",
        name: "Bagamoyo",
        address: "Bagamoyo Town, Pwani",
        point: GeoPoint(latitude: -6.4400, longitude: 38.9000)
    )
    static let morogoro = Place(
        id: "place-morogoro",
        name: "Morogoro",
        address: "Morogoro Town",
        point: GeoPoint(latitude: -6.8200, longitude: 37.6600)
    )

    /// Searchable catalogue, popular first.
    static let catalogue: [Place] = [
        mikocheni, mlimaniCity, kariakoo, airport, masaki, ubungo, kigamboni,
        oysterBay, muhimbili, slipway, work, home, bagamoyo, morogoro,
    ]

    /// Case-insensitive match on name or address, popular ordering preserved.
    static func search(_ query: String) -> [Place] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return Array(catalogue.prefix(6)) }
        return catalogue.filter {
            $0.name.lowercased().contains(needle) || $0.address.lowercased().contains(needle)
        }
    }

    /// Best-effort readable label for a dropped pin. Main-actor because the name is localised.
    @MainActor
    static func label(for point: GeoPoint) -> Place {
        let nearest = catalogue.min { $0.point.distanceKm(to: point) < $1.point.distanceKm(to: point) }
        let distance = nearest.map { $0.point.distanceKm(to: point) } ?? 99
        let name: String
        if let nearest, distance < 1.2 {
            name = L(.nearPlace, nearest.name)
        } else {
            name = L(.droppedPin)
        }
        return Place(
            name: name,
            address: String(format: "%.4f, %.4f", point.latitude, point.longitude),
            point: point
        )
    }
}

/// Past trips so a new account's history screen has content.
nonisolated enum DemoTrips {
    static func history() -> [Trip] {
        let now = Date()
        return [
            make(
                id: "TW-9F2KD",
                daysAgo: 1,
                hour: 18,
                pickup: DemoPlaces.work,
                destination: DemoPlaces.home,
                tier: .economy,
                driverID: MockDrivers.jumaID,
                payment: .cash,
                tip: 0,
                rating: 5
            ),
            make(
                id: "TW-4QX7M",
                daysAgo: 3,
                hour: 8,
                pickup: DemoPlaces.home,
                destination: DemoPlaces.mlimaniCity,
                tier: .bajaji,
                driverID: MockDrivers.barakaID,
                payment: .mpesa,
                tip: 500,
                rating: 4
            ),
            make(
                id: "TW-2HB8P",
                daysAgo: 6,
                hour: 21,
                pickup: DemoPlaces.masaki,
                destination: DemoPlaces.home,
                tier: .comfort,
                driverID: MockDrivers.aminaID,
                payment: .cash,
                tip: 1_000,
                rating: 5
            ),
        ].map { trip in
            var copy = trip
            copy.createdAt = min(copy.createdAt, now)
            return copy
        }
    }

    private static func make(
        id: String,
        daysAgo: Int,
        hour: Int,
        pickup: Place,
        destination: Place,
        tier: RideTier,
        driverID: String,
        payment: PaymentMethod,
        tip: Int,
        rating: Int
    ) -> Trip {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Format.timeZone
        let day = calendar.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date()
        let start = calendar.date(bySettingHour: hour, minute: 12, second: 0, of: day) ?? day
        let route = RoutingService.route(from: pickup.point, to: destination.point)
        let quote = FareEngine.quote(tier: tier, route: route, pickupEtaMinutes: 4, hasDriversNearby: true, promo: nil)
        let end = start.addingTimeInterval(Double(route.durationMinutes + 6) * 60)
        return Trip(
            id: id,
            createdAt: start,
            pickup: pickup,
            destination: destination,
            pickupNote: "",
            tier: tier,
            quote: quote,
            route: route,
            driverID: driverID,
            phase: .rated,
            paymentMethod: payment,
            paymentState: .confirmed,
            promoCode: nil,
            tip: tip,
            rating: rating,
            ratingReasons: [],
            cancellation: nil,
            assignedAt: start.addingTimeInterval(20),
            arrivedAt: start.addingTimeInterval(300),
            startedAt: start.addingTimeInterval(360),
            completedAt: end,
            trafficMinutes: 3,
            preferredDriverID: nil
        )
    }
}

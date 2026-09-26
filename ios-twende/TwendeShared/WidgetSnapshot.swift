import Foundation

/// App Group shared by the app and the widget extension.
nonisolated enum TwendeAppGroup {
    static let identifier = "group.app.rork.emy9ab9spipidt122yz59"
    static let snapshotKey = "twende.widget.snapshot.v2"
    static let snapshotFileName = "widget-snapshot-v2.json"
    static let widgetKind = "TwendeWidget"

    /// Preview installers re-sign the app under a different bundle ID, which can remap the App Group to
    /// `group.<new bundle id>`. Both the app and the widget derive the same candidate from their host bundle ID
    /// and use whichever group the signature actually grants.
    static var candidateIdentifiers: [String] {
        var ids: [String] = []
        if let host = hostBundleIdentifier {
            ids.append("group.\(host)")
        }
        if !ids.contains(identifier) {
            ids.append(identifier)
        }
        return ids
    }

    /// The containing app's bundle ID, also when called from inside the widget extension.
    static var hostBundleIdentifier: String? {
        guard var id = Bundle.main.bundleIdentifier else { return nil }
        if Bundle.main.bundleURL.pathExtension == "appex", let dot = id.lastIndex(of: ".") {
            id = String(id[..<dot])
        }
        return id
    }

    /// The first App Group this signature is entitled to, or nil when the build carries none.
    static let resolvedIdentifier: String? = candidateIdentifiers.first {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) != nil
    }

    /// The shared container, or nil when this build was signed without any usable App Group — in which case
    /// the app and the widget cannot see each other's data and the widget shows its plain launcher.
    static var containerURL: URL? {
        resolvedIdentifier.flatMap { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) }
    }
}

/// Language code the widget renders in. Mirrors the in-app language setting.
nonisolated enum WidgetLanguage: String, Codable, Sendable {
    case swahili = "sw"
    case english = "en"

    /// Best guess before the app has published anything: follow the device.
    static var device: WidgetLanguage {
        Locale.current.language.languageCode?.identifier == "sw" ? .swahili : .english
    }
}

/// A saved or recent destination as the widget shows it.
nonisolated struct WidgetPlace: Codable, Hashable, Identifiable, Sendable {
    /// `home`, `work`, `other` for saved slots, `recent` for history.
    var kind: String
    var id: String
    var label: String
    var detail: String
}

/// Pickup time for one service family measured from the passenger's current pickup point.
nonisolated struct WidgetServiceEta: Codable, Hashable, Identifiable, Sendable {
    /// `ride`, `bajaji`, `boda`.
    var service: String
    /// Localised family name as the app shows it in the service switcher.
    var name: String
    /// Tier whose vehicle illustrates the family: `economy`, `bajaji`, `boda`.
    var tier: String
    /// Nil when no driver of this family is inside the dispatch radius.
    var etaMinutes: Int?

    var id: String { service }
}

/// A coordinate the widget map draws: the pickup, a nearby driver, a route vertex.
nonisolated struct WidgetMapPoint: Codable, Hashable, Sendable {
    var latitude: Double
    var longitude: Double
    /// Vehicle tier for driver markers; nil for pins and route vertices.
    var tier: String?
}

/// Live ride the passenger is on right now.
nonisolated struct WidgetActiveTrip: Codable, Hashable, Sendable {
    var tripID: String
    /// `searching`, `noDrivers`, `driverAssigned`, `driverArrived`, `inTrip`, `completed`.
    var phase: String
    var destination: String
    var pickup: String
    /// Raw tier key: `economy`, `comfort`, `premium`, `bajaji`, `boda`.
    var tier: String
    var tierName: String
    var etaMinutes: Int
    var fare: Int
    var driverFirstName: String?
    var vehicle: String?
    var plate: String?
    var ridePIN: String?
    var progress: Double
    /// Pickup → destination polyline, thinned to a few dozen vertices.
    var routePoints: [WidgetMapPoint]? = nil
    var driverPoint: WidgetMapPoint? = nil
    /// Display name of the rail this ride is charged to, e.g. `M-Pesa`.
    var paymentMethod: String? = nil
}

/// A past trip row.
nonisolated struct WidgetTrip: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var destination: String
    var date: Date
    var amount: Int
    var tier: String
    var tierName: String
    var isCancelled: Bool
}

/// A favourite driver tile.
nonisolated struct WidgetDriver: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var firstName: String
    var tier: String
    var tierName: String
    /// `online`, `busy`, `offline`.
    var status: String
    var rating: Double
}

/// Everything the widget can render, produced by the app and read by the extension.
nonisolated struct WidgetSnapshot: Codable, Sendable {
    var generatedAt: Date
    var language: WidgetLanguage
    var passengerFirstName: String
    var walletBalance: Int
    var monthTrips: Int
    var monthSpend: Int
    var favouritesOnline: Int
    var activeTrip: WidgetActiveTrip?
    var savedPlaces: [WidgetPlace]
    var recentPlaces: [WidgetPlace]
    var recentTrips: [WidgetTrip]
    var favouriteDrivers: [WidgetDriver]
    /// Pickup estimates for Ride / Bajaji / Boda at publish time. Empty once the app has been away long
    /// enough for them to be stale.
    var serviceEtas: [WidgetServiceEta]
    var isDarkMap: Bool
    /// Where a new ride would start, as the Home screen shows it.
    var pickupName: String? = nil
    var pickupPoint: WidgetMapPoint? = nil
    /// Online drivers around the pickup, for the widget map.
    var nearbyDrivers: [WidgetMapPoint]? = nil
    /// Default payment rail display name, e.g. `Cash`, `M-Pesa`.
    var paymentMethod: String? = nil
    /// Raw `PaymentMethod` value, used to pick the icon.
    var paymentKind: String? = nil

    /// The family that can pick the passenger up soonest, if any driver is in range.
    var nearestService: WidgetServiceEta? {
        serviceEtas.filter { $0.etaMinutes != nil }.min { ($0.etaMinutes ?? .max) < ($1.etaMinutes ?? .max) }
    }

    static func empty(language: WidgetLanguage) -> WidgetSnapshot {
        WidgetSnapshot(
            generatedAt: .distantPast,
            language: language,
            passengerFirstName: "",
            walletBalance: 0,
            monthTrips: 0,
            monthSpend: 0,
            favouritesOnline: 0,
            activeTrip: nil,
            savedPlaces: [],
            recentPlaces: [],
            recentTrips: [],
            favouriteDrivers: [],
            serviceEtas: [],
            isDarkMap: false
        )
    }

    /// Representative data for widget galleries and placeholders.
    static let preview = WidgetSnapshot(
        generatedAt: .now,
        language: .english,
        passengerFirstName: "Amina",
        walletBalance: 12_500,
        monthTrips: 7,
        monthSpend: 46_500,
        favouritesOnline: 2,
        activeTrip: WidgetActiveTrip(
            tripID: "TW-7K3M2",
            phase: "driverAssigned",
            destination: "Mlimani City",
            pickup: "Mikocheni B",
            tier: "comfort",
            tierName: "Comfort",
            etaMinutes: 4,
            fare: 9_500,
            driverFirstName: "Hassan",
            vehicle: "Silver Toyota Premio",
            plate: "T 482 DGK",
            ridePIN: "4821",
            progress: 0.42,
            routePoints: [
                WidgetMapPoint(latitude: -6.7630, longitude: 39.2530),
                WidgetMapPoint(latitude: -6.7680, longitude: 39.2490),
                WidgetMapPoint(latitude: -6.7730, longitude: 39.2380),
                WidgetMapPoint(latitude: -6.7710, longitude: 39.2270),
            ],
            driverPoint: WidgetMapPoint(latitude: -6.7580, longitude: 39.2580, tier: "comfort"),
            paymentMethod: "M-Pesa"
        ),
        savedPlaces: [
            WidgetPlace(kind: "home", id: "home", label: "Home", detail: "Mikocheni B"),
            WidgetPlace(kind: "work", id: "work", label: "Work", detail: "Posta, City Centre"),
        ],
        recentPlaces: [
            WidgetPlace(kind: "recent", id: "r1", label: "Julius Nyerere Airport", detail: "Kipawa"),
            WidgetPlace(kind: "recent", id: "r2", label: "Kariakoo Market", detail: "Kariakoo"),
            WidgetPlace(kind: "recent", id: "r3", label: "Slipway", detail: "Msasani"),
        ],
        recentTrips: [
            WidgetTrip(id: "t1", destination: "Kariakoo Market", date: .now.addingTimeInterval(-86_400 * 2), amount: 6_500, tier: "bajaji", tierName: "Bajaji", isCancelled: false),
            WidgetTrip(id: "t2", destination: "Slipway", date: .now.addingTimeInterval(-86_400 * 5), amount: 11_000, tier: "comfort", tierName: "Comfort", isCancelled: false),
            WidgetTrip(id: "t3", destination: "Muhimbili", date: .now.addingTimeInterval(-86_400 * 8), amount: 3_500, tier: "economy", tierName: "Economy", isCancelled: false),
        ],
        favouriteDrivers: [
            WidgetDriver(id: "d1", firstName: "Hassan", tier: "comfort", tierName: "Comfort", status: "busy", rating: 4.9),
            WidgetDriver(id: "d2", firstName: "Neema", tier: "boda", tierName: "Boda", status: "online", rating: 4.8),
            WidgetDriver(id: "d3", firstName: "Juma", tier: "economy", tierName: "Economy", status: "offline", rating: 4.7),
        ],
        serviceEtas: [
            WidgetServiceEta(service: "ride", name: "Ride", tier: "economy", etaMinutes: 4),
            WidgetServiceEta(service: "bajaji", name: "Bajaji", tier: "bajaji", etaMinutes: 6),
            WidgetServiceEta(service: "boda", name: "Boda", tier: "boda", etaMinutes: 3),
        ],
        isDarkMap: false,
        pickupName: "Mikocheni B",
        pickupPoint: WidgetMapPoint(latitude: -6.7630, longitude: 39.2530),
        nearbyDrivers: [
            WidgetMapPoint(latitude: -6.7600, longitude: 39.2560, tier: "economy"),
            WidgetMapPoint(latitude: -6.7665, longitude: 39.2500, tier: "boda"),
            WidgetMapPoint(latitude: -6.7610, longitude: 39.2480, tier: "bajaji"),
            WidgetMapPoint(latitude: -6.7680, longitude: 39.2575, tier: "comfort"),
        ],
        paymentMethod: "M-Pesa",
        paymentKind: "mpesa"
    )
}

/// Reads and writes the snapshot through the App Group container. The JSON file is the primary channel;
/// the shared `UserDefaults` suite is written as well so either side can fall back if the other is unavailable.
nonisolated enum WidgetSnapshotStore {
    /// False when the build has no App Group entitlement, so nothing written here can reach the widget.
    static var isContainerAvailable: Bool { TwendeAppGroup.containerURL != nil }

    private static var fileURL: URL? {
        TwendeAppGroup.containerURL?.appendingPathComponent(TwendeAppGroup.snapshotFileName)
    }

    private static var defaults: UserDefaults? {
        TwendeAppGroup.resolvedIdentifier.flatMap { UserDefaults(suiteName: $0) }
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func load() -> WidgetSnapshot? {
        if let url = fileURL,
           let data = try? Data(contentsOf: url),
           let snapshot = try? decoder.decode(WidgetSnapshot.self, from: data) {
            return snapshot
        }
        guard let data = defaults?.data(forKey: TwendeAppGroup.snapshotKey) else { return nil }
        return try? decoder.decode(WidgetSnapshot.self, from: data)
    }

    /// Returns true when the snapshot landed in the shared container, i.e. the widget will be able to read it.
    @discardableResult
    static func save(_ snapshot: WidgetSnapshot) -> Bool {
        guard let data = try? encoder.encode(snapshot) else { return false }
        var reachedContainer = false
        if let url = fileURL {
            do {
                try data.write(to: url, options: .atomic)
                reachedContainer = true
            } catch {
                print("[WidgetSnapshotStore] container write failed: \(error.localizedDescription)")
            }
        }
        defaults?.set(data, forKey: TwendeAppGroup.snapshotKey)
        return reachedContainer
    }

    static func clear() {
        if let url = fileURL {
            try? FileManager.default.removeItem(at: url)
        }
        defaults?.removeObject(forKey: TwendeAppGroup.snapshotKey)
    }

    /// Where the app drops a rendered PNG of each procedural vehicle so the widget shows the real fleet
    /// rather than a symbol. `nil` when the App Group container is unavailable.
    static func vehicleImageURL(tier: String) -> URL? {
        TwendeAppGroup.containerURL?.appendingPathComponent("vehicle_\(tier).png")
    }

    /// One frame of the low-angle 3D vehicle turntable for the Live Activity. Frame 0 drives away from
    /// the viewer; each step turns the car clockwise, so a quarter turn is the side profile facing right.
    static func vehicleTurntableURL(tier: String, frame: Int) -> URL? {
        TwendeAppGroup.containerURL?.appendingPathComponent("vehicle_turn_\(tier)_\(frame).png")
    }

    /// Straight-down render of the same 3D vehicle, nose pointing right, for the Live Activity route line.
    static func vehicleTopURL(tier: String) -> URL? {
        TwendeAppGroup.containerURL?.appendingPathComponent("vehicle_top3d_\(tier).png")
    }

    /// Number of turntable frames the app exports per tier.
    static let vehicleTurntableFrames: Int = 16

    /// The assigned driver's portrait, exported by the app for the Live Activity.
    static func driverPortraitURL(id: String) -> URL? {
        TwendeAppGroup.containerURL?.appendingPathComponent("driver_\(id).png")
    }
}

/// Deep links the widget hands to the app.
nonisolated enum WidgetLink {
    static let scheme = "zuri"

    static func place(_ id: String) -> URL { URL(string: "\(scheme)://place/\(id)") ?? home }
    static func trip(_ id: String) -> URL { URL(string: "\(scheme)://trip/\(id)") ?? home }
    static func driver(_ id: String) -> URL { URL(string: "\(scheme)://driver/\(id)") ?? home }
    static let activeTrip = URL(string: "\(scheme)://active") ?? home
    static let wallet = URL(string: "\(scheme)://wallet") ?? home
    static let search = URL(string: "\(scheme)://search") ?? home
    static let history = URL(string: "\(scheme)://history") ?? home
    static let home = URL(string: "zuri://home")!
}

/// Copy the widget needs, in both product languages, without depending on the app's string tables.
nonisolated enum WidgetCopy {
    static func text(_ key: Key, _ language: WidgetLanguage) -> String {
        switch (key, language) {
        case (.whereTo, .swahili): "Unaenda wapi?"
        case (.whereTo, .english): "Where to?"
        case (.searchDestination, .swahili): "Tafuta unakoenda"
        case (.searchDestination, .english): "Search a destination"
        case (.wallet, .swahili): "Pochi"
        case (.wallet, .english): "Wallet"
        case (.topUp, .swahili): "Weka salio"
        case (.topUp, .english): "Top up"
        case (.recent, .swahili): "Za karibuni"
        case (.recent, .english): "Recent"
        case (.noRecents, .swahili): "Safari yako ya kwanza itaonekana hapa"
        case (.noRecents, .english): "Your first destination will appear here"
        case (.myDrivers, .swahili): "Madereva wangu"
        case (.myDrivers, .english): "My drivers"
        case (.pastTrips, .swahili): "Safari zilizopita"
        case (.pastTrips, .english): "Past trips"
        case (.thisMonth, .swahili): "Mwezi huu"
        case (.thisMonth, .english): "This month"
        case (.trips, .swahili): "safari"
        case (.trips, .english): "trips"
        case (.online, .swahili): "mtandaoni"
        case (.online, .english): "online"
        case (.busy, .swahili): "ana abiria"
        case (.busy, .english): "on a trip"
        case (.offline, .swahili): "hayupo"
        case (.offline, .english): "offline"
        case (.searching, .swahili): "Tunatafuta dereva…"
        case (.searching, .english): "Finding your driver…"
        case (.noDrivers, .swahili): "Hakuna madereva karibu"
        case (.noDrivers, .english): "No drivers nearby"
        case (.noDriversShort, .swahili): "hakuna"
        case (.noDriversShort, .english): "none"
        case (.arrivingIn, .swahili): "Anafika baada ya"
        case (.arrivingIn, .english): "Arriving in"
        case (.driverArrived, .swahili): "Dereva amefika"
        case (.driverArrived, .english): "Your driver is here"
        case (.onTheWay, .swahili): "Unaelekea"
        case (.onTheWay, .english): "Heading to"
        case (.remaining, .swahili): "zimebaki"
        case (.remaining, .english): "remaining"
        case (.tripComplete, .swahili): "Safari imekamilika"
        case (.tripComplete, .english): "Trip complete"
        case (.min, .swahili): "dak"
        case (.min, .english): "min"
        case (.startCode, .swahili): "Nambari ya kuanza"
        case (.startCode, .english): "Start code"
        case (.goodMorning, .swahili): "Habari za asubuhi"
        case (.goodMorning, .english): "Good morning"
        case (.goodAfternoon, .swahili): "Habari za mchana"
        case (.goodAfternoon, .english): "Good afternoon"
        case (.goodEvening, .swahili): "Habari za jioni"
        case (.goodEvening, .english): "Good evening"
        case (.addHome, .swahili): "Weka nyumbani"
        case (.addHome, .english): "Add home"
        case (.addWork, .swahili): "Weka kazini"
        case (.addWork, .english): "Add work"
        case (.openApp, .swahili): "Fungua Zuri ili kuanza"
        case (.openApp, .english): "Open Zuri to get started"
        case (.openToConnect, .swahili): "Fungua Zuri mara moja na wijeti hii itajaa na safari zako, pochi na madereva wako."
        case (.openToConnect, .english): "Open Zuri once and this widget fills in with your rides, wallet and drivers."
        case (.openZuri, .swahili): "Fungua Zuri"
        case (.openZuri, .english): "Open Zuri"
        case (.cancelled, .swahili): "Imeghairiwa"
        case (.cancelled, .english): "Cancelled"
        case (.noTrips, .swahili): "Hakuna safari bado"
        case (.noTrips, .english): "No trips yet"
        case (.seeAll, .swahili): "Zote"
        case (.seeAll, .english): "See all"
        case (.activity, .swahili): "Shughuli"
        case (.activity, .english): "Activity"
        case (.savedPlaces, .swahili): "Sehemu zilizohifadhiwa"
        case (.savedPlaces, .english): "Saved places"
        case (.request, .swahili): "Omba"
        case (.request, .english): "Request"
        case (.bookAgain, .swahili): "Safiri tena"
        case (.bookAgain, .english): "Book again"
        case (.lookFor, .swahili): "Tafuta gari"
        case (.lookFor, .english): "Look for"
        case (.meetAt, .swahili): "Kutana"
        case (.meetAt, .english): "Meet at"
        case (.to, .swahili): "Kwenda"
        case (.to, .english): "To"
        case (.driversNearby, .swahili): "Madereva karibu nawe"
        case (.driversNearby, .english): "Drivers near you"
        case (.payWith, .swahili): "Lipa kwa"
        case (.payWith, .english): "Pay with"
        case (.pickup, .swahili): "Kuchukuliwa"
        case (.pickup, .english): "Pickup"
        case (.cash, .swahili): "Taslimu"
        case (.cash, .english): "Cash"
        }
    }

    enum Key {
        case whereTo, searchDestination, wallet, topUp, recent, noRecents, myDrivers, pastTrips, thisMonth, trips
        case online, busy, offline
        case searching, noDrivers, noDriversShort, arrivingIn, driverArrived, onTheWay, remaining, tripComplete, min, startCode
        case goodMorning, goodAfternoon, goodEvening, addHome, addWork, openApp, openToConnect, openZuri, cancelled, noTrips, seeAll
        case activity, savedPlaces, request, bookAgain, lookFor, meetAt, to, driversNearby
        case payWith, pickup, cash
    }

    /// `3 nearby` / `3 karibu`.
    static func nearby(_ count: Int, _ language: WidgetLanguage) -> String {
        language == .swahili ? "\(count) karibu" : "\(count) nearby"
    }

    /// Payment rail name in the widget's language; only Cash needs translating, the rest are brands.
    static func payment(_ name: String?, kind: String?, _ language: WidgetLanguage) -> String {
        if kind == "cash" || name == nil { return text(.cash, language) }
        return name ?? text(.cash, language)
    }

    /// `TZS 14,125` — the product-wide currency format.
    static func tzs(_ amount: Int) -> String {
        "TZS " + amount.formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US")))
    }

    /// `4 min` / `dak 4`, matching the app's `minutesShort` copy in each language.
    static func minutes(_ value: Int, _ language: WidgetLanguage) -> String {
        language == .swahili ? "dak \(value)" : "\(value) min"
    }

    /// Greets in the device's local time — the widget lives on the phone the passenger is holding.
    static func greeting(at date: Date, _ language: WidgetLanguage) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        let hour = calendar.component(.hour, from: date)
        switch hour {
        case 5..<12: return text(.goodMorning, language)
        case 12..<17: return text(.goodAfternoon, language)
        default: return text(.goodEvening, language)
        }
    }
}

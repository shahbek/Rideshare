import AppIntents
import Foundation
import UniformTypeIdentifiers

// Actions Siri can fill from what Zuri is showing (iOS 27 on-screen awareness): "this driver", "this ride",
// "this place", "this receipt". Each also works by name from Siri and as a Shortcuts block on iOS 18+, and
// none of them opens the app except calling the driver, which hands off to the Phone app.

// MARK: - Drivers

/// "Add this driver to my drivers" / "Save Hassan" — on the pickup panel or a driver's page.
struct FavouriteDriverIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Driver to My Drivers"
    static let description = IntentDescription("Saves the driver you are looking at so you can request them directly later.")

    @Parameter(title: "Driver", requestValueDialog: "Which driver?")
    var driver: DriverEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$driver) to my drivers")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let env = try IntentEnvironment.resolve()
        guard env.drivers.driver(id: driver.id) != nil else { throw TwendeIntentError.driverNotFound }
        if env.store.isFavourite(driver.id) {
            return .result(dialog: "\(driver.firstName) is already one of your drivers.")
        }
        env.store.addFavourite(driver.id)
        WidgetBridge.publishNow(env)
        WidgetBridge.refreshShortcutParameters(force: true)
        return .result(dialog: "Saved. \(driver.firstName) is now in My drivers.")
    }
}

/// "Get me Neema with Zuri" — books a ride aimed at one of your drivers, asking where to go.
struct RequestDriverIntent: AppIntent {
    static let title: LocalizedStringResource = "Request This Driver"
    static let description = IntentDescription("Requests a ride with one of your drivers to the destination you name.")

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    @Parameter(title: "Driver", requestValueDialog: "Which driver?")
    var driver: DriverEntity

    @Parameter(title: "Destination", requestValueDialog: "Where should they take you?")
    var destination: PlaceEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Request \(\.$driver) to \(\.$destination)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<TripEntity> & ProvidesDialog {
        let env = try IntentEnvironment.resolve()
        guard let live = env.drivers.driver(id: driver.id) else { throw TwendeIntentError.driverNotFound }
        guard !env.trips.hasLiveTrip else { throw TwendeIntentError.tripAlreadyLive }
        guard live.status == .online else { throw TwendeIntentError.driverUnavailable(live.firstName) }
        let trip = try RideBookingService.request(to: destination.place, tier: live.tier, preferredDriverID: live.id, env: env)
        return .result(
            value: TripEntity(trip, env: env),
            dialog: "Asking \(live.firstName) to take you to \(destination.name) for \(Format.tzs(trip.fare))."
        )
    }
}

/// "Tell me when Juma is online" — on an offline driver's row or page.
struct NotifyWhenOnlineIntent: AppIntent {
    static let title: LocalizedStringResource = "Notify Me When Driver Is Online"
    static let description = IntentDescription("Turns on a notification for when one of your drivers comes online.")

    @Parameter(title: "Driver", requestValueDialog: "Which driver?")
    var driver: DriverEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Notify me when \(\.$driver) is online")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let env = try IntentEnvironment.resolve()
        guard env.drivers.driver(id: driver.id) != nil else { throw TwendeIntentError.driverNotFound }
        env.store.addFavourite(driver.id)
        env.store.setNotifyWhenOnline(driver.id, enabled: true)
        return .result(dialog: "I'll let you know when \(driver.firstName) is online.")
    }
}

// MARK: - Places

/// "Save this as Work" — on a search result, a recent row or the confirm-pickup screen.
struct SavePlaceIntent: AppIntent {
    static let title: LocalizedStringResource = "Save Place"
    static let description = IntentDescription("Saves a place as Home, Work or a custom label for one-tap booking.")

    @Parameter(title: "Place", requestValueDialog: "Which place?")
    var place: PlaceEntity

    @Parameter(title: "Save as", default: .other)
    var kind: SavedPlaceKindValue

    @Parameter(title: "Label")
    var label: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Save \(\.$place) as \(\.$kind)") {
            \.$label
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let env = try IntentEnvironment.resolve()
        guard place.place.isInServiceZone else { throw TwendeIntentError.outOfZone(place.name) }
        let resolvedLabel: String
        switch kind {
        case .home: resolvedLabel = L(.homeLabel)
        case .work: resolvedLabel = L(.workLabel)
        case .other: resolvedLabel = (label?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 } ?? place.name
        }
        let existing = kind == .other ? nil : env.store.savedPlace(kind: kind.kind)?.id
        env.store.upsertSavedPlace(id: existing, kind: kind.kind, label: resolvedLabel, place: place.place)
        WidgetBridge.publishNow(env)
        WidgetBridge.refreshShortcutParameters(force: true)
        return .result(dialog: "Saved \(place.name) as \(resolvedLabel).")
    }
}

/// "Add a stop here" / "Stop at Kariakoo on the way" — while choosing a ride or confirming pickup.
struct AddStopIntent: AppIntent {
    static let title: LocalizedStringResource = "Add a Stop"
    static let description = IntentDescription("Adds a stop before the destination of the ride you are setting up and re-quotes the fare.")

    @Parameter(title: "Stop", requestValueDialog: "Where should we stop?")
    var stop: PlaceEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Add a stop at \(\.$stop)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let env = try IntentEnvironment.resolve()
        guard let destination = env.flow.destination, !env.trips.hasLiveTrip else { throw TwendeIntentError.noBookingInProgress }
        guard stop.place.isInServiceZone else { throw TwendeIntentError.outOfZone(stop.name) }
        guard env.flow.canAddStop else { throw TwendeIntentError.tooManyStops }
        env.flow.add(stop: stop.place)
        return .result(dialog: "Added a stop at \(stop.name) on the way to \(destination.name). The fares are updated.")
    }
}

// MARK: - Trips

/// "Share this receipt" / "Send this receipt to Amina" — on a receipt or history row. Returns a PDF file.
struct ShareReceiptIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Receipt"
    static let description = IntentDescription("Produces the PDF receipt for a trip so you can share, print or file it.")

    @Parameter(title: "Trip", requestValueDialog: "Which trip?")
    var trip: TripEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Get the receipt for \(\.$trip)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> & ProvidesDialog {
        let env = try IntentEnvironment.resolve()
        guard let stored = env.store.trip(id: trip.id) else { throw TwendeIntentError.tripNotFound }
        let driver = env.drivers.driver(id: stored.driverID)
        guard let url = ReceiptRenderer.render(trip: stored, driver: driver, language: env.settings.language),
              let data = try? Data(contentsOf: url) else {
            throw TwendeIntentError.receiptUnavailable
        }
        let file = IntentFile(data: data, filename: "Zuri-\(stored.id).pdf", type: .pdf)
        return .result(value: file, dialog: "Here is your receipt for \(trip.destinationName), \(Format.tzs(trip.fare)).")
    }
}

// MARK: - The ride in progress

/// "Share my ride with Amina" / "Send this to my sister" — a plain-text trip card Siri can drop into
/// Messages or WhatsApp: where you are going, the car, plate, and when you should arrive.
struct ShareRideIntent: AppIntent {
    static let title: LocalizedStringResource = "Share My Ride"
    static let description = IntentDescription("Writes a short message with your destination, driver, car, plate and arrival time so someone can follow your ride.")

    @Parameter(title: "Trip")
    var trip: TripEntity?

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let env = try IntentEnvironment.resolve()
        guard let active = env.trips.activeTrip, active.phase.isLive else { throw TwendeIntentError.noActiveTrip }
        if let trip, trip.id != active.id { throw TwendeIntentError.noActiveTrip }
        let entity = TripEntity(active, env: env)
        var lines = ["I'm on a Zuri ride from \(entity.pickupName) to \(entity.destinationName)."]
        if let driver = entity.driverName, let vehicle = entity.vehicle, let plate = entity.plate {
            lines.append("Driver: \(driver), \(vehicle), plate \(plate).")
        }
        if let minutes = entity.remainingMinutes, active.phase == .inTrip {
            let arrival = Date().addingTimeInterval(TimeInterval(minutes * 60)).formatted(date: .omitted, time: .shortened)
            lines.append("Arriving around \(arrival).")
        } else if let minutes = entity.pickupEtaMinutes {
            lines.append("Pickup in about \(minutes) min.")
        }
        let message = lines.joined(separator: " ")
        return .result(value: message, dialog: IntentDialog(stringLiteral: message))
    }
}

/// "Call my driver" / "Call him" — while the driver is on the way. Hands off to the Phone app.
struct CallDriverIntent: AppIntent {
    static let title: LocalizedStringResource = "Call My Driver"
    static let description = IntentDescription("Calls the driver assigned to your ride.")

    @MainActor
    func perform() async throws -> some IntentResult & OpensIntent & ProvidesDialog {
        let env = try IntentEnvironment.resolve()
        guard let trip = env.trips.activeTrip, trip.phase.isLive, let driver = env.trips.assignedDriver else {
            throw TwendeIntentError.noDriverYet
        }
        let digits = driver.phone.filter { $0.isNumber || $0 == "+" }
        guard let url = URL(string: "tel://\(digits)") else { throw TwendeIntentError.driverNotFound }
        return .result(opensIntent: OpenURLIntent(url), dialog: "Calling \(driver.firstName).")
    }
}

/// "Tip 1,000 shillings" / "Give Neema a tip" — on the end-of-ride sheet, before paying.
struct TipDriverIntent: AppIntent {
    static let title: LocalizedStringResource = "Tip My Driver"
    static let description = IntentDescription("Adds a tip to the ride you just finished. The whole tip goes to the driver.")

    @Parameter(title: "Amount (TZS)", inclusiveRange: (0, 20_000), requestValueDialog: "How much would you like to tip?")
    var amount: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Tip \(\.$amount) shillings")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let env = try IntentEnvironment.resolve()
        guard let trip = env.trips.activeTrip, trip.phase == .completed else { throw TwendeIntentError.nothingToTip }
        let name = env.trips.assignedDriver?.firstName ?? "your driver"
        env.trips.setTip(amount)
        let total = env.trips.activeTrip?.totalDue ?? trip.fare
        if amount == 0 {
            return .result(dialog: "Tip removed. You'll pay \(Format.tzs(total)).")
        }
        return .result(dialog: "Added a \(Format.tzs(amount)) tip for \(name). You'll pay \(Format.tzs(total)).")
    }
}

/// "Rate this five stars" — once the ride is paid. Five stars can also save the driver to My drivers.
struct RateRideIntent: AppIntent {
    static let title: LocalizedStringResource = "Rate My Ride"
    static let description = IntentDescription("Rates the ride you just paid for, from one to five stars.")

    @Parameter(title: "Stars", inclusiveRange: (1, 5), requestValueDialog: "How many stars, one to five?")
    var stars: Int

    @Parameter(title: "Add driver to My drivers", default: false)
    var saveDriver: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Rate my ride \(\.$stars) stars") {
            \.$saveDriver
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let env = try IntentEnvironment.resolve()
        guard let trip = env.trips.activeTrip, trip.phase == .paymentConfirmed else { throw TwendeIntentError.nothingToRate }
        let driver = env.trips.assignedDriver
        let alreadySaved = driver.map { env.store.isFavourite($0.id) } ?? true
        env.trips.rate(stars: stars, reasons: [], addFavourite: saveDriver && !alreadySaved)
        WidgetBridge.publishNow(env)
        let who = driver?.firstName ?? "your driver"
        if saveDriver && !alreadySaved {
            return .result(dialog: "Thanks. \(stars) stars for \(who), and \(who) is now in My drivers.")
        }
        return .result(dialog: "Thanks. You gave \(who) \(stars) \(stars == 1 ? "star" : "stars").")
    }
}

/// "How much was this?" / "What's the plate?" — reads back the trip on screen, live or past.
struct TripDetailsIntent: AppIntent {
    static let title: LocalizedStringResource = "Trip Details"
    static let description = IntentDescription("Reads back a trip's fare, driver, car and plate.")

    @Parameter(title: "Trip", requestValueDialog: "Which trip?")
    var trip: TripEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Details of \(\.$trip)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<TripEntity> & ProvidesDialog {
        var line = "\(trip.destinationName) from \(trip.pickupName): \(trip.status), \(Format.tzs(trip.fare))."
        if let driverName = trip.driverName, let vehicle = trip.vehicle, let plate = trip.plate {
            line += " \(driverName), \(vehicle), plate \(plate)."
        }
        return .result(value: trip, dialog: IntentDialog(stringLiteral: line))
    }
}

// MARK: - Supporting enum

/// Home / Work / custom, for `SavePlaceIntent`.
nonisolated enum SavedPlaceKindValue: String, AppEnum {
    case home
    case work
    case other

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Saved Place Type")
    static let caseDisplayRepresentations: [SavedPlaceKindValue: DisplayRepresentation] = [
        .home: DisplayRepresentation(title: "Home", subtitle: "Nyumbani"),
        .work: DisplayRepresentation(title: "Work", subtitle: "Kazini"),
        .other: DisplayRepresentation(title: "Custom label", subtitle: "Any place you visit often")
    ]

    var kind: SavedPlaceKind {
        switch self {
        case .home: .home
        case .work: .work
        case .other: .other
        }
    }
}

extension DriverEntity {
    var firstName: String { name.split(separator: " ").first.map(String.init) ?? name }
}

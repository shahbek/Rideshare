import AppIntents
import Foundation

// MARK: - Step 1: find a place

/// "Where is the airport in Zuri?" — resolves free text to a place Siri can carry into the next step.
struct FindPlaceIntent: AppIntent {
    static let title: LocalizedStringResource = "Find a Place"
    static let description = IntentDescription("Looks up a destination in Dar es Salaam by name, or one of your saved places like Home or Work.")

    @Parameter(title: "Place", requestValueDialog: "Where do you want to go?")
    var query: String

    static var parameterSummary: some ParameterSummary {
        Summary("Find \(\.$query)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<PlaceEntity> & ProvidesDialog {
        let env = try IntentEnvironment.resolve()
        guard let place = await PlaceResolver.search(query, in: env).first else {
            throw TwendeIntentError.placeNotFound(query)
        }
        return .result(value: place, dialog: "\(place.name), \(place.address).")
    }
}

// MARK: - Step 2: quote

/// "How much is a boda to Kariakoo?" — prices every tier (or one) and returns quotes the booking step accepts.
struct GetFareQuoteIntent: AppIntent {
    static let title: LocalizedStringResource = "Get a Fare Quote"
    static let description = IntentDescription("Prices a ride from your current location to a destination. Returns a quote you can book straight away.")

    @Parameter(title: "Destination", requestValueDialog: "Where to?")
    var destination: PlaceEntity

    @Parameter(title: "Ride type")
    var tier: RideTierValue?

    static var parameterSummary: some ParameterSummary {
        Summary("Quote a \(\.$tier) ride to \(\.$destination)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[FareQuoteEntity]> & ProvidesDialog {
        let env = try IntentEnvironment.resolve()
        let quotes = try RideBookingService.quotes(to: destination.place, tier: tier?.tier, env: env)
        let dialog: IntentDialog
        if let tier, let only = quotes.first {
            dialog = only.hasDriversNearby
                ? "A \(RideTierValue.caseDisplayRepresentations[tier]?.title ?? "ride") to \(destination.name) is \(Format.tzs(only.fare)), pickup in about \(only.pickupEtaMinutes) minutes."
                : "A ride to \(destination.name) would be \(Format.tzs(only.fare)), but no \(tier.rawValue) drivers are nearby right now."
        } else if let cheapest = quotes.min(by: { $0.fare < $1.fare }), let fastest = quotes.filter(\.hasDriversNearby).min(by: { $0.pickupEtaMinutes < $1.pickupEtaMinutes }) {
            dialog = "To \(destination.name): from \(Format.tzs(cheapest.fare)) by \(cheapest.tier.rawValue). Fastest pickup is \(fastest.tier.rawValue) in \(fastest.pickupEtaMinutes) minutes."
        } else {
            dialog = "Here are the fares to \(destination.name)."
        }
        return .result(value: quotes, dialog: dialog)
    }
}

// MARK: - Step 3: book

/// "Book it" / "Get me a comfort to work" — starts matching from a quote or from a destination + tier.
struct RequestRideIntent: AppIntent {
    static let title: LocalizedStringResource = "Request a Ride"
    static let description = IntentDescription("Requests a Zuri driver to a destination. Accepts a fare quote from the previous step or a destination and ride type.")
    /// Runs without opening Zuri: Siri speaks the result and the ride appears in the app and widget.
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    @Parameter(title: "Quote")
    var quote: FareQuoteEntity?

    @Parameter(title: "Destination", requestValueDialog: "Where should the ride go?")
    var destination: PlaceEntity?

    @Parameter(title: "Ride type", default: .economy)
    var tier: RideTierValue

    @Parameter(title: "Driver")
    var preferredDriver: DriverEntity?

    static var parameterSummary: some ParameterSummary {
        When(\.$quote, .hasAnyValue) {
            Summary("Book \(\.$quote)")
        } otherwise: {
            Summary("Request a \(\.$tier) ride to \(\.$destination)") {
                \.$preferredDriver
            }
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<TripEntity> & ProvidesDialog {
        let env = try IntentEnvironment.resolve()
        let place: Place
        let chosenTier: RideTier
        if let quote {
            place = quote.destination.place
            chosenTier = quote.tier.tier
        } else if let destination {
            place = destination.place
            chosenTier = preferredDriver?.tier.tier ?? tier.tier
        } else {
            throw $destination.needsValueError("Where should the ride go?")
        }
        let trip = try RideBookingService.request(to: place, tier: chosenTier, preferredDriverID: preferredDriver?.id, env: env)
        let entity = TripEntity(trip, env: env)
        return .result(
            value: entity,
            dialog: "Requesting a \(RideTierValue.caseDisplayRepresentations[RideTierValue(chosenTier)]?.title ?? "ride") to \(place.name) for \(Format.tzs(trip.fare)). I'll find you a driver."
        )
    }
}

/// "Zuri, take me home" / "Take me to work with Zuri" — books the saved Home or Work place in one breath.
/// A fixed Home/Work choice (not a searched place) so Siri always recognises the word, whatever the
/// saved address is called.
struct RideToSavedPlaceIntent: AppIntent {
    static let title: LocalizedStringResource = "Ride Home or to Work"
    static let description = IntentDescription("Requests a Zuri ride to your saved Home or Work place without opening the app.")
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    @Parameter(title: "Place", default: .home)
    var place: SavedDestinationValue

    @Parameter(title: "Ride type", default: .economy)
    var tier: RideTierValue

    static var parameterSummary: some ParameterSummary {
        Summary("Ride to \(\.$place) by \(\.$tier)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<TripEntity> & ProvidesDialog {
        let env = try IntentEnvironment.resolve()
        let label = place == .home ? "Home" : "Work"
        guard let saved = env.store.savedPlaces.first(where: { $0.kind == place.kind }) else {
            throw TwendeIntentError.noSavedPlace(label)
        }
        let trip = try RideBookingService.request(to: saved.place, tier: tier.tier, preferredDriverID: nil, env: env)
        return .result(
            value: TripEntity(trip, env: env),
            dialog: "Requesting a \(RideTierValue.caseDisplayRepresentations[tier]?.title ?? "ride") to \(label) for \(Format.tzs(trip.fare)). I'll find you a driver."
        )
    }
}

/// Home / Work as a closed set, so the phrase parameter never depends on indexed place names.
nonisolated enum SavedDestinationValue: String, AppEnum {
    case home
    case work

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Saved Place")
    static let caseDisplayRepresentations: [SavedDestinationValue: DisplayRepresentation] = [
        .home: DisplayRepresentation(title: "Home", subtitle: "Nyumbani", synonyms: ["my house", "my place", "nyumbani"]),
        .work: DisplayRepresentation(title: "Work", subtitle: "Kazini", synonyms: ["the office", "my office", "kazini"])
    ]

    var kind: SavedPlaceKind {
        switch self {
        case .home: .home
        case .work: .work
        }
    }
}

// MARK: - Step 4: track / act on the live ride

/// "Where's my driver?" — reads the live trip so Siri can answer ETA, plate and start-code questions.
struct CurrentTripIntent: AppIntent {
    static let title: LocalizedStringResource = "Check My Ride"
    static let description = IntentDescription("Tells you where your driver is, the car to look for and your start code.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<TripEntity> & ProvidesDialog {
        let env = try IntentEnvironment.resolve()
        guard let trip = env.trips.activeTrip else { throw TwendeIntentError.noActiveTrip }
        let entity = TripEntity(trip, env: env)
        var line = entity.status + "."
        if let vehicle = entity.vehicle, let plate = entity.plate, let driver = entity.driverName {
            line += " Look for \(driver) in a \(vehicle), plate \(plate)."
        }
        if let pin = entity.ridePIN {
            line += " Your start code is \(pin.map(String.init).joined(separator: " "))."
        }
        return .result(value: entity, dialog: IntentDialog(stringLiteral: line))
    }
}

/// "Cancel my Zuri ride" — confirms the fee first when a driver is already committed.
struct CancelRideIntent: AppIntent {
    static let title: LocalizedStringResource = "Cancel My Ride"
    static let description = IntentDescription("Cancels the ride in progress. Asks before charging a late cancellation fee.")

    @Parameter(title: "Trip")
    var trip: TripEntity?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let env = try IntentEnvironment.resolve()
        guard let active = env.trips.activeTrip, active.phase.isLive else { throw TwendeIntentError.noActiveTrip }
        if let trip, trip.id != active.id { throw TwendeIntentError.cannotCancelNow }
        let fee = env.trips.cancellationFeePreview
        if fee > 0 {
            try await requestConfirmation(
                result: .result(dialog: "Cancelling now carries a \(Format.tzs(fee)) fee because \(env.trips.assignedDriver?.firstName ?? "your driver") is already on the way. Cancel anyway?")
            )
        }
        env.trips.cancel(reason: .changedPlans)
        WidgetBridge.publishNow(env)
        return .result(dialog: fee > 0 ? "Cancelled. A \(Format.tzs(fee)) fee applies." : "Your ride is cancelled — no fee.")
    }
}

/// "Change my destination to Slipway" — mid-trip re-route, chaining a found place into the live ride.
struct ChangeDestinationIntent: AppIntent {
    static let title: LocalizedStringResource = "Change Destination"
    static let description = IntentDescription("Re-routes the ride in progress to a new destination and re-quotes the fare.")

    @Parameter(title: "New destination", requestValueDialog: "Where should we go instead?")
    var destination: PlaceEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Change destination to \(\.$destination)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<TripEntity> & ProvidesDialog {
        let env = try IntentEnvironment.resolve()
        guard let active = env.trips.activeTrip, active.phase == .inTrip else { throw TwendeIntentError.noActiveTrip }
        guard destination.place.isInServiceZone else { throw TwendeIntentError.outOfZone(destination.name) }
        env.trips.changeDestination(to: destination.place)
        guard let updated = env.trips.activeTrip else { throw TwendeIntentError.noActiveTrip }
        WidgetBridge.publishNow(env)
        return .result(value: TripEntity(updated, env: env), dialog: "Heading to \(destination.name) now. The fare is \(Format.tzs(updated.fare)).")
    }
}

// MARK: - Rebook and open

/// "Book my last trip again" — chains a past trip's destination and tier into a fresh request.
struct RebookTripIntent: AppIntent {
    static let title: LocalizedStringResource = "Book Again"
    static let description = IntentDescription("Requests a ride to the destination of a past trip, using the same ride type.")
    /// Runs without opening Zuri: Siri speaks the result and the ride appears in the app and widget.
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    @Parameter(title: "Trip", requestValueDialog: "Which trip should I book again?")
    var trip: TripEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Book \(\.$trip) again")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<TripEntity> & ProvidesDialog {
        let env = try IntentEnvironment.resolve()
        let requested = try RideBookingService.request(to: trip.destination.place, tier: trip.tier.tier, preferredDriverID: nil, env: env)
        return .result(value: TripEntity(requested, env: env), dialog: "Booking a \(trip.tier.rawValue) to \(trip.destinationName) again for \(Format.tzs(requested.fare)).")
    }
}

/// System-generated "Open <place> in Zuri" — lands on the confirm-pickup screen for that destination.
struct OpenPlaceIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Place"

    @Parameter(title: "Place")
    var target: PlaceEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        let env = try IntentEnvironment.resolve()
        env.flow.closeMenu()
        env.flow.choose(destination: target.place)
        return .result()
    }
}

/// System-generated "Open <trip> in Zuri" — opens the receipt, or the live map for the current ride.
struct OpenTripIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Trip"

    @Parameter(title: "Trip")
    var target: TripEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        let env = try IntentEnvironment.resolve()
        if env.trips.activeTrip?.id == target.id {
            env.flow.closeMenu()
            env.flow.selectedTab = .home
        } else {
            env.flow.openMenu(at: .tripDetail(target.id))
        }
        return .result()
    }
}

// MARK: - Shortcuts

/// Phrases are English only: Siri has no Kiswahili speech model, so Swahili utterances can never match and
/// would only dilute the training set the system builds from these templates. Every phrase carries the app
/// name and at most one parameter, as App Shortcuts require.
struct TwendeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: GetFareQuoteIntent(),
            phrases: [
                "How much is a ride to \(\.$destination) with \(.applicationName)",
                "\(.applicationName) how much to \(\.$destination)",
                "Quote a \(.applicationName) ride to \(\.$destination)",
                "Get a \(.applicationName) fare quote",
                "Get a fare quote from \(.applicationName)",
            ],
            shortTitle: "Fare Quote",
            systemImageName: "banknote"
        )
        AppShortcut(
            intent: RideToSavedPlaceIntent(),
            phrases: [
                "Take me \(\.$place) with \(.applicationName)",
                "Take me to \(\.$place) with \(.applicationName)",
                "\(.applicationName) take me \(\.$place)",
                "\(.applicationName) take me to \(\.$place)",
                "Request a ride to \(\.$place) with \(.applicationName)",
                "Request ride to \(\.$place) with \(.applicationName)",
                "Get me a ride to \(\.$place) with \(.applicationName)",
                "Get me a ride \(\.$place) with \(.applicationName)",
                "Book a \(.applicationName) to \(\.$place)",
                "Book a \(.applicationName) \(\.$place)",
                "\(.applicationName) ride \(\.$place)",
                "\(.applicationName) ride to \(\.$place)",
            ],
            shortTitle: "Home or Work",
            systemImageName: "house.fill"
        )
        AppShortcut(
            intent: RequestRideIntent(),
            phrases: [
                "Get me a ride to \(\.$destination) with \(.applicationName)",
                "\(.applicationName) take me to \(\.$destination)",
                "Take me to \(\.$destination) with \(.applicationName)",
                "Request a ride to \(\.$destination) with \(.applicationName)",
                "Request ride to \(\.$destination) with \(.applicationName)",
                "Book a \(.applicationName) to \(\.$destination)",
                "Request a \(.applicationName) ride",
                "Request a ride with \(.applicationName)",
                "Book a ride with \(.applicationName)",
                "Get me a \(.applicationName)",
            ],
            shortTitle: "Request Ride",
            systemImageName: "car.fill"
        )
        AppShortcut(
            intent: CurrentTripIntent(),
            phrases: [
                "Where is my \(.applicationName) driver",
                "Where is my \(.applicationName)",
                "Check my \(.applicationName) ride",
                "What is my \(.applicationName) start code",
            ],
            shortTitle: "Check My Ride",
            systemImageName: "location.fill"
        )
        AppShortcut(
            intent: CancelRideIntent(),
            phrases: [
                "Cancel my \(.applicationName) ride",
                "Cancel my \(.applicationName)",
            ],
            shortTitle: "Cancel Ride",
            systemImageName: "xmark.circle"
        )
        AppShortcut(
            intent: RebookTripIntent(),
            phrases: [
                "Book my last \(.applicationName) trip again",
                "Repeat my last \(.applicationName) ride",
            ],
            shortTitle: "Book Again",
            systemImageName: "arrow.clockwise"
        )
        AppShortcut(
            intent: RequestDriverIntent(),
            phrases: [
                "Request \(\.$driver) with \(.applicationName)",
                "\(.applicationName) get me \(\.$driver)",
            ],
            shortTitle: "Request Driver",
            systemImageName: "person.fill.checkmark"
        )
        AppShortcut(
            intent: ShareRideIntent(),
            phrases: [
                "Share my \(.applicationName) ride",
                "Send my \(.applicationName) trip details",
            ],
            shortTitle: "Share Ride",
            systemImageName: "square.and.arrow.up"
        )
        AppShortcut(
            intent: CallDriverIntent(),
            phrases: [
                "Call my \(.applicationName) driver",
                "Phone my \(.applicationName) driver",
            ],
            shortTitle: "Call Driver",
            systemImageName: "phone.fill"
        )
        AppShortcut(
            intent: ShareReceiptIntent(),
            phrases: [
                "Get my last \(.applicationName) receipt",
                "Show my last \(.applicationName) receipt",
            ],
            shortTitle: "Get Receipt",
            systemImageName: "doc.text"
        )
    }

    static let shortcutTileColor: ShortcutTileColor = .orange
}

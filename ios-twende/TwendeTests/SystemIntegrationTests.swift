import AppIntents
import XCTest
@testable import Twende

/// Widget snapshot, deep links and the Siri booking chain.
@MainActor
final class SystemIntegrationTests: XCTestCase {
    private func makeEnvironment() -> AppEnvironment {
        UserDefaults.standard.removeObject(forKey: Persistence.Key.activeTrip)
        let env = AppEnvironment()
        if env.store.profile == nil {
            env.store.createProfile(name: "Amina Juma", phone: "0712345678", email: "")
        }
        IntentEnvironment.register(env)
        return env
    }

    func testWidgetSnapshotRoundTripsThroughTheAppGroupAndMirrorsPassengerState() throws {
        let env = makeEnvironment()
        let snapshot = WidgetBridge.snapshot(for: env)
        XCTAssertEqual(snapshot.passengerFirstName, env.store.firstName)
        XCTAssertEqual(snapshot.walletBalance, env.store.walletBalance)
        XCTAssertEqual(snapshot.savedPlaces.count, env.store.savedPlaces.count)
        XCTAssertEqual(snapshot.recentTrips.count, min(env.store.history.count, 6))
        XCTAssertNil(snapshot.activeTrip)

        // Pickup times mirror the Home service switcher: one entry per family, a number only where a
        // driver of that family is inside the dispatch radius.
        XCTAssertEqual(snapshot.serviceEtas.map(\.service), ServiceFamily.allCases.map(\.rawValue))
        for eta in snapshot.serviceEtas {
            let family = try XCTUnwrap(ServiceFamily(rawValue: eta.service))
            let available = env.drivers.hasDriversNearby(tier: family.defaultTier, near: env.flow.pickup.point)
            XCTAssertEqual(eta.etaMinutes != nil, available, "\(eta.service) availability must match the fleet")
            XCTAssertEqual(eta.tier, family.defaultTier.rawValue)
        }

        WidgetSnapshotStore.clear()
        let reachedWidget = WidgetSnapshotStore.save(snapshot)
        // The simulator may not provision the App Group; when it does, the snapshot must decode identically
        // and the store must report that the widget can see it.
        if let loaded = WidgetSnapshotStore.load() {
            XCTAssertTrue(reachedWidget || !WidgetSnapshotStore.isContainerAvailable)
            XCTAssertEqual(loaded.walletBalance, snapshot.walletBalance)
            XCTAssertEqual(loaded.savedPlaces, snapshot.savedPlaces)
            XCTAssertEqual(loaded.serviceEtas, snapshot.serviceEtas)
        }
        XCTAssertEqual(WidgetCopy.tzs(14_125), "TZS 14,125")
        XCTAssertEqual(WidgetCopy.minutes(4, .english), "4 min")
        XCTAssertEqual(WidgetCopy.minutes(4, .swahili), "dak 4")
    }

    func testWidgetEmptyStateNeverInventsNumbers() {
        let empty = WidgetSnapshot.empty(language: .english)
        XCTAssertNil(empty.nearestService)
        XCTAssertTrue(empty.serviceEtas.isEmpty)
        XCTAssertTrue(empty.recentTrips.isEmpty)

        var withEtas = empty
        withEtas.serviceEtas = [
            WidgetServiceEta(service: "ride", name: "Ride", tier: "economy", etaMinutes: 6),
            WidgetServiceEta(service: "bajaji", name: "Bajaji", tier: "bajaji", etaMinutes: nil),
            WidgetServiceEta(service: "boda", name: "Boda", tier: "boda", etaMinutes: 3),
        ]
        XCTAssertEqual(withEtas.nearestService?.service, "boda")
    }

    func testIntentEnvironmentIsAvailableWithoutAScene() throws {
        // Siri launches the app in the background to run intents; the composition root must be reachable
        // from the App struct's initialiser path, not only after a view appears.
        let env = makeEnvironment()
        let resolved = try IntentEnvironment.resolve()
        XCTAssertTrue(resolved.settings.isOnboarded)
        XCTAssertIdentical(resolved, env)
    }

    func testSiriChainFindsQuotesAndBooksARideThenReadsItBackOffScreen() async throws {
        let env = makeEnvironment()
        env.trips.activeTrip.map { _ in env.trips.cancel(reason: .changedPlans) }

        let found = try await FindPlaceIntent(query: "airport").perform()
        let place = found.value
        XCTAssertEqual(place?.name, DemoPlaces.airport.name)

        var quoteIntent = GetFareQuoteIntent()
        quoteIntent.destination = try XCTUnwrap(place)
        let quotes = try await quoteIntent.perform().value ?? []
        XCTAssertEqual(quotes.count, RideTier.allCases.count)
        XCTAssertTrue(quotes.allSatisfy { $0.fare > 0 })

        let bookable = try XCTUnwrap(quotes.first(where: \.hasDriversNearby))
        var request = RequestRideIntent()
        request.quote = bookable
        let trip = try await request.perform().value
        XCTAssertEqual(trip?.destinationName, DemoPlaces.airport.name)
        XCTAssertEqual(env.trips.activeTrip?.tier, bookable.tier.tier)
        XCTAssertTrue(env.trips.hasLiveTrip)

        let current = try await CurrentTripIntent().perform().value
        XCTAssertEqual(current?.id, env.trips.activeTrip?.id)

        // A second booking must be refused while one is live.
        var again = RequestRideIntent()
        again.destination = place
        do {
            _ = try await again.perform()
            XCTFail("second booking should be rejected")
        } catch let error as TwendeIntentError {
            guard case .tripAlreadyLive = error else { return XCTFail("unexpected \(error)") }
        }

        let widget = WidgetBridge.snapshot(for: env)
        XCTAssertEqual(widget.activeTrip?.destination, DemoPlaces.airport.name)
        env.trips.cancel(reason: .changedPlans)
    }

    func testDeepLinksFromTheWidgetLandOnTheRightScreen() throws {
        let env = makeEnvironment()
        if env.trips.activeTrip != nil { env.trips.cancel(reason: .changedPlans) }
        DeepLinkRouter.handle(WidgetLink.wallet, env: env)
        XCTAssertTrue(env.flow.isMenuPresented)
        XCTAssertEqual(env.flow.menuNavigation.path, [.wallet])

        let saved = try XCTUnwrap(env.store.savedPlaces.first)
        DeepLinkRouter.handle(WidgetLink.place(saved.id), env: env)
        XCTAssertFalse(env.flow.isMenuPresented)
        XCTAssertEqual(env.flow.destination, saved.place)
        XCTAssertEqual(env.flow.path, [.search, .confirmPickup])

        let past = try XCTUnwrap(env.store.history.first)
        DeepLinkRouter.handle(WidgetLink.trip(past.id), env: env)
        XCTAssertEqual(env.flow.menuNavigation.path, [.tripDetail(past.id)])
        env.flow.resetToHome()
    }

    func testEveryTierMapsToASiriValueAndBack() {
        for tier in RideTier.allCases {
            XCTAssertEqual(RideTierValue(tier).tier, tier)
            XCTAssertNotNil(RideTierValue.caseDisplayRepresentations[RideTierValue(tier)])
        }
    }
}

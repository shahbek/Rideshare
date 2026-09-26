import Foundation

/// Booking primitives shared by Siri intents and deep links, so both take the exact path the UI does.
enum RideBookingService {
    /// Quotes every tier (or one) from the passenger's live pickup to `destination`.
    static func quotes(to destination: Place, tier: RideTier?, env: AppEnvironment) throws -> [FareQuoteEntity] {
        guard destination.isInServiceZone else { throw TwendeIntentError.outOfZone(destination.name) }
        let pickup = BookingFlow.pickupPlace(for: env.location.effectivePosition)
        let route = RoutingService.route(from: pickup.point, to: destination.point)
        let tiers = tier.map { [$0] } ?? RideTier.allCases
        return tiers.map { tier in
            let quote = FareEngine.quote(
                tier: tier,
                route: route,
                pickupEtaMinutes: env.drivers.pickupEta(tier: tier, near: pickup.point),
                hasDriversNearby: env.drivers.hasDriversNearby(tier: tier, near: pickup.point),
                promo: nil
            )
            return FareQuoteEntity(quote, pickup: pickup, destination: destination)
        }
    }

    /// Starts matching and returns the new trip. Mirrors `BookingFlow.requestRide` without the screen stack.
    @discardableResult
    static func request(to destination: Place, tier: RideTier, preferredDriverID: String?, env: AppEnvironment) throws -> Trip {
        guard env.trips.activeTrip == nil || env.trips.activeTrip?.isFinished == true else { throw TwendeIntentError.tripAlreadyLive }
        guard destination.isInServiceZone else { throw TwendeIntentError.outOfZone(destination.name) }
        let pickup = BookingFlow.pickupPlace(for: env.location.effectivePosition)
        let route = RoutingService.route(from: pickup.point, to: destination.point)
        let quote = FareEngine.quote(
            tier: tier,
            route: route,
            pickupEtaMinutes: env.drivers.pickupEta(tier: tier, near: pickup.point),
            hasDriversNearby: env.drivers.hasDriversNearby(tier: tier, near: pickup.point),
            promo: nil
        )
        guard quote.hasDriversNearby else { throw TwendeIntentError.noDriversNearby(L(tier.nameKey)) }
        env.flow.closeMenu()
        env.flow.activeSheet = nil
        env.flow.resetToHome()
        env.trips.requestRide(
            pickup: pickup,
            destination: destination,
            pickupNote: "",
            quote: quote,
            route: route,
            paymentMethod: env.store.defaultPaymentMethod,
            promoCode: nil,
            preferredDriverID: preferredDriverID
        )
        WidgetBridge.publishNow(env)
        // Siri bookings run with no scene, so the view-level sync never fires; start the Live Activity here.
        LiveActivityBridge.sync(env)
        guard let trip = env.trips.activeTrip else { throw TwendeIntentError.appNotReady }
        return trip
    }
}

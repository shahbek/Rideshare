import Foundation
import Observation

/// Persisted snapshot of a live trip so a cold start can resume mid-ride.
nonisolated struct ActiveTripSnapshot: Codable, Sendable {
    var trip: Trip
    var driverProgress: Double
    var tripProgress: Double
    var driverPosition: GeoPoint?
    var searchElapsedSeconds: Int
}

/// Demo clock. One quoted minute plays back in `secondsPerMinute` real seconds.
nonisolated enum TripSimulation {
    static let secondsPerMinute = 12.0
    static let tickSeconds = 0.25
    static let searchTimeoutSeconds = 90
    static let noCandidatesFailSeconds = 12
    static let boardingSeconds = 8.0
    static let cancellationGraceSeconds = 120.0
}

/// Owns the trip state machine:
/// searching → noDrivers | driverAssigned → driverArrived → inTrip → completed → paymentPending → paymentConfirmed → rated
/// Any live phase may move to `cancelled`. The coordinator is the only writer of `activeTrip`.
@Observable
final class TripCoordinator {
    private(set) var activeTrip: Trip?
    private(set) var driverPosition: GeoPoint?
    private(set) var driverHeading: Double = 0
    private(set) var searchElapsedSeconds: Int = 0
    private(set) var driverEtaMinutes: Int = 0
    private(set) var remainingTripMinutes: Int = 0
    private(set) var tripProgress: Double = 0
    private(set) var isInTraffic: Bool = false
    /// Set after a cancellation so Home can show a toast with the fee outcome.
    private(set) var lastCancellation: Cancellation?
    /// Set when the trip reaches `rated` or `cancelled` and has been archived.
    private(set) var justArchivedTripID: String?

    private let drivers: DriverService
    private let store: PassengerStore
    private let network: NetworkMonitor
    private let payments: MobileMoneyCoordinator
    /// Plain-language reason for the last failed mobile money ride payment, shown on the completion sheet.
    private(set) var mobileMoneyError: String?

    /// Driver → pickup route while the driver is on the way.
    private(set) var approachRoute: RouteResult?

    private var simulation: Task<Void, Never>?
    private var driverProgress: Double = 0
    private var assignmentDelaySeconds: Int = 5
    private var boardingElapsed: Double = 0
    private var trafficSecondsAccumulated: Double = 0
    private var ticksSincePersist: Int = 0
    private var searchTicks: Int = 0

    init(drivers: DriverService, store: PassengerStore, network: NetworkMonitor, payments: MobileMoneyCoordinator) {
        self.drivers = drivers
        self.store = store
        self.network = network
        self.payments = payments
        restoreIfNeeded()
        payments.onRideSettled = { [weak self] tripID, payment in
            self?.settleMobileMoney(tripID: tripID, payment: payment)
        }
    }

    var phase: TripPhase? { activeTrip?.phase }
    var hasLiveTrip: Bool { activeTrip?.phase.isLive ?? false }
    var isSettling: Bool { activeTrip?.phase.isSettling ?? false }
    var assignedDriver: Driver? { drivers.driver(id: activeTrip?.driverID) }
    /// 0…1 along the driver's approach to the pickup.
    var approachProgress: Double { driverProgress }

    /// Cancelling after the grace period, once a driver is committed, carries a fee.
    var cancellationFeePreview: Int {
        guard let trip = activeTrip, let assignedAt = trip.assignedAt else { return 0 }
        switch trip.phase {
        case .driverAssigned, .driverArrived:
            return Date().timeIntervalSince(assignedAt) > TripSimulation.cancellationGraceSeconds ? trip.tier.lateCancellationFee : 0
        default:
            return 0
        }
    }

    // MARK: Requests

    func requestRide(
        pickup: Place,
        destination: Place,
        stops: [Place] = [],
        pickupNote: String,
        quote: FareQuote,
        route: RouteResult,
        paymentMethod: PaymentMethod,
        promoCode: String?,
        preferredDriverID: String?
    ) {
        stopSimulation()
        let trip = Trip(
            id: Trip.makeReference(),
            createdAt: Date(),
            pickup: pickup,
            destination: destination,
            stops: stops.isEmpty ? nil : stops,
            pickupNote: pickupNote,
            tier: quote.tier,
            quote: quote,
            route: route,
            driverID: nil,
            phase: .searching,
            paymentMethod: paymentMethod,
            paymentState: .notStarted,
            promoCode: promoCode,
            tip: 0,
            rating: nil,
            ratingReasons: [],
            cancellation: nil,
            assignedAt: nil,
            arrivedAt: nil,
            startedAt: nil,
            completedAt: nil,
            trafficMinutes: 0,
            preferredDriverID: preferredDriverID
        )
        activeTrip = trip
        driverPosition = nil
        driverProgress = 0
        tripProgress = 0
        searchElapsedSeconds = 0
        searchTicks = 0
        trafficSecondsAccumulated = 0
        boardingElapsed = 0
        isInTraffic = false
        lastCancellation = nil
        justArchivedTripID = nil
        assignmentDelaySeconds = preferredDriverID == nil ? Int.random(in: 4...8) : 3
        store.addRecent(destination)
        if let promoCode {
            store.markRedeemed(promoCode)
        }
        persist()
        startSimulation()
    }

    /// Restarts matching after a `noDrivers` outcome.
    func retrySearch() {
        guard var trip = activeTrip, trip.phase == .noDrivers else { return }
        trip.phase = .searching
        activeTrip = trip
        searchElapsedSeconds = 0
        searchTicks = 0
        assignmentDelaySeconds = Int.random(in: 4...8)
        persist()
        startSimulation()
    }

    /// Switches tier after `noDrivers`, re-quoting on the same route.
    func retrySearch(with tier: RideTier) {
        guard var trip = activeTrip, trip.phase == .noDrivers else { return }
        let promo = trip.promoCode.flatMap { PromoCatalog.promotion(code: $0) }
        trip.tier = tier
        trip.quote = FareEngine.quote(
            tier: tier,
            route: trip.route,
            pickupEtaMinutes: drivers.pickupEta(tier: tier, near: trip.pickup.point),
            hasDriversNearby: drivers.hasDriversNearby(tier: tier, near: trip.pickup.point),
            promo: promo
        )
        trip.phase = .searching
        activeTrip = trip
        searchElapsedSeconds = 0
        searchTicks = 0
        assignmentDelaySeconds = Int.random(in: 3...6)
        persist()
        startSimulation()
    }

    func cancel(reason: CancelReason) {
        guard var trip = activeTrip, trip.phase.isLive else { return }
        stopSimulation()
        let fee = reason == .driverAskedToCancel ? 0 : cancellationFeePreview
        let cancellation = Cancellation(reason: reason, fee: fee, cancelledByDriver: false, at: Date())
        trip.cancellation = cancellation
        trip.phase = .cancelled
        if let driverID = trip.driverID {
            drivers.setStatus(.online, for: driverID)
        }
        lastCancellation = cancellation
        archive(trip)
    }

    /// Leaves the `noDrivers` screen without booking.
    func abandonSearch() {
        guard var trip = activeTrip, trip.phase == .noDrivers else { return }
        stopSimulation()
        trip.phase = .cancelled
        trip.cancellation = Cancellation(reason: .other, fee: 0, cancelledByDriver: false, at: Date())
        archive(trip)
    }

    func changeDestination(to place: Place) {
        updateRoute(stops: [], destination: place)
    }

    /// Replaces the rest of a live ride with new stops and destination, re-quoting the whole journey.
    /// Before pickup only the legs after the pickup change; during the ride the car heads there next.
    func updateRoute(stops newStops: [Place], destination place: Place) {
        guard var trip = activeTrip, trip.phase.isLive else { return }
        let promo = trip.promoCode.flatMap { PromoCatalog.promotion(code: $0) }
        guard trip.phase == .inTrip, let current = driverPosition else {
            let route = RoutingService.route(through: [trip.pickup.point] + newStops.map(\.point) + [place.point])
            trip.destination = place
            trip.stops = newStops.isEmpty ? nil : newStops
            trip.route = route
            trip.quote = FareEngine.quote(tier: trip.tier, route: route, pickupEtaMinutes: trip.quote.pickupEtaMinutes, hasDriversNearby: true, promo: promo)
            activeTrip = trip
            store.addRecent(place)
            persist()
            return
        }
        let remaining = RoutingService.route(through: [current] + newStops.map(\.point) + [place.point])
        let travelled = tripProgress
        // Re-quote the full journey: distance already driven plus the new remainder.
        let drivenKm = trip.route.distanceKm * travelled
        let drivenMinutes = Int((Double(trip.route.durationMinutes) * travelled).rounded())
        let combined = RouteResult(
            points: remaining.points,
            distanceKm: (drivenKm + remaining.distanceKm).rounded(toPlaces: 1),
            durationMinutes: drivenMinutes + remaining.durationMinutes
        )
        trip.destination = place
        trip.stops = newStops.isEmpty ? nil : newStops
        trip.quote = FareEngine.quote(
            tier: trip.tier,
            route: combined,
            pickupEtaMinutes: trip.quote.pickupEtaMinutes,
            hasDriversNearby: true,
            promo: promo
        )
        trip.route = remaining
        activeTrip = trip
        tripProgress = 0
        store.addRecent(place)
        persist()
    }

    // MARK: Payment

    func setTip(_ amount: Int) {
        guard var trip = activeTrip, trip.phase == .completed else { return }
        trip.tip = max(amount, 0)
        activeTrip = trip
        persist()
    }

    func confirmCashPayment() {
        guard var trip = activeTrip, trip.phase == .completed, trip.paymentMethod == .cash else { return }
        trip.paymentState = .confirmed
        trip.phase = .paymentConfirmed
        activeTrip = trip
        Haptics.success()
        persist()
    }

    /// Sends the network PIN prompt for the ride fare through the payment server. The trip waits in
    /// `paymentPending` until the server reports approval or failure.
    func payWithMobileMoney() {
        guard var trip = activeTrip, trip.phase == .completed || trip.paymentState == .failed,
              trip.paymentMethod.isMobileMoney else { return }
        trip.paymentState = .pending
        trip.phase = .paymentPending
        activeTrip = trip
        mobileMoneyError = nil
        persist()
        let tripID = trip.id, amount = trip.totalDue, method = trip.paymentMethod
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.payments.start(amount: amount, method: method, purpose: .ride, tripID: tripID)
            } catch {
                guard var current = self.activeTrip, current.id == tripID, current.phase == .paymentPending else { return }
                current.paymentState = .failed
                current.phase = .completed
                self.mobileMoneyError = MobileMoneyCopy.startFailure(error)
                self.activeTrip = current
                Haptics.error()
                self.persist()
            }
        }
    }

    private func settleMobileMoney(tripID: String, payment: MobileMoneyPayment) {
        guard var trip = activeTrip, trip.id == tripID, trip.phase == .paymentPending else { return }
        if payment.status == .success {
            trip.paymentState = .confirmed
            trip.phase = .paymentConfirmed
            mobileMoneyError = nil
            Haptics.success()
        } else {
            trip.paymentState = .failed
            trip.phase = .completed
            mobileMoneyError = MobileMoneyCopy.failureTitle(payment.reason) + ". " + MobileMoneyCopy.failureBody(payment.reason, method: payment.method)
            Haptics.error()
        }
        activeTrip = trip
        persist()
    }

    /// Settles instantly from the prepaid balance. Fails (without charging) when the balance is short so
    /// the passenger can top up or switch to cash.
    func payWithWallet() {
        guard var trip = activeTrip, trip.phase == .completed, trip.paymentMethod == .wallet else { return }
        let charged = store.chargeWallet(trip.totalDue, tripID: trip.id, detail: trip.destination.name)
        if charged {
            trip.paymentState = .confirmed
            trip.phase = .paymentConfirmed
            Haptics.success()
            payments.checkAutoTopUp()
        } else {
            trip.paymentState = .failed
            Haptics.error()
        }
        activeTrip = trip
        persist()
    }


    func switchPaymentToCash() {
        guard var trip = activeTrip, trip.phase == .completed else { return }
        trip.paymentMethod = .cash
        trip.paymentState = .notStarted
        activeTrip = trip
        persist()
    }

    // MARK: Rating

    func rate(stars: Int, reasons: [RatingReason], addFavourite: Bool) {
        guard var trip = activeTrip, trip.phase == .paymentConfirmed else { return }
        trip.rating = stars
        trip.ratingReasons = reasons
        trip.phase = .rated
        if addFavourite, let driverID = trip.driverID {
            store.addFavourite(driverID)
        }
        archive(trip)
    }

    func skipRating() {
        guard var trip = activeTrip, trip.phase == .paymentConfirmed else { return }
        trip.phase = .rated
        archive(trip)
    }

    func acknowledgeCancellation() {
        lastCancellation = nil
    }

    func acknowledgeArchive() {
        justArchivedTripID = nil
    }

    // MARK: Simulation

    private func startSimulation() {
        simulation?.cancel()
        simulation = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(TripSimulation.tickSeconds))
                guard let self, !Task.isCancelled else { return }
                self.tick()
                if !(self.activeTrip?.phase.isLive ?? false) { return }
            }
        }
    }

    private func stopSimulation() {
        simulation?.cancel()
        simulation = nil
    }

    private func tick() {
        guard var trip = activeTrip else { return }
        switch trip.phase {
        case .searching:
            tickSearching(&trip)
        case .driverAssigned:
            tickApproach(&trip)
        case .driverArrived:
            boardingElapsed += TripSimulation.tickSeconds
            if boardingElapsed >= TripSimulation.boardingSeconds {
                trip.phase = .inTrip
                trip.startedAt = Date()
                tripProgress = 0
                remainingTripMinutes = trip.route.durationMinutes
                Haptics.medium()
                persistNow(trip)
            }
        case .inTrip:
            tickInTrip(&trip)
        default:
            break
        }
        activeTrip = trip
        ticksSincePersist += 1
        if ticksSincePersist >= 16 {
            persist()
        }
    }

    private func tickSearching(_ trip: inout Trip) {
        searchTicks += 1
        let ticksPerSecond = Int(1 / TripSimulation.tickSeconds)
        if searchTicks % ticksPerSecond == 0 {
            searchElapsedSeconds += 1
        }
        let candidates = drivers.candidates(
            tier: trip.tier,
            near: trip.pickup.point,
            favouriteIDs: store.favouriteDriverIDs
        )
        var pool = candidates
        if let preferred = trip.preferredDriverID, let match = candidates.first(where: { $0.id == preferred }) {
            pool = [match]
        }
        if pool.isEmpty {
            if searchElapsedSeconds >= TripSimulation.noCandidatesFailSeconds || searchElapsedSeconds >= TripSimulation.searchTimeoutSeconds {
                trip.phase = .noDrivers
                Haptics.warning()
                persistNow(trip)
            }
            return
        }
        if searchElapsedSeconds >= assignmentDelaySeconds, let driver = pool.first {
            assign(driver, to: &trip)
        } else if searchElapsedSeconds >= TripSimulation.searchTimeoutSeconds {
            trip.phase = .noDrivers
            persistNow(trip)
        }
    }

    private func assign(_ driver: Driver, to trip: inout Trip) {
        let route = RoutingService.route(from: driver.position, to: trip.pickup.point)
        approachRoute = route
        driverProgress = 0
        driverPosition = driver.position
        driverHeading = route.bearing(at: 0)
        driverEtaMinutes = max(route.durationMinutes, 1)
        trip.driverID = driver.id
        trip.phase = .driverAssigned
        trip.assignedAt = Date()
        trip.ridePIN = Trip.makePIN()
        trip.quote.pickupEtaMinutes = driverEtaMinutes
        drivers.setStatus(.busy, for: driver.id)
        Haptics.success()
        persistNow(trip)
        refineApproachRoute(from: driver.position, to: trip.pickup.point, driverID: driver.id)
    }

    /// Swaps the instant approach estimate for real street directions if they arrive while the driver is still near the start.
    private func refineApproachRoute(from origin: GeoPoint, to pickup: GeoPoint, driverID: String) {
        Task { @MainActor [weak self] in
            guard let real = await RoutingService.directions(from: origin, to: pickup) else { return }
            guard let self, var trip = self.activeTrip,
                  trip.phase == .driverAssigned, trip.driverID == driverID, self.driverProgress < 0.2 else { return }
            self.approachRoute = real
            self.driverProgress = 0
            self.driverPosition = origin
            self.driverHeading = real.bearing(at: 0)
            self.driverEtaMinutes = max(real.durationMinutes, 1)
            trip.quote.pickupEtaMinutes = self.driverEtaMinutes
            self.persistNow(trip)
        }
    }

    private func tickApproach(_ trip: inout Trip) {
        guard let route = approachRoute else {
            approachRoute = RoutingService.route(from: driverPosition ?? trip.pickup.point, to: trip.pickup.point)
            return
        }
        let totalSeconds = Double(max(route.durationMinutes, 1)) * TripSimulation.secondsPerMinute
        driverProgress = min(driverProgress + TripSimulation.tickSeconds / totalSeconds, 1)
        driverPosition = route.point(at: driverProgress)
        driverHeading = route.bearing(at: driverProgress)
        driverEtaMinutes = max(Int(ceil((1 - driverProgress) * Double(route.durationMinutes))), driverProgress >= 1 ? 0 : 1)
        if driverProgress >= 1 {
            trip.phase = .driverArrived
            trip.arrivedAt = Date()
            boardingElapsed = 0
            driverPosition = trip.pickup.point
            Haptics.success()
            persistNow(trip)
        }
    }

    private func tickInTrip(_ trip: inout Trip) {
        let totalSeconds = Double(max(trip.route.durationMinutes, 1)) * TripSimulation.secondsPerMinute
        let trafficWindow = 0.32...0.46
        isInTraffic = trafficWindow.contains(tripProgress)
        let speedFactor = isInTraffic ? 0.45 : 1.0
        if isInTraffic {
            trafficSecondsAccumulated += TripSimulation.tickSeconds * (1 - speedFactor)
            trip.trafficMinutes = Int((trafficSecondsAccumulated / TripSimulation.secondsPerMinute).rounded())
        }
        tripProgress = min(tripProgress + (TripSimulation.tickSeconds * speedFactor) / totalSeconds, 1)
        driverPosition = trip.route.point(at: tripProgress)
        driverHeading = trip.route.bearing(at: tripProgress)
        remainingTripMinutes = Int(ceil((1 - tripProgress) * Double(trip.route.durationMinutes))) + (isInTraffic ? 2 : 0)
        if tripProgress >= 1 {
            trip.phase = .completed
            trip.completedAt = Date()
            trip.paymentState = .notStarted
            remainingTripMinutes = 0
            isInTraffic = false
            driverPosition = trip.destination.point
            if let driverID = trip.driverID {
                drivers.setPosition(trip.destination.point, for: driverID)
                drivers.setStatus(.online, for: driverID)
            }
            Haptics.success()
            persistNow(trip)
        }
    }

    // MARK: Persistence

    private func archive(_ trip: Trip) {
        store.archive(trip)
        activeTrip = nil
        driverPosition = nil
        approachRoute = nil
        justArchivedTripID = trip.id
        Persistence.remove(key: Persistence.Key.activeTrip)
    }

    private func persistNow(_ trip: Trip) {
        activeTrip = trip
        persist()
    }

    private func persist() {
        ticksSincePersist = 0
        guard let trip = activeTrip else {
            Persistence.remove(key: Persistence.Key.activeTrip)
            return
        }
        let snapshot = ActiveTripSnapshot(
            trip: trip,
            driverProgress: driverProgress,
            tripProgress: tripProgress,
            driverPosition: driverPosition,
            searchElapsedSeconds: searchElapsedSeconds
        )
        Persistence.save(snapshot, key: Persistence.Key.activeTrip)
    }

    /// Cold-start recovery: resume whatever phase the passenger left in.
    private func restoreIfNeeded() {
        guard let snapshot = Persistence.load(ActiveTripSnapshot.self, key: Persistence.Key.activeTrip) else { return }
        let trip = snapshot.trip
        guard !trip.isFinished else {
            Persistence.remove(key: Persistence.Key.activeTrip)
            return
        }
        activeTrip = trip
        driverProgress = snapshot.driverProgress
        tripProgress = snapshot.tripProgress
        driverPosition = snapshot.driverPosition
        searchElapsedSeconds = min(snapshot.searchElapsedSeconds, TripSimulation.searchTimeoutSeconds - 10)
        remainingTripMinutes = Int(ceil((1 - tripProgress) * Double(trip.route.durationMinutes)))
        if let driverID = trip.driverID, let driver = drivers.driver(id: driverID) {
            drivers.setStatus(trip.phase.isLive ? .busy : .online, for: driverID)
            if trip.phase == .driverAssigned {
                approachRoute = RoutingService.route(from: snapshot.driverPosition ?? driver.position, to: trip.pickup.point)
                driverProgress = 0
                driverEtaMinutes = approachRoute?.durationMinutes ?? 3
            }
        }
        if trip.phase.isLive {
            startSimulation()
        } else if trip.phase == .paymentPending,
                  !store.pendingMobileMoney.contains(where: { $0.tripID == trip.id }) {
            // The request was lost (never reached the server): let the passenger retry rather than wait forever.
            var reopened = trip
            reopened.phase = .completed
            reopened.paymentState = .failed
            activeTrip = reopened
            persist()
        }
    }
}

extension Double {
    /// Rounds to a fixed number of decimal places.
    nonisolated func rounded(toPlaces places: Int) -> Double {
        let factor = pow(10.0, Double(places))
        return (self * factor).rounded() / factor
    }
}

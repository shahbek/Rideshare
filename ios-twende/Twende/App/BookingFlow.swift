import Foundation
import Observation

/// Screens pushed on top of the map root while the passenger builds a request.
nonisolated enum BookingRoute: Hashable, Sendable {
    case search
    case setOnMap
    case confirmPickup
    case rideOptions
}

nonisolated enum SetOnMapTarget: Equatable, Sendable {
    case pickup
    case destination
    /// A new intermediate stop, appended after the existing ones.
    case stop
    /// Replaces the visit at this index of `orderedPlaces`.
    case replace(Int)
}

/// Which route field the search screen is filling.
nonisolated enum SearchTarget: Equatable, Sendable {
    case destination
    case stop
    /// Replaces the visit at this index of `orderedPlaces` (pickup is 0).
    case replace(Int)
}

/// Modal sheets owned by the map root. One at a time.
nonisolated enum MainSheet: Identifiable, Hashable, Sendable {
    case zeroCommission
    case fareBreakdown
    case paymentPicker
    case promoCode
    case cancelReason
    case sos
    case chat
    case outOfZone
    case quickRequest(String)
    case billboard(String)

    var id: String {
        switch self {
        case .quickRequest(let driverID): "quickRequest-\(driverID)"
        case .billboard(let adID): "billboard-\(adID)"
        default: String(describing: self)
        }
    }
}

/// Destinations inside the side menu's navigation stack.
nonisolated enum MenuRoute: Hashable, Sendable {
    case profile
    case history
    case tripDetail(String)
    case drivers
    case driverDetail(String)
    case payments
    case wallet
    case savedPlaces
    case editSavedPlace(String?)
    case promotions
    case safety
    case support
    case settings
    case offlineMaps
    case diorama
    case siriGuide
    case identity
}

/// Pre-request state: destination, pickup, tier, payment, promo and the quotes shown on the ride options screen.
@Observable
final class BookingFlow {
    var path: [BookingRoute] = []
    var destination: Place?
    /// Intermediate stops between pickup and destination, in visiting order.
    var stops: [Place] = []
    /// Field the search screen currently fills; adding a stop switches it until one is chosen.
    var searchTarget: SearchTarget = .destination
    var pickup: Place
    var pickupNote: String = ""
    var selectedTier: RideTier = .economy
    /// Service chosen on Home; seeds `selectedTier` when the passenger starts a booking.
    var service: ServiceFamily = .ride {
        didSet { selectedTier = service.defaultTier }
    }
    var paymentMethod: PaymentMethod
    var promo: Promotion?
    var preferredDriverID: String?
    var mapCentre: GeoPoint
    var setOnMapTarget: SetOnMapTarget = .destination
    var route: RouteResult?
    var quotes: [FareQuote] = []
    var searchQuery: String = ""
    /// Destination the passenger tried to pick outside the service zone (G4).
    var outOfZonePlace: Place?
    /// True while the planner edits the route of a ride that is already under way. The first visit is
    /// then the car's current position and cannot be moved or removed.
    private(set) var isEditingLiveRoute: Bool = false

    var selectedTab: MainTab = .home
    var isMenuPresented: Bool = false
    let menuNavigation = MenuNavigation()
    var activeSheet: MainSheet?
    var toast: ToastMessage?
    /// True while Apple Maps directions are being fetched to refine the instant estimate.
    private(set) var isRefiningRoute: Bool = false

    private var routeWaypoints: [GeoPoint]?
    private var directionsTask: Task<Void, Never>?

    /// Upper bound on intermediate stops per ride.
    static let maxStops = 3

    private let drivers: DriverService
    private let store: PassengerStore
    private let location: LocationService
    private let trips: TripCoordinator

    init(drivers: DriverService, store: PassengerStore, location: LocationService, trips: TripCoordinator) {
        self.drivers = drivers
        self.store = store
        self.location = location
        self.trips = trips
        paymentMethod = store.defaultPaymentMethod
        let start = location.effectivePosition
        pickup = BookingFlow.pickupPlace(for: start)
        mapCentre = start
    }

    /// Keeps pickup estimates in the list, map banners and request consistent as availability changes.
    /// Fare and journey duration still come from the route quote; this never starts a routing request.
    var rideOptionQuotes: [FareQuote] {
        quotes.map { quote in
            var current = quote
            let candidates = drivers.candidates(tier: quote.tier, near: pickup.point, favouriteIDs: [])
            let candidate = candidates.first { $0.id == preferredDriverID } ?? candidates.first
            current.hasDriversNearby = candidate != nil
            if let candidate {
                current.pickupEtaMinutes = RoutingService.pickupEtaMinutes(from: candidate.position, to: pickup.point)
            }
            return current
        }
    }

    var selectedQuote: FareQuote? {
        rideOptionQuotes.first { $0.tier == selectedTier }
    }

    /// Only available vehicles of the exact selected tier, with the same dispatch radius as the quote.
    var rideOptionDrivers: [Driver] {
        drivers.candidates(tier: selectedTier, near: pickup.point, favouriteIDs: [])
    }

    var preferredDriver: Driver? {
        drivers.driver(id: preferredDriverID)
    }

    var currentRoute: BookingRoute? { path.last }

    /// Pickup, stops and destination in visiting order.
    var waypoints: [GeoPoint] {
        var points = [pickup.point] + stops.map(\.point)
        if let destination { points.append(destination.point) }
        return points
    }

    var canAddStop: Bool { stops.count < Self.maxStops }

    var orderedPlaces: [Place] {
        [pickup] + stops + (destination.map { [$0] } ?? [])
    }

    /// Applies a permutation of the existing places. Duplicate visits are preserved; the first item is
    /// the new pickup and, if a destination was already chosen, the last item is the new destination.
    @discardableResult
    func reorderRoute(_ places: [Place]) -> Bool {
        var unmatched = orderedPlaces
        guard places.count == unmatched.count, places.count > 1 else { return false }
        for place in places {
            guard let index = unmatched.firstIndex(of: place) else { return false }
            unmatched.remove(at: index)
        }
        guard places != orderedPlaces, let first = places.first else { return true }
        let hadDestination = destination != nil
        if pickup != first { pickupNote = "" }
        pickup = first
        stops = Array(places.dropFirst().dropLast(hadDestination ? 1 : 0))
        if hadDestination { destination = places.last }
        mapCentre = pickup.point
        requote()
        return true
    }

    // MARK: Navigation

    func openMenu(at route: MenuRoute? = nil) {
        menuNavigation.path = route.map { [$0] } ?? []
        isMenuPresented = true
    }

    func closeMenu() {
        isMenuPresented = false
        menuNavigation.path = []
    }

    /// Opens the menu after a sheet has been dismissed so the two presentations never overlap.
    func openMenuAfterSheet(at route: MenuRoute) {
        activeSheet = nil
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            self?.openMenu(at: route)
        }
    }

    func beginSearch() {
        selectedTab = .home
        searchQuery = ""
        searchTarget = .destination
        if preferredDriverID == nil, ServiceFamily.family(for: selectedTier) != service {
            selectedTier = service.defaultTier
        }
        path = [.search]
    }

    /// Returns to the search screen to add a stop before the destination.
    func beginAddStop() {
        guard canAddStop else {
            showToast(L(.maxStopsReached, Self.maxStops), symbol: "exclamationmark.circle.fill", tint: .warning)
            return
        }
        searchQuery = ""
        searchTarget = .stop
        if path.first != .search {
            path = [.search]
        } else if path.count > 1 {
            path = [.search]
        }
    }

    /// Inserts a stop before the destination. Out-of-zone places are rejected like destinations.
    func add(stop place: Place) {
        guard place.isInServiceZone else {
            outOfZonePlace = place
            activeSheet = .outOfZone
            return
        }
        guard canAddStop else { return }
        var visit = place
        visit.id = UUID().uuidString
        stops.append(visit)
        searchQuery = ""
        searchTarget = .destination
        if destination != nil {
            requote()
            path = isEditingLiveRoute ? [.search] : [.search, .confirmPickup]
        }
    }

    /// Opens search to change one visit in place; the chosen place keeps that position in the route.
    func beginReplace(at index: Int) {
        guard orderedPlaces.indices.contains(index), !(isEditingLiveRoute && index == 0) else { return }
        searchQuery = ""
        searchTarget = .replace(index)
        if path.count > 1 { path = [.search] }
    }

    /// Swaps the visit at `index` of `orderedPlaces` for `place`.
    func replace(at index: Int, with place: Place) {
        guard place.isInServiceZone else {
            outOfZonePlace = place
            activeSheet = .outOfZone
            return
        }
        var visit = place
        visit.id = UUID().uuidString
        let stopIndex = index - 1
        if index == 0 {
            if pickup != visit { pickupNote = "" }
            pickup = visit
            mapCentre = visit.point
        } else if stops.indices.contains(stopIndex) {
            stops[stopIndex] = visit
        } else {
            destination = visit
        }
        searchQuery = ""
        searchTarget = .destination
        requote()
    }

    /// Clears one visit. Pickup falls back to the current location, the destination hands over to the
    /// last stop (or empties so the search field fills it), and stops are simply removed.
    func clearVisit(at index: Int) {
        let places = orderedPlaces
        guard places.indices.contains(index) else { return }
        if index == 0 {
            guard !isEditingLiveRoute else { return }
            pickup = BookingFlow.pickupPlace(for: location.effectivePosition)
            pickupNote = ""
            mapCentre = pickup.point
        } else if destination != nil && index == places.count - 1 {
            if let last = stops.popLast() {
                destination = last
            } else {
                destination = nil
                route = nil
                routeWaypoints = nil
                quotes = []
            }
        } else {
            removeStop(at: index - 1)
            return
        }
        searchTarget = .destination
        requote()
    }

    /// True when the visit can be cleared: current-location pickups and a live ride's car cannot.
    func canClearVisit(at index: Int) -> Bool {
        guard index == 0 else { return orderedPlaces.indices.contains(index) }
        return !isEditingLiveRoute && pickup.id != "pickup-current"
    }

    // MARK: Live route editing

    /// Opens the trip planner on a ride that is under way: the car's position first, then the remaining
    /// stops and the destination, all editable and reorderable.
    func beginLiveRouteEdit(trip: Trip, from position: GeoPoint) {
        isEditingLiveRoute = true
        pickup = Place(id: "live-car", name: L(.yourRideNow), address: trip.pickup.name, point: position)
        stops = trip.stopList
        destination = trip.destination
        selectedTier = trip.tier
        searchQuery = ""
        searchTarget = .destination
        route = nil
        routeWaypoints = nil
        requote()
        path = [.search]
    }

    /// Sends the edited route to the ride and returns to the live trip.
    func commitLiveRouteEdit() {
        guard isEditingLiveRoute, let destination else { return }
        trips.updateRoute(stops: stops, destination: destination)
        showToast(L(.routeUpdated), symbol: "arrow.triangle.branch")
        endLiveRouteEdit()
    }

    func endLiveRouteEdit() {
        isEditingLiveRoute = false
        resetToHome()
    }

    func removeStop(at index: Int) {
        guard stops.indices.contains(index) else { return }
        stops.remove(at: index)
        if destination != nil { requote() }
    }

    /// Backs out of adding or replacing a visit without choosing one.
    func cancelAddStop() {
        searchTarget = .destination
        searchQuery = ""
    }

    func refreshPickupFromLocation() {
        guard path.isEmpty else { return }
        pickup = BookingFlow.pickupPlace(for: location.effectivePosition)
        refinePickupName()
    }

    /// Replaces the "near …" label of a current-location pickup with the real street address.
    private func refinePickupName() {
        let current = pickup
        guard current.id == "pickup-current" else { return }
        Task { @MainActor [weak self] in
            guard let resolved = await ReverseGeocoder.place(for: current.point) else { return }
            guard let self, self.pickup.id == "pickup-current", self.pickup.point == current.point else { return }
            self.pickup = Place(id: "pickup-current", name: resolved.name, address: resolved.address, point: current.point, category: resolved.category)
        }
    }

    /// Chooses a destination. Out-of-zone places are rejected and surfaced through the G4 sheet.
    func choose(destination place: Place) {
        guard place.isInServiceZone else {
            outOfZonePlace = place
            activeSheet = .outOfZone
            return
        }
        selectedTab = .home
        destination = place
        searchTarget = .destination
        if path.isEmpty {
            pickup = BookingFlow.pickupPlace(for: location.effectivePosition)
            refinePickupName()
        }
        mapCentre = pickup.point
        requote()
        path = isEditingLiveRoute ? [.search] : [.search, .confirmPickup]
    }

    func beginSetOnMap(for target: SetOnMapTarget) {
        setOnMapTarget = target
        switch target {
        case .pickup: mapCentre = pickup.point
        case .destination: mapCentre = destination?.point ?? pickup.point
        case .stop: mapCentre = stops.last?.point ?? destination?.point ?? pickup.point
        case .replace(let index): mapCentre = orderedPlaces.indices.contains(index) ? orderedPlaces[index].point : pickup.point
        }
        path.append(.setOnMap)
    }

    /// Confirms the pinned spot, using the street address resolved under the pin when available.
    func confirmSetOnMap(resolved: Place? = nil) {
        let place = resolved ?? DemoPlaces.label(for: mapCentre)
        switch setOnMapTarget {
        case .destination:
            choose(destination: place)
        case .stop:
            add(stop: place)
            if destination == nil || isEditingLiveRoute { path = [.search] }
        case .replace(let index):
            replace(at: index, with: place)
            path = [.search]
        case .pickup:
            pickup = place
            requote()
            path = [.search, .confirmPickup]
        }
    }

    func confirmPickup() {
        guard destination != nil else { return }
        requote()
        if let preferredDriver {
            selectedTier = preferredDriver.tier
        }
        path = [.search, .confirmPickup, .rideOptions]
    }

    func resetToHome() {
        selectedTab = .home
        directionsTask?.cancel()
        isRefiningRoute = false
        isEditingLiveRoute = false
        path = []
        destination = nil
        stops = []
        searchTarget = .destination
        pickupNote = ""
        promo = nil
        preferredDriverID = nil
        route = nil
        routeWaypoints = nil
        quotes = []
        searchQuery = ""
        selectedTier = service.defaultTier
        paymentMethod = store.defaultPaymentMethod
        refreshPickupFromLocation()
    }

    // MARK: Quotes

    /// Prices every tier for the current pickup → stops → destination. An instant estimate is shown
    /// immediately and replaced by real street directions when Apple Maps returns them.
    func requote() {
        guard destination != nil else { return }
        let points = waypoints
        if let route, routeWaypoints == points {
            quotes = buildQuotes(for: route)
            return
        }
        let estimate = RoutingService.route(through: points)
        route = estimate
        routeWaypoints = points
        quotes = buildQuotes(for: estimate)
        refineRoute(through: points)
    }

    private func refineRoute(through points: [GeoPoint]) {
        directionsTask?.cancel()
        isRefiningRoute = true
        directionsTask = Task { @MainActor [weak self] in
            let real = await RoutingService.directions(through: points)
            guard let self, !Task.isCancelled else { return }
            self.isRefiningRoute = false
            guard let real, self.routeWaypoints == points else { return }
            self.route = real
            self.quotes = self.buildQuotes(for: real)
        }
    }

    private func buildQuotes(for route: RouteResult) -> [FareQuote] {
        RideTier.allCases.map { tier in
            FareEngine.quote(
                tier: tier,
                route: route,
                pickupEtaMinutes: drivers.pickupEta(tier: tier, near: pickup.point),
                hasDriversNearby: drivers.hasDriversNearby(tier: tier, near: pickup.point),
                promo: promo
            )
        }
    }

    /// Applies a promo code. Returns false when the code is unknown, expired or already used.
    func applyPromo(code: String) -> Bool {
        guard let promotion = PromoCatalog.promotion(code: code),
              !store.redeemedPromoCodes.contains(promotion.code),
              promotion.expires > Date() else {
            return false
        }
        promo = promotion
        requote()
        return true
    }

    func removePromo() {
        promo = nil
        requote()
    }

    // MARK: Requests

    func requestRide() {
        guard let destination, let route, let quote = selectedQuote else { return }
        trips.requestRide(
            pickup: pickup,
            destination: destination,
            stops: stops,
            pickupNote: pickupNote,
            quote: quote,
            route: route,
            paymentMethod: paymentMethod,
            promoCode: promo?.code,
            preferredDriverID: preferredDriverID
        )
        resetToHome()
    }

    func showToast(_ text: String, symbol: String = "checkmark.circle.fill", tint: ToastMessage.Tint = .success) {
        toast = ToastMessage(text: text, symbol: symbol, tint: tint)
    }

    /// Starts a request aimed at a favourite driver (quick request from Home or driver detail).
    func requestDriver(_ driver: Driver) {
        closeMenu()
        activeSheet = nil
        preferredDriverID = driver.id
        selectedTier = driver.tier
        beginSearch()
    }

    /// Re-books a past trip's destination.
    func rebook(_ trip: Trip) {
        closeMenu()
        selectedTier = trip.tier
        stops = trip.stopList.filter(\.isInServiceZone)
        choose(destination: trip.destination)
    }

    // MARK: Helpers

    static func pickupPlace(for point: GeoPoint) -> Place {
        if point.distanceKm(to: DemoPlaces.home.point) < 0.3 {
            return Place(id: "pickup-current", name: DemoPlaces.home.name, address: DemoPlaces.home.address, point: point)
        }
        let labelled = DemoPlaces.label(for: point)
        return Place(id: "pickup-current", name: labelled.name, address: labelled.address, point: point)
    }
}

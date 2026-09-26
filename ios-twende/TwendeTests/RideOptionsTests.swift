import XCTest
import SwiftUI
@_spi(Experimental) import MapboxMaps
@testable import Twende

/// Booking-specific timing and fleet selection; no directions or backend requests are required.
@MainActor
final class RideOptionsTests: XCTestCase {
    func testSedanAndMinivanAreIndependentBookableOptions() throws {
        XCTAssertEqual(RideTier.allCases, [.economy, .comfort, .premium, .bajaji, .boda])
        XCTAssertEqual(try JSONDecoder().decode(RideTier.self, from: Data("\"comfort\"".utf8)), .comfort)
        XCTAssertEqual(try JSONDecoder().decode(RideTier.self, from: Data("\"premium\"".utf8)), .premium)
        XCTAssertEqual(RideTier.comfort.icon3D.vehicleTier, .comfort)
        XCTAssertEqual(RideTier.premium.icon3D.vehicleTier, .premium)
        XCTAssertNotEqual(RideTier.comfort.icon3D, RideTier.premium.icon3D)
        XCTAssertEqual(ServiceFamily.family(for: .premium), .ride)
        XCTAssertEqual(RideTier.comfort.seats, 4)
        XCTAssertEqual(RideTier.premium.seats, 6)

        let env = AppEnvironment()
        env.flow.pickup = DemoPlaces.home
        let route = RouteResult(points: [], distanceKm: 5, durationMinutes: 15)
        env.flow.quotes = RideTier.allCases.map {
            FareEngine.quote(tier: $0, route: route, pickupEtaMinutes: 4, hasDriversNearby: true, promo: nil)
        }
        env.flow.selectedTier = .comfort
        let sedan = try XCTUnwrap(env.flow.selectedQuote)
        let sedanDrivers = Set(env.flow.rideOptionDrivers.map(\.id))
        env.flow.selectedTier = .premium
        let minivan = try XCTUnwrap(env.flow.selectedQuote)
        XCTAssertEqual(minivan.tier, .premium)
        XCTAssertGreaterThan(minivan.fare, sedan.fare)
        XCTAssertTrue(minivan.hasDriversNearby)
        XCTAssertFalse(env.flow.rideOptionDrivers.isEmpty)
        XCTAssertTrue(env.flow.rideOptionDrivers.allSatisfy { $0.tier == .premium })
        XCTAssertTrue(sedanDrivers.isDisjoint(with: Set(env.flow.rideOptionDrivers.map(\.id))))
    }

    func testDropoffIncludesPickupWaitAndJourneyAcrossMidnight() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-21T20:50:00Z"))
        var quote = FareEngine.quote(
            tier: .bajaji,
            route: RouteResult(points: [], distanceKm: 5, durationMinutes: 19),
            pickupEtaMinutes: 6, hasDriversNearby: true, promo: nil
        )
        let arrival = try XCTUnwrap(quote.estimatedDropoff(at: now))
        XCTAssertEqual(arrival.timeIntervalSince(now), 25 * 60)
        XCTAssertEqual(Format.time(arrival), "00:15", "Drop-off is shown in Dar es Salaam time, not the device's zone")
        quote.durationMinutes = 29
        XCTAssertEqual(quote.estimatedDropoff(at: now)?.timeIntervalSince(now), 35 * 60, "A refined multi-stop duration must replace the previous estimate")
        quote.hasDriversNearby = false
        XCTAssertNil(quote.estimatedDropoff(at: now))
    }

    func testSelectedTransportFiltersAllAvailableModelsAndRemovesUnavailableDrivers() {
        let env = AppEnvironment()
        let flow = env.flow
        flow.pickup = DemoPlaces.home
        flow.selectedTier = .bajaji
        XCTAssertEqual(Set(flow.rideOptionDrivers.map(\.id)), [MockDrivers.barakaID, "drv-frank", "drv-mwajuma"])
        XCTAssertTrue(flow.rideOptionDrivers.allSatisfy { $0.tier == .bajaji })
        env.drivers.setStatus(.offline, for: "drv-frank")
        env.drivers.setPosition(DarEsSalaam.upanga.offset(eastMetres: 8_000, northMetres: 0), for: "drv-mwajuma")
        XCTAssertEqual(flow.rideOptionDrivers.map(\.id), [MockDrivers.barakaID])
        flow.selectedTier = .comfort
        XCTAssertEqual(Set(flow.rideOptionDrivers.map(\.id)), [MockDrivers.aminaID, "drv-rehema"])
        XCTAssertTrue(flow.rideOptionDrivers.allSatisfy { $0.tier == .comfort })
        flow.selectedTier = .boda
        XCTAssertEqual(flow.rideOptionDrivers.map(\.id), [MockDrivers.neemaID])
        env.drivers.setStatus(.offline, for: MockDrivers.neemaID)
        XCTAssertTrue(flow.rideOptionDrivers.isEmpty, "Do not fill an empty selected fleet with another vehicle type")
    }

    func testPickupEstimateTracksTheSameFleetWithoutChangingTheFare() throws {
        let env = AppEnvironment()
        let flow = env.flow
        flow.pickup = DemoPlaces.home
        flow.selectedTier = .boda
        flow.quotes = [FareEngine.quote(
            tier: .boda, route: RouteResult(points: [], distanceKm: 5, durationMinutes: 19),
            pickupEtaMinutes: 8, hasDriversNearby: true, promo: nil
        )]
        let fare = try XCTUnwrap(flow.selectedQuote).fare
        env.drivers.setPosition(DarEsSalaam.upanga.offset(eastMetres: 1_500, northMetres: 0), for: MockDrivers.neemaID)
        let expected = RoutingService.pickupEtaMinutes(from: try XCTUnwrap(env.drivers.driver(id: MockDrivers.neemaID)).position, to: flow.pickup.point)
        XCTAssertEqual(flow.selectedQuote?.pickupEtaMinutes, expected)
        XCTAssertEqual(flow.rideOptionQuotes.first?.pickupEtaMinutes, expected)
        XCTAssertEqual(flow.selectedQuote?.fare, fare)
        env.drivers.setStatus(.offline, for: MockDrivers.neemaID)
        XCTAssertEqual(flow.selectedQuote?.hasDriversNearby, false)
        XCTAssertNil(flow.selectedQuote?.estimatedDropoff(at: Date()))
        XCTAssertEqual(flow.selectedQuote?.fare, fare)
    }

    func testBookingBannerOverridesDoNotAlterLiveTripLabels() {
        var map = TripMapView(camera: .constant(.automatic))
        map.pickupBannerText = "Pickup in 6 mins"
        map.destinationBannerText = "Drop-off at 14:35"
        XCTAssertEqual(map.pickupBannerLabel, "Pickup in 6 mins")
        XCTAssertEqual(map.destinationBannerLabel, "Drop-off at 14:35")
        map.pickupBannerText = nil
        map.destinationBannerText = nil
        map.pickupEtaMinutes = 4
        map.destinationEtaMinutes = 12
        XCTAssertEqual(map.pickupBannerLabel, L(.minutesShort, 4))
        XCTAssertEqual(map.destinationBannerLabel, L(.minutesShort, 12))
        map.showsPinLabels = false
        XCTAssertNil(map.pickupBannerLabel)
        XCTAssertNil(map.destinationBannerLabel)
    }

    func testNativeMapRemovesPreviousTransportAnnotationsOnSelectionChange() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let oldWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 600)
        let controller = UIViewController()
        window.rootViewController = controller
        let json = ##"{"version":8,"sources":{},"layers":[{"id":"background","type":"background","paint":{"background-color":"#222222"}}]}"##
        let options = MapInitOptions(cameraOptions: CameraOptions(center: DarEsSalaam.upanga.coordinate, zoom: 13, pitch: 45), styleURI: nil, styleJSON: json)
        let map = MapView(frame: window.bounds, mapInitOptions: options)
        controller.view.addSubview(map)
        // Annotation registration/removal is synchronous and works before basemap loading.
        // Waiting for an initial style event after MapView.init can miss that event entirely.
        window.makeKeyAndVisible()
        let coordinator = TripMapView.Coordinator(parent: TripMapView(camera: .constant(.automatic)))
        coordinator.mapView = map
        defer {
            coordinator.removeVehicles()
            window.isHidden = true
            oldWindow?.makeKeyAndVisible()
        }
        let env = AppEnvironment()
        env.flow.pickup = DemoPlaces.home
        env.flow.selectedTier = .bajaji
        coordinator.updateNearby(env.flow.rideOptionDrivers)
        XCTAssertEqual(map.viewAnnotations.allAnnotations.count, 3)
        let oldViews = Set(map.viewAnnotations.allAnnotations.map { ObjectIdentifier($0.view) })
        env.flow.selectedTier = .boda
        coordinator.updateNearby(env.flow.rideOptionDrivers)
        XCTAssertEqual(map.viewAnnotations.allAnnotations.count, 1)
        XCTAssertTrue(oldViews.isDisjoint(with: Set(map.viewAnnotations.allAnnotations.map { ObjectIdentifier($0.view) })))
        env.drivers.setStatus(.offline, for: MockDrivers.neemaID)
        coordinator.updateNearby(env.flow.rideOptionDrivers)
        XCTAssertEqual(map.viewAnnotations.allAnnotations.count, 0)
    }
}

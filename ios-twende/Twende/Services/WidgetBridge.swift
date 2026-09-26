import AppIntents
import Foundation
import UIKit
import WidgetKit

/// Publishes a compact snapshot of passenger state to the App Group and asks WidgetKit to redraw.
/// Called from the app whenever the ride, wallet, places or favourites change.
enum WidgetBridge {
    private static var lastPublished: Date = .distantPast
    private static var pending: Task<Void, Never>?
    private static var lastShortcutRefresh: Date = .distantPast
    private static var hasLoggedMissingContainer: Bool = false

    /// Coalesces bursts (the trip simulation ticks four times a second) into at most one publish per second.
    static func publish(_ env: AppEnvironment) {
        let elapsed = Date().timeIntervalSince(lastPublished)
        if elapsed >= 1 {
            publishNow(env)
        } else if pending == nil {
            pending = Task { @MainActor in
                try? await Task.sleep(for: .seconds(1 - elapsed))
                guard !Task.isCancelled else { return }
                pending = nil
                publishNow(env)
            }
        }
    }

    static func publishNow(_ env: AppEnvironment) {
        guard UIApplication.shared.applicationState != .background else {
            publishForBackground(env)
            return
        }
        pending?.cancel()
        pending = nil
        writeSnapshot(env)
        exportVehicleSprites()
        WidgetCenter.shared.reloadTimelines(ofKind: TwendeAppGroup.widgetKind)
        refreshShortcutParameters()
    }

    /// Minimal publish for the moment the app leaves the screen: one small JSON write and a timeline
    /// reload, inside a background-task assertion so the system never suspends the app mid-write.
    /// Image encoding and Siri re-indexing are deferred to the next foreground publish.
    static func publishForBackground(_ env: AppEnvironment) {
        pending?.cancel()
        pending = nil
        let application = UIApplication.shared
        var taskID: UIBackgroundTaskIdentifier = .invalid
        taskID = application.beginBackgroundTask(withName: "ZuriWidgetSnapshot") {
            application.endBackgroundTask(taskID)
            taskID = .invalid
        }
        writeSnapshot(env)
        WidgetCenter.shared.reloadTimelines(ofKind: TwendeAppGroup.widgetKind)
        if taskID != .invalid {
            application.endBackgroundTask(taskID)
            taskID = .invalid
        }
    }

    private static func writeSnapshot(_ env: AppEnvironment) {
        lastPublished = Date()
        let reachedWidget = WidgetSnapshotStore.save(snapshot(for: env))
        if !reachedWidget, !hasLoggedMissingContainer {
            hasLoggedMissingContainer = true
            print("[WidgetBridge] App Group container unavailable — this build was signed without any of \(TwendeAppGroup.candidateIdentifiers); the widget cannot read passenger data")
        }
    }

    /// Saved places, recents and favourite drivers feed the spoken phrase parameters, so Siri re-learns
    /// them whenever passenger state changes. Rate-limited: the system indexes asynchronously and a
    /// refresh per simulation tick would only queue up work.
    static func refreshShortcutParameters(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastShortcutRefresh) > 30 else { return }
        lastShortcutRefresh = Date()
        TwendeShortcuts.updateAppShortcutParameters()
    }

    private static var exportedTiers: Set<RideTier> = []
    private static var exportedTurntableTiers: Set<RideTier> = []

    /// Copies each rendered procedural vehicle into the App Group once, so the widget can show the
    /// exact fleet illustration the app uses instead of a stand-in symbol.
    private static func exportVehicleSprites() {
        for tier in RideTier.allCases where !exportedTiers.contains(tier) {
            guard let image = VehicleSpriteStore.shared.preview(for: tier),
                  let url = WidgetSnapshotStore.vehicleImageURL(tier: tier.rawValue),
                  let data = image.pngData() else { continue }
            do {
                try data.write(to: url, options: .atomic)
                exportedTiers.insert(tier)
            } catch {
                print("[WidgetBridge] vehicle sprite export failed for \(tier.rawValue): \(error.localizedDescription)")
            }
        }
        // Low-angle 3D turntable frames for the Live Activity, already small: the extension has a tight memory budget.
        for tier in RideTier.allCases where !exportedTurntableTiers.contains(tier) {
            let frames = VehicleSpriteStore.shared.turntable(for: tier)
            guard frames.count == WidgetSnapshotStore.vehicleTurntableFrames,
                  let top = VehicleSpriteStore.shared.topView(for: tier) else { continue }
            do {
                if let url = WidgetSnapshotStore.vehicleTopURL(tier: tier.rawValue), let data = top.pngData() {
                    try data.write(to: url, options: .atomic)
                }
                for (index, frame) in frames.enumerated() {
                    guard let url = WidgetSnapshotStore.vehicleTurntableURL(tier: tier.rawValue, frame: index),
                          let data = frame.pngData() else { continue }
                    try data.write(to: url, options: .atomic)
                }
                exportedTurntableTiers.insert(tier)
            } catch {
                print("[WidgetBridge] turntable export failed for \(tier.rawValue): \(error.localizedDescription)")
            }
        }
    }

    static func downscaled(_ image: UIImage, maxSide: CGFloat) -> UIImage {
        let size = image.size
        let scale = min(1, maxSide / max(size.width, size.height, 1))
        guard scale < 1 else { return image }
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    static func snapshot(for env: AppEnvironment, now: Date = Date()) -> WidgetSnapshot {
        let store = env.store
        let trips = env.trips
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Format.timeZone
        let monthTrips = store.history.filter {
            calendar.isDate($0.createdAt, equalTo: now, toGranularity: .month) && $0.phase != .cancelled
        }
        let favourites = env.drivers.favourites(ids: store.favouriteDriverIDs)

        var active: WidgetActiveTrip?
        if let trip = trips.activeTrip, trip.phase.isLive || trip.phase.isSettling {
            let driver = trips.assignedDriver
            let eta: Int
            let progress: Double
            switch trip.phase {
            case .driverAssigned:
                eta = max(trips.driverEtaMinutes, 1)
                progress = 1 - Double(trips.driverEtaMinutes) / Double(max(trip.quote.pickupEtaMinutes, 1))
            case .inTrip:
                eta = max(trips.remainingTripMinutes, 1)
                progress = trips.tripProgress
            case .driverArrived:
                eta = 0
                progress = 1
            default:
                eta = trip.quote.pickupEtaMinutes
                progress = trip.phase.isSettling ? 1 : 0
            }
            active = WidgetActiveTrip(
                tripID: trip.id,
                phase: trip.phase.rawValue,
                destination: trip.destination.name,
                pickup: trip.pickup.name,
                tier: trip.tier.rawValue,
                tierName: L(trip.tier.nameKey),
                etaMinutes: eta,
                fare: trip.totalDue,
                driverFirstName: driver?.firstName,
                vehicle: driver?.vehicle.description,
                plate: driver.map { Format.plate($0.vehicle.plate) },
                ridePIN: trip.ridePIN,
                progress: min(max(progress, 0), 1),
                routePoints: thinned(trip.route.points, limit: 48),
                driverPoint: trips.driverPosition.map { WidgetMapPoint(latitude: $0.latitude, longitude: $0.longitude, tier: trip.tier.rawValue) },
                paymentMethod: trip.paymentMethod.displayName
            )
        }

        // The same numbers the Home service switcher shows, measured from the live pickup point.
        let pickupPoint = env.flow.pickup.point
        let serviceEtas = ServiceFamily.allCases.map { family in
            let tier = family.defaultTier
            let available = env.drivers.hasDriversNearby(tier: tier, near: pickupPoint)
            return WidgetServiceEta(
                service: family.rawValue,
                name: L(family.nameKey),
                tier: tier.rawValue,
                etaMinutes: available ? env.drivers.pickupEta(tier: tier, near: pickupPoint) : nil
            )
        }

        return WidgetSnapshot(
            generatedAt: now,
            language: env.settings.language == .english ? .english : .swahili,
            passengerFirstName: store.firstName,
            walletBalance: store.walletBalance,
            monthTrips: monthTrips.count,
            monthSpend: monthTrips.reduce(0) { $0 + $1.totalDue },
            favouritesOnline: favourites.filter { $0.status == .online }.count,
            activeTrip: active,
            savedPlaces: store.savedPlaces.map {
                WidgetPlace(kind: $0.kind.rawValue, id: $0.id, label: $0.label, detail: $0.place.name)
            },
            recentPlaces: store.recents.prefix(4).map {
                WidgetPlace(kind: "recent", id: $0.place.id, label: $0.place.name, detail: $0.place.address)
            },
            recentTrips: store.history.prefix(6).map {
                WidgetTrip(
                    id: $0.id,
                    destination: $0.destination.name,
                    date: $0.createdAt,
                    amount: $0.phase == .cancelled ? ($0.cancellation?.fee ?? 0) : $0.totalDue,
                    tier: $0.tier.rawValue,
                    tierName: L($0.tier.nameKey),
                    isCancelled: $0.phase == .cancelled
                )
            },
            favouriteDrivers: favourites.prefix(3).map {
                WidgetDriver(id: $0.id, firstName: $0.firstName, tier: $0.tier.rawValue, tierName: L($0.tier.nameKey), status: $0.status.rawValue, rating: $0.rating)
            },
            serviceEtas: serviceEtas,
            isDarkMap: env.settings.mapStyle.isDark,
            pickupName: env.flow.pickup.name,
            pickupPoint: WidgetMapPoint(latitude: pickupPoint.latitude, longitude: pickupPoint.longitude),
            nearbyDrivers: env.drivers.nearbyOnline(near: pickupPoint).prefix(14).map {
                WidgetMapPoint(latitude: $0.position.latitude, longitude: $0.position.longitude, tier: $0.tier.rawValue)
            },
            paymentMethod: store.defaultPaymentMethod.displayName,
            paymentKind: store.defaultPaymentMethod.rawValue
        )
    }

    /// Keeps the route shape while bounding the snapshot size.
    private static func thinned(_ points: [GeoPoint], limit: Int) -> [WidgetMapPoint] {
        guard points.count > limit, let last = points.last else {
            return points.map { WidgetMapPoint(latitude: $0.latitude, longitude: $0.longitude) }
        }
        let step = Double(points.count - 1) / Double(limit - 1)
        var result = (0..<(limit - 1)).map { points[Int(Double($0) * step)] }
        result.append(last)
        return result.map { WidgetMapPoint(latitude: $0.latitude, longitude: $0.longitude) }
    }
}

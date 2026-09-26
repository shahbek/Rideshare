import Foundation
import Observation

/// Mock driver fleet. Owns live status/position updates so the favourites row and map feel alive.
@Observable
final class DriverService {
    private(set) var drivers: [Driver]
    /// Set when a favourite driver flips from offline to online. Home decides whether to toast.
    private(set) var recentlyOnlineDriverID: String?

    static let dispatchRadiusKm = 6.0

    private var liveTask: Task<Void, Never>?

    init() {
        var seeded = MockDrivers.all
        var generator = SeededGenerator(seed: 0xA11C_E5)
        for index in seeded.indices {
            seeded[index].heading = Double(Int(generator.next() % 8) * 45)
        }
        drivers = seeded
    }

    func driver(id: String?) -> Driver? {
        guard let id else { return nil }
        return drivers.first { $0.id == id }
    }

    func drivers(ids: [String]) -> [Driver] {
        ids.compactMap { driver(id: $0) }
    }

    /// Favourites ordered online → busy → offline, stable within each group.
    func favourites(ids: [String]) -> [Driver] {
        drivers(ids: ids).sorted { lhs, rhs in
            rank(lhs.status) < rank(rhs.status)
        }
    }

    func onlineCount(ids: [String]) -> Int {
        drivers(ids: ids).filter { $0.status == .online }.count
    }

    /// Online drivers of a tier within dispatch radius, nearest first. Favourites are preferred.
    func candidates(tier: RideTier, near point: GeoPoint, favouriteIDs: [String]) -> [Driver] {
        drivers
            .filter { $0.tier == tier && $0.status == .online }
            .filter { $0.position.distanceKm(to: point) <= Self.dispatchRadiusKm }
            .sorted { lhs, rhs in
                let lhsFav = favouriteIDs.contains(lhs.id)
                let rhsFav = favouriteIDs.contains(rhs.id)
                if lhsFav != rhsFav { return lhsFav }
                return lhs.position.distanceKm(to: point) < rhs.position.distanceKm(to: point)
            }
    }

    func hasDriversNearby(tier: RideTier, near point: GeoPoint) -> Bool {
        !candidates(tier: tier, near: point, favouriteIDs: []).isEmpty
    }

    /// Pickup ETA of the nearest online driver for the tier, or a conservative default.
    func pickupEta(tier: RideTier, near point: GeoPoint) -> Int {
        guard let nearest = candidates(tier: tier, near: point, favouriteIDs: []).first else {
            return 8
        }
        return RoutingService.pickupEtaMinutes(from: nearest.position, to: point)
    }

    /// Nearby drivers for map decoration (any tier, online, within 4 km).
    func nearbyOnline(near point: GeoPoint) -> [Driver] {
        drivers.filter { $0.status == .online && $0.position.distanceKm(to: point) <= 4 }
    }

    func setStatus(_ status: DriverStatus, for id: String) {
        guard let index = drivers.firstIndex(where: { $0.id == id }) else { return }
        drivers[index].status = status
    }

    func setPosition(_ point: GeoPoint, for id: String) {
        guard let index = drivers.firstIndex(where: { $0.id == id }) else { return }
        drivers[index].position = point
    }

    /// Finds a driver by phone digits (used by "Add driver by phone").
    func driver(phone: String) -> Driver? {
        let digits = normalised(phone)
        guard digits.count >= 9 else { return nil }
        return drivers.first { normalised($0.phone).hasSuffix(digits.suffix(9)) }
    }

    func clearRecentlyOnline() {
        recentlyOnlineDriverID = nil
    }

    /// Simulates a living fleet: idle cars creep along their heading and turn at street angles every
    /// couple of seconds, statuses flip occasionally, Hassan comes online after ~2 minutes.
    func startLiveUpdates() {
        guard liveTask == nil else { return }
        liveTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                tick += 1
                self.advanceIdleDrivers(tick: tick)
                if tick % 30 == 0 {
                    self.flipRandomStatus(seed: tick)
                }
                if tick == 60 {
                    self.bringOnline(MockDrivers.hassanID)
                }
            }
        }
    }

    /// Stops the fleet loop while the app is backgrounded; `startLiveUpdates()` resumes it.
    func pauseLiveUpdates() {
        liveTask?.cancel()
        liveTask = nil
    }

    /// Cars move ~8 m per tick along their heading; roughly one in five ticks they turn 90° like a
    /// grid street, and any car that has wandered >1.2 km from Upanga turns back towards it.
    private func advanceIdleDrivers(tick: Int) {
        var generator = SeededGenerator(seed: UInt64(tick &* 7_331))
        let anchor = DarEsSalaam.upanga
        for index in drivers.indices where drivers[index].status == .online {
            var driver = drivers[index]
            let roll = generator.next() % 100
            if driver.position.distanceKm(to: anchor) > 1.2 {
                let toAnchor = driver.position.bearing(to: anchor)
                driver.heading = (toAnchor / 45).rounded() * 45
            } else if roll < 20 {
                let turn: Double = roll < 10 ? 90 : -90
                driver.heading = (driver.heading + turn).truncatingRemainder(dividingBy: 360)
                if driver.heading < 0 { driver.heading += 360 }
            }
            let speed = 6.0 + Double(generator.next() % 5)
            let radians = driver.heading * .pi / 180
            driver.position = driver.position.offset(eastMetres: sin(radians) * speed, northMetres: cos(radians) * speed)
            drivers[index] = driver
        }
    }

    private func flipRandomStatus(seed: Int) {
        let nonFavourites = drivers.filter { !MockDrivers.favouriteIDs.contains($0.id) && $0.status != .busy }
        guard !nonFavourites.isEmpty else { return }
        let target = nonFavourites[seed % nonFavourites.count]
        setStatus(target.status == .online ? .offline : .online, for: target.id)
    }

    private func bringOnline(_ id: String) {
        guard let driver = driver(id: id), driver.status == .offline else { return }
        setStatus(.online, for: id)
        recentlyOnlineDriverID = id
    }

    private func rank(_ status: DriverStatus) -> Int {
        switch status {
        case .online: 0
        case .busy: 1
        case .offline: 2
        }
    }

    private func normalised(_ phone: String) -> String {
        var digits = phone.filter(\.isNumber)
        if digits.hasPrefix("255") { digits.removeFirst(3) }
        if digits.hasPrefix("0") { digits.removeFirst() }
        return digits
    }
}

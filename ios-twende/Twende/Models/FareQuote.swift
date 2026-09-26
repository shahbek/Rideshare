import Foundation

/// Itemised fare. `total` always equals `base + distance + time - discount`.
nonisolated struct FareBreakdown: Codable, Hashable, Sendable {
    var base: Int
    var distance: Int
    var time: Int
    var discount: Int

    var subtotal: Int { base + distance + time }
    var total: Int { max(subtotal - discount, 0) }
}

/// A priced option for one tier on one route.
nonisolated struct FareQuote: Codable, Hashable, Identifiable, Sendable {
    var tier: RideTier
    var distanceKm: Double
    var durationMinutes: Int
    var pickupEtaMinutes: Int
    var breakdown: FareBreakdown
    var hasDriversNearby: Bool

    var id: RideTier { tier }
    var fare: Int { breakdown.total }

    /// Arrival includes the wait for pickup and the entire quoted journey, including route stops.
    /// No clock estimate is promised when no driver is currently available.
    func estimatedDropoff(at now: Date) -> Date? {
        guard hasDriversNearby else { return nil }
        let minutes = max(1, pickupEtaMinutes) + max(0, durationMinutes)
        return now.addingTimeInterval(TimeInterval(minutes) * 60)
    }
}

/// Mock road route between two points.
nonisolated struct RouteResult: Codable, Hashable, Sendable {
    var points: [GeoPoint]
    var distanceKm: Double
    var durationMinutes: Int

    /// Coordinate at a fraction of the route length.
    func point(at fraction: Double) -> GeoPoint {
        guard points.count > 1 else { return points.first ?? DarEsSalaam.centre }
        let clamped = min(max(fraction, 0), 1)
        var segmentLengths: [Double] = []
        var total = 0.0
        for index in 1..<points.count {
            let length = points[index - 1].distanceKm(to: points[index])
            segmentLengths.append(length)
            total += length
        }
        guard total > 0 else { return points[0] }
        var target = clamped * total
        for index in 0..<segmentLengths.count {
            let length = segmentLengths[index]
            if target <= length || index == segmentLengths.count - 1 {
                let localFraction = length > 0 ? target / length : 1
                return points[index].interpolated(to: points[index + 1], fraction: localFraction)
            }
            target -= length
        }
        return points[points.count - 1]
    }

    /// Bearing of travel at a fraction of the route.
    func bearing(at fraction: Double) -> Double {
        let here = point(at: fraction)
        let ahead = point(at: min(fraction + 0.02, 1))
        return here.bearing(to: ahead)
    }
}

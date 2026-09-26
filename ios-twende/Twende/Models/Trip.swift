import Foundation

/// Lifecycle of a ride request. The coordinator is the only writer.
nonisolated enum TripPhase: String, Codable, Hashable, Sendable {
    case searching
    case noDrivers
    case driverAssigned
    case driverArrived
    case inTrip
    case completed
    case paymentPending
    case paymentConfirmed
    case rated
    case cancelled

    /// Phases where the passenger has a live trip on the map.
    var isLive: Bool {
        switch self {
        case .searching, .noDrivers, .driverAssigned, .driverArrived, .inTrip: true
        default: false
        }
    }

    /// Phases where the completion sheet is shown.
    var isSettling: Bool {
        switch self {
        case .completed, .paymentPending, .paymentConfirmed: true
        default: false
        }
    }
}

nonisolated enum CancelReason: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case waitTooLong
    case driverNotMoving
    case wrongPickup
    case changedPlans
    case driverAskedToCancel
    case other

    var id: String { rawValue }
}

nonisolated struct Cancellation: Codable, Hashable, Sendable {
    var reason: CancelReason
    var fee: Int
    var cancelledByDriver: Bool
    var at: Date
}

nonisolated enum RatingReason: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case route
    case driving
    case vehicle
    case behaviour
    case late
    case price

    var id: String { rawValue }
}

nonisolated struct Trip: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var createdAt: Date
    var pickup: Place
    var destination: Place
    /// Intermediate stops in visiting order. Optional so trips saved before the feature still decode.
    var stops: [Place]? = nil
    var pickupNote: String
    var tier: RideTier
    var quote: FareQuote
    var route: RouteResult
    var driverID: String?
    var phase: TripPhase
    var paymentMethod: PaymentMethod
    var paymentState: PaymentState
    var promoCode: String?
    var tip: Int
    var rating: Int?
    var ratingReasons: [RatingReason]
    var cancellation: Cancellation?
    var assignedAt: Date?
    var arrivedAt: Date?
    var startedAt: Date?
    var completedAt: Date?
    var trafficMinutes: Int
    var preferredDriverID: String?
    /// Four-digit start code the passenger reads to the driver before the ride begins. Issued when a
    /// driver is assigned; absent on trips that pre-date the feature.
    var ridePIN: String? = nil

    /// Intermediate stops, never nil.
    var stopList: [Place] { stops ?? [] }

    var fare: Int { quote.fare }
    var totalDue: Int { quote.fare + tip }
    var isFinished: Bool { phase == .rated || phase == .cancelled }

    /// Four random digits; the first is never zero so it reads naturally aloud.
    static func makePIN() -> String {
        let first = Int.random(in: 1...9)
        let rest = (0..<3).map { _ in String(Int.random(in: 0...9)) }.joined()
        return "\(first)\(rest)"
    }

    /// Human-readable reference like `TW-7K3M2`.
    static func makeReference() -> String {
        let alphabet = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")
        let suffix = (0..<5).map { _ in String(alphabet[Int.random(in: 0..<alphabet.count)]) }.joined()
        return "TW-\(suffix)"
    }
}

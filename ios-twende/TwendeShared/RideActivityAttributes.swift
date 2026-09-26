import ActivityKit
import Foundation

/// The ride Live Activity: everything fixed for the trip lives in the attributes, everything that moves
/// (stage, minutes, progress, heading) lives in the content state the app pushes while the ride runs.
nonisolated struct RideActivityAttributes: ActivityAttributes {
    /// Passenger-facing stage of the ride, collapsed from the app's trip phases.
    nonisolated enum Stage: String, Codable, Hashable, Sendable {
        case searching
        case noDrivers
        case onTheWay
        case arrived
        case inTrip
        case completed
        case paid
        case cancelled

        var isFinal: Bool { self == .paid || self == .cancelled }
    }

    nonisolated struct ContentState: Codable, Hashable, Sendable {
        var stage: Stage
        /// Driver-to-pickup minutes while on the way, minutes to destination during the ride.
        var minutes: Int
        /// 0…1 along the current leg (driver → pickup, then pickup → destination).
        var progress: Double
        /// Unwrapped compass heading in degrees (may exceed 360 or go negative) so rotations always take
        /// the short way round instead of spinning through 360°.
        var heading: Double
        /// Signed change of heading since the previous update, clamped; tilts the car on the track so a
        /// turn is visible even on the horizontal route line.
        var turn: Double
        var driverName: String?
        /// Set once the app has exported the driver's portrait to the App Group.
        var driverID: String?
        var vehicle: String?
        var plate: String?
        var pin: String?
        var fare: Int
        var inTraffic: Bool
        var nextStop: String?
    }

    var tripID: String
    /// Raw `RideTier` value; picks the 3D vehicle turntable.
    var tier: String
    var tierName: String
    var pickupName: String
    var destinationName: String
    var paymentName: String
    var language: WidgetLanguage
}

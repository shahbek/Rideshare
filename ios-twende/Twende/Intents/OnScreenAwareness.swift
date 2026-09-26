import AppIntents
import SwiftUI

/// iOS 27 on-screen awareness: tells Siri which of our App Entities are visible so questions like
/// "how much is this ride?", "text my driver's plate to Amina" or "book this one" resolve without the
/// passenger repeating what is already on screen. Every modifier is a no-op before iOS 27.
extension View {
    /// Marks the view as the single primary item on screen (a live ride, a receipt, a chosen destination).
    /// Uses `NSUserActivity` so Siri also gets a title and, on iOS 27, the entity identifier.
    func primaryOnScreen<Entity: AppEntity>(_ entity: Entity?, activity type: String, title: String) -> some View {
        modifier(PrimaryEntityActivity(entity: entity, activityType: type, title: title))
    }

    /// Marks one item among many (a fare row, a saved-place chip, a trip in history).
    @ViewBuilder
    func onScreenEntity<Entity: AppEntity>(_ entity: Entity) -> some View {
        #if IOS27_SDK
        if #available(iOS 27.0, *) {
            appEntityIdentifier(EntityIdentifier(for: Entity.self, identifier: entity.id))
        } else {
            self
        }
        #else
        self
        #endif
    }
}

private struct PrimaryEntityActivity<Entity: AppEntity>: ViewModifier {
    let entity: Entity?
    let activityType: String
    let title: String

    func body(content: Content) -> some View {
        content.userActivity(activityType, isActive: entity != nil) { activity in
            guard let entity else { return }
            activity.title = title
            activity.isEligibleForPrediction = true
            activity.persistentIdentifier = "\(activityType).\(entity.id)"
            if #available(iOS 27.0, *) {
                activity.appEntityIdentifier = EntityIdentifier(for: Entity.self, identifier: entity.id)
            }
        }
    }
}

/// Activity type names used for the primary-item annotations above.
enum TwendeActivity {
    static let liveTrip = "app.rork.twende.liveTrip"
    static let receipt = "app.rork.twende.receipt"
    static let booking = "app.rork.twende.booking"
    static let driver = "app.rork.twende.driver"
    static let pickup = "app.rork.twende.pickup"
    static let rideEnd = "app.rork.twende.rideEnd"
}

/// Keeps Siri's suggestions in step with the ride: donates the live trip so "check my ride" surfaces
/// in Siri Suggestions and Spotlight while one is running.
enum SiriContextPublisher {
    private static var donatedTripID: String?

    @MainActor
    static func publish(_ env: AppEnvironment) {
        guard let trip = env.trips.activeTrip, trip.phase.isLive else {
            donatedTripID = nil
            return
        }
        guard donatedTripID != trip.id else { return }
        donatedTripID = trip.id
        Task {
            do {
                try await CurrentTripIntent().donate()
            } catch {
                print("[SiriContext] donation failed: \(error.localizedDescription)")
            }
        }
    }
}

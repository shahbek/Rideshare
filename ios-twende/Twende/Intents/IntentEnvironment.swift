import Foundation

/// Hands the running app's composition root to App Intents. Intents run in-process — Siri and Shortcuts
/// launch the app in the background when it is not running — so they read and mutate the same
/// `AppEnvironment` the UI observes. `TwendeApp.init` registers it before any scene exists.
enum IntentEnvironment {
    private(set) static var current: AppEnvironment?

    static func register(_ env: AppEnvironment) {
        current = env
    }

    /// Resolves the environment or throws a user-facing error when the passenger has not signed in yet.
    static func resolve() throws -> AppEnvironment {
        guard let current else { throw TwendeIntentError.appNotReady }
        guard current.settings.isOnboarded else { throw TwendeIntentError.notSignedIn }
        return current
    }
}

/// Errors surfaced to Siri and Shortcuts with localised copy.
nonisolated enum TwendeIntentError: Error, CustomLocalizedStringResourceConvertible {
    case appNotReady
    case notSignedIn
    case placeNotFound(String)
    case outOfZone(String)
    case noActiveTrip
    case tripAlreadyLive
    case noDriversNearby(String)
    case cannotCancelNow
    case tripNotFound
    case driverNotFound
    case driverUnavailable(String)
    case noBookingInProgress
    case tooManyStops
    case receiptUnavailable
    case noDriverYet
    case nothingToTip
    case nothingToRate
    case noSavedPlace(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .appNotReady: "Zuri is still starting up. Try again in a moment."
        case .notSignedIn: "Open Zuri and sign in first."
        case .placeNotFound(let query): "I couldn't find \(query) in Dar es Salaam."
        case .outOfZone(let name): "\(name) is outside Zuri's service area."
        case .noActiveTrip: "You don't have a ride in progress."
        case .tripAlreadyLive: "You already have a ride in progress. Finish or cancel it first."
        case .noDriversNearby(let tier): "No \(tier) drivers are nearby right now."
        case .cannotCancelNow: "This ride can't be cancelled at this stage."
        case .tripNotFound: "I couldn't find that trip."
        case .driverNotFound: "I couldn't find that driver."
        case .driverUnavailable(let name): "\(name) isn't online right now. I can tell you when they are."
        case .noBookingInProgress: "Choose a destination in Zuri first, then I can add a stop."
        case .tooManyStops: "This ride already has the maximum number of stops."
        case .receiptUnavailable: "The receipt couldn't be generated right now."
        case .noDriverYet: "No driver is assigned to your ride yet."
        case .nothingToTip: "You can add a tip when your ride ends, before you pay."
        case .nothingToRate: "You can rate your ride once it's paid."
        case .noSavedPlace(let label): "You haven't saved a \(label) place yet. Add it on Zuri's home screen first."
        }
    }
}

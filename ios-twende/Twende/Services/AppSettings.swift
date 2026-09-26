import Foundation
import Observation

/// Where the passenger is in first-run onboarding. Persisted so a cold start resumes the right step.
nonisolated enum OnboardingStage: String, Codable, Sendable {
    case splash
    case language
    case signIn
    case phone
    case otp
    case profile
    case identity
    case location
    case notifications
    case done
}

/// Device-level preferences. Shared singleton so localisation can be read from anywhere on the main actor.
@Observable
final class AppSettings {
    static let shared = AppSettings()

    private enum Keys {
        static let language = "twende.settings.language"
        static let stage = "twende.settings.onboardingStage"
        static let pendingPhone = "twende.settings.pendingPhone"
        static let tripNotifications = "twende.settings.tripNotifications"
        static let promoNotifications = "twende.settings.promoNotifications"
        static let hasSeenZeroCommission = "twende.settings.hasSeenZeroCommission"
        static let mapStyle = "twende.settings.mapStyle"
    }

    private var storedLanguage: AppLanguage
    private var storedStage: OnboardingStage
    private var storedPendingPhone: String
    private var storedTripNotifications: Bool
    private var storedPromoNotifications: Bool
    private var storedHasSeenZeroCommission: Bool
    private var storedMapStyle: MapStyleOption

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        storedLanguage = AppLanguage(rawValue: defaults.string(forKey: Keys.language) ?? "") ?? .swahili
        let savedStage = OnboardingStage(rawValue: defaults.string(forKey: Keys.stage) ?? "") ?? .language
        storedStage = savedStage == .done ? .done : .splash
        storedPendingPhone = defaults.string(forKey: Keys.pendingPhone) ?? ""
        storedTripNotifications = defaults.object(forKey: Keys.tripNotifications) as? Bool ?? true
        storedPromoNotifications = defaults.object(forKey: Keys.promoNotifications) as? Bool ?? false
        storedHasSeenZeroCommission = defaults.bool(forKey: Keys.hasSeenZeroCommission)
        storedMapStyle = MapStyleOption(rawValue: defaults.string(forKey: Keys.mapStyle) ?? "") ?? .fallback
    }

    /// Basemap look chosen in Settings. Persisted so the map opens in the same light on a cold start.
    var mapStyle: MapStyleOption {
        get { storedMapStyle }
        set {
            storedMapStyle = newValue
            defaults.set(newValue.rawValue, forKey: Keys.mapStyle)
        }
    }

    var language: AppLanguage {
        get { storedLanguage }
        set {
            storedLanguage = newValue
            defaults.set(newValue.rawValue, forKey: Keys.language)
        }
    }

    var onboardingStage: OnboardingStage {
        get { storedStage }
        set {
            storedStage = newValue
            defaults.set(newValue.rawValue, forKey: Keys.stage)
        }
    }

    /// National digits typed on the phone screen, kept until OTP succeeds.
    var pendingPhone: String {
        get { storedPendingPhone }
        set {
            storedPendingPhone = newValue
            defaults.set(newValue, forKey: Keys.pendingPhone)
        }
    }

    var tripNotificationsEnabled: Bool {
        get { storedTripNotifications }
        set {
            storedTripNotifications = newValue
            defaults.set(newValue, forKey: Keys.tripNotifications)
        }
    }

    var promoNotificationsEnabled: Bool {
        get { storedPromoNotifications }
        set {
            storedPromoNotifications = newValue
            defaults.set(newValue, forKey: Keys.promoNotifications)
        }
    }

    var hasSeenZeroCommissionExplainer: Bool {
        get { storedHasSeenZeroCommission }
        set {
            storedHasSeenZeroCommission = newValue
            defaults.set(newValue, forKey: Keys.hasSeenZeroCommission)
        }
    }

    var isOnboarded: Bool { onboardingStage == .done }

    /// Returns to the splash and forgets the pending phone (log out / delete account).
    func resetOnboarding() {
        pendingPhone = ""
        onboardingStage = .splash
    }
}

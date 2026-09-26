import Foundation

/// Supported UI languages. Swahili is the default; English is a toggle.
nonisolated enum AppLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case swahili = "sw"
    case english = "en"

    var id: String { rawValue }

    var nativeName: String {
        switch self {
        case .swahili: "Kiswahili"
        case .english: "English"
        }
    }

    var subtitle: String {
        switch self {
        case .swahili: "Lugha chaguo-msingi"
        case .english: "Switch anytime in Settings"
        }
    }

    var flag: String {
        switch self {
        case .swahili: "🇹🇿"
        case .english: "🇬🇧"
        }
    }
}

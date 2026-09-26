import Foundation

/// Returns the localised copy for `key` in the active language.
/// Reading `AppSettings.shared.language` inside a view body keeps the view reactive to language changes.
func L(_ key: LKey) -> String {
    Strings.text(for: key, language: AppSettings.shared.language)
}

/// Returns the localised copy for `key` with `String(format:)` arguments applied.
/// Plain copy (no arguments) is returned verbatim so literal percent signs are never interpreted.
func L(_ key: LKey, _ args: CVarArg...) -> String {
    let text = Strings.text(for: key, language: AppSettings.shared.language)
    guard !args.isEmpty else { return text }
    return String(format: text, arguments: args)
}

enum Strings {
    static func text(for key: LKey, language: AppLanguage) -> String {
        switch language {
        case .swahili: swahili(key)
        case .english: english(key)
        }
    }
}

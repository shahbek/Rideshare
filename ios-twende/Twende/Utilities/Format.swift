import Foundation

/// Product-wide formatting rules: `TZS 14,125`, `dd/MM/yyyy`, 24h time, `+255 7XX XXX XXX`.
nonisolated enum Format {
    static let timeZone = TimeZone(identifier: "Africa/Dar_es_Salaam") ?? .current
    private static let groupingLocale = Locale(identifier: "en_US")

    static func tzs(_ amount: Int) -> String {
        "TZS \(grouped(amount))"
    }

    static func signedTZS(_ amount: Int) -> String {
        amount < 0 ? "− TZS \(grouped(-amount))" : "TZS \(grouped(amount))"
    }

    static func grouped(_ amount: Int) -> String {
        amount.formatted(.number.grouping(.automatic).locale(groupingLocale))
    }

    private static let dateLocale = Locale(identifier: "en_GB")

    static func date(_ date: Date) -> String {
        date.formatted(
            Date.FormatStyle(locale: dateLocale, calendar: Calendar(identifier: .gregorian), timeZone: timeZone)
                .day(.twoDigits)
                .month(.twoDigits)
                .year(.defaultDigits)
        )
    }

    static func time(_ date: Date) -> String {
        date.formatted(
            Date.FormatStyle(locale: dateLocale, calendar: Calendar(identifier: .gregorian), timeZone: timeZone)
                .hour(.twoDigits(amPM: .omitted))
                .minute(.twoDigits)
        )
    }

    static func clock(seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    static func dateTime(_ date: Date) -> String {
        "\(self.date(date)) · \(time(date))"
    }

    /// Month heading in the UI language, e.g. `September 2026` / `Septemba 2026`.
    static func monthYear(_ date: Date, language: AppLanguage) -> String {
        date.formatted(
            Date.FormatStyle(locale: Locale(identifier: language.rawValue), calendar: Calendar(identifier: .gregorian), timeZone: timeZone)
                .month(.wide)
                .year(.defaultDigits)
        )
    }

    static func distance(_ km: Double) -> String {
        km < 1 ? "\(Int((km * 1000).rounded())) m" : String(format: "%.1f km", km)
    }

    /// Formats nine national digits as `+255 7XX XXX XXX`, or `7XX XXX XXX` when `includeCode` is false.
    static func phone(nationalDigits: String, includeCode: Bool = true) -> String {
        let digits = nationalDigits.filter(\.isNumber)
        guard !digits.isEmpty else { return includeCode ? "+255" : "" }
        var groups: [String] = []
        var index = digits.startIndex
        while index < digits.endIndex {
            let end = digits.index(index, offsetBy: 3, limitedBy: digits.endIndex) ?? digits.endIndex
            groups.append(String(digits[index..<end]))
            index = end
        }
        let national = groups.joined(separator: " ")
        return includeCode ? "+255 " + national : national
    }

    /// Formats any stored phone value (`+2557XXXXXXXX` or `7XXXXXXXX`) for display.
    static func phone(_ stored: String) -> String {
        var digits = stored.filter(\.isNumber)
        if digits.hasPrefix("255") { digits.removeFirst(3) }
        if digits.hasPrefix("0") { digits.removeFirst() }
        return phone(nationalDigits: digits)
    }

    /// Normalises a raw plate such as `t123abc` or `mc552byt` to `T 123 ABC` / `MC 552 BYT`.
    static func plate(_ raw: String) -> String {
        let cleaned = raw.uppercased().filter { $0.isLetter || $0.isNumber }
        var prefix = ""
        var digits = ""
        var suffix = ""
        for character in cleaned {
            if digits.isEmpty, character.isLetter {
                prefix.append(character)
            } else if suffix.isEmpty, character.isNumber {
                digits.append(character)
            } else {
                suffix.append(character)
            }
        }
        guard !prefix.isEmpty, !digits.isEmpty, !suffix.isEmpty else { return cleaned }
        return "\(prefix) \(digits) \(suffix)"
    }

    static func stars(_ rating: Double) -> String {
        String(format: "%.1f", rating)
    }

    static func initials(_ name: String) -> String {
        let parts = name.split(separator: " ").prefix(2)
        return parts.compactMap { $0.first.map(String.init) }.joined().uppercased()
    }
}

import Foundation

/// Turns the recognised text of one camera frame into document fields. Tries the machine-readable
/// zone first (any passport or ICAO ID card worldwide), then the Tanzanian NIDA card front, then
/// generic labelled documents such as driving licences.
nonisolated enum IDDocumentParser {
    static func parse(lines: [String]) -> IDScanResult? {
        if let mrz = MRZParser.parse(lines: lines) { return mrz }
        let upper = lines.map { $0.uppercased().trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !upper.isEmpty else { return nil }
        if let nida = parseNIDA(upper) { return nida }
        return parseLabelled(upper) ?? parseHeuristic(upper)
    }

    // MARK: Heuristic fallback

    /// Last resort for cards whose labels were misread or sit in odd columns: the longest number-like
    /// token becomes the document number, the oldest plausible date the birth date, and the first
    /// clean all-letter line of two to four words the name. Every field is flagged for a second look.
    static func parseHeuristic(_ lines: [String]) -> IDScanResult? {
        var result = IDScanResult(kind: .other)
        let joined = lines.joined(separator: " ")
        if joined.contains("PASSPORT") { result.kind = .passport }
        else if joined.contains("LICEN") || joined.contains("LESENI") { result.kind = .drivingLicence }
        else if joined.contains("IDENTITY") || joined.contains("UTAMBULISHO") || joined.contains("ID CARD") { result.kind = .nationalID }

        let tokens = joined.split(whereSeparator: { $0 == " " || $0 == ":" }).map(String.init)
        result.documentNumber = tokens
            .filter { $0.count >= 6 && $0.filter(\.isNumber).count >= 5 && !$0.contains("/") && !$0.contains(".") }
            .max { $0.count < $1.count }

        let calendar = Calendar(identifier: .gregorian)
        let now = Date()
        let dates = lines.compactMap(printedDate)
        result.dateOfBirth = dates.filter { (calendar.dateComponents([.year], from: $0, to: now).year ?? 0) >= 10 }.min()
        result.expiryDate = dates.filter { $0 > now }.max()

        if let nameLine = lines.first(where: { line in
            let words = line.split(separator: " ")
            return (2...4).contains(words.count)
                && line.allSatisfy { $0.isLetter || $0 == " " || $0 == "-" || $0 == "'" }
                && !isLabel(line) && words.allSatisfy { $0.count >= 2 }
                && !headerWords.contains(where: { line.contains($0) })
        }) {
            let parts = nameLine.split(separator: " ").map(String.init)
            result.surname = parts.last
            result.givenNames = parts.dropLast().joined(separator: " ")
        }

        let found = [result.surname, result.documentNumber].compactMap { $0 }.count + (result.dateOfBirth == nil ? 0 : 1)
        guard found >= 1 else { return nil }
        result.uncertain.formUnion([.surname, .givenNames, .documentNumber, .dateOfBirth])
        return result
    }

    private static let headerWords = [
        "TANZANIA", "UNITED", "REPUBLIC", "JAMHURI", "MUUNGANO", "NATIONAL", "IDENTIFICATION", "AUTHORITY",
        "PASSPORT", "LICENCE", "LICENSE", "DRIVING", "CARD", "KITAMBULISHO", "UTAMBULISHO", "MAMLAKA",
    ]

    // MARK: NIDA (Tanzania National Identification Authority)

    /// NIN is 20 digits printed as YYYYMMDD-XXXXX-XXXXX-XX, where the first eight are the birth date.
    static func nin(in text: String) -> (formatted: String, birth: Date?)? {
        let pattern = #"(\d{8})\s*[-–]?\s*(\d{5})\s*[-–]?\s*(\d{5})\s*[-–]?\s*(\d{2})"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        let groups = (1...4).compactMap { Range(match.range(at: $0), in: text).map { String(text[$0]) } }
        guard groups.count == 4 else { return nil }
        let birth = compactDate(groups[0])
        return (groups.joined(separator: "-"), birth)
    }

    private static func parseNIDA(_ lines: [String]) -> IDScanResult? {
        let joined = lines.joined(separator: "\n")
        let isNIDA = joined.contains("NIDA") || joined.contains("UTAMBULISHO") || joined.contains("KITAMBULISHO")
            || (joined.contains("TANZANIA") && !joined.contains("PASSPORT") && !joined.contains("LICEN"))
        // OCR often reads 0 as O and 1 as I/L inside the NIN.
        let ninText = joined
            .replacingOccurrences(of: "O", with: "0")
            .replacingOccurrences(of: "I", with: "1")
            .replacingOccurrences(of: "L", with: "1")
        let ninMatch = nin(in: ninText)
        guard isNIDA || ninMatch != nil else { return nil }

        var result = IDScanResult(kind: .nida)
        result.nationality = "TZA"
        if let ninMatch {
            result.documentNumber = ninMatch.formatted
            result.dateOfBirth = ninMatch.birth
        }
        let first = value(after: ["FIRST NAME", "JINA LA KWANZA"], in: lines)
        let middle = value(after: ["MIDDLE NAME", "JINA LA KATI"], in: lines)
        result.surname = value(after: ["SURNAME", "LAST NAME", "JINA LA MWISHO", "JINA LA UKOO"], in: lines)
        let given = [first, middle].compactMap { $0 }.joined(separator: " ")
        result.givenNames = given.isEmpty ? nil : given
        result.sex = sex(in: lines)
        if let printed = value(after: ["DATE OF BIRTH", "TAREHE YA KUZALIWA"], in: lines).flatMap(printedDate) {
            if let fromNIN = result.dateOfBirth, !Calendar(identifier: .gregorian).isDate(fromNIN, inSameDayAs: printed) {
                result.uncertain.insert(.dateOfBirth)
            }
            result.dateOfBirth = result.dateOfBirth ?? printed
        }
        result.expiryDate = value(after: ["EXPIRY", "DATE OF EXPIRY", "TAREHE YA KUISHA", "MWISHO WA MATUMIZI"], in: lines).flatMap(printedDate)
        if result.surname == nil && result.givenNames == nil, let heuristic = parseHeuristic(lines) {
            result.surname = heuristic.surname
            result.givenNames = heuristic.givenNames
            result.uncertain.formUnion([.surname, .givenNames])
        }
        if result.documentNumber == nil { result.uncertain.insert(.documentNumber) }
        if result.givenNames == nil { result.uncertain.insert(.givenNames) }
        if result.surname == nil { result.uncertain.insert(.surname) }
        return result
    }

    // MARK: Generic labelled documents

    private static func parseLabelled(_ lines: [String]) -> IDScanResult? {
        let joined = lines.joined(separator: " ")
        var result = IDScanResult(kind: .other)
        if joined.contains("DRIVING LICEN") || joined.contains("DRIVER") || joined.contains("LESENI") { result.kind = .drivingLicence }
        else if joined.contains("RESIDENCE") || joined.contains("RESIDENT") { result.kind = .residencePermit }
        else if joined.contains("PASSPORT") { result.kind = .passport }
        else if joined.contains("IDENTITY") || joined.contains("NATIONAL ID") { result.kind = .nationalID }

        result.surname = value(after: ["SURNAME", "LAST NAME", "FAMILY NAME", "NOM"], in: lines)
        result.givenNames = value(after: ["GIVEN NAME", "FIRST NAME", "FORENAME", "OTHER NAMES", "PRENOM"], in: lines)
        if result.surname == nil && result.givenNames == nil, let name = value(after: ["NAME", "JINA"], in: lines) {
            let parts = name.split(separator: " ")
            result.surname = parts.last.map(String.init)
            result.givenNames = parts.dropLast().joined(separator: " ").nilIfEmpty
            result.uncertain.formUnion([.surname, .givenNames])
        }
        result.documentNumber = value(after: ["LICENCE NO", "LICENSE NO", "DOCUMENT NO", "ID NO", "CARD NO", "NUMBER", "NO."], in: lines)
            .map { $0.replacingOccurrences(of: " ", with: "") }
        result.dateOfBirth = value(after: ["DATE OF BIRTH", "BIRTH", "DOB", "D.O.B"], in: lines).flatMap(printedDate)
        result.expiryDate = value(after: ["EXPIRY", "EXPIRES", "DATE OF EXPIRY", "VALID UNTIL", "VALID TO", "EXP"], in: lines).flatMap(printedDate)
        result.sex = sex(in: lines)
        if let nationality = value(after: ["NATIONALITY", "URAIA"], in: lines) { result.nationality = nationality }

        let found = [result.surname, result.givenNames, result.documentNumber].compactMap { $0 }.count + (result.dateOfBirth == nil ? 0 : 1)
        guard found >= 2 else { return nil }
        // Labelled text has no check digits, so every read field deserves a second look.
        if result.documentNumber != nil { result.uncertain.insert(.documentNumber) }
        return result
    }

    // MARK: Helpers

    /// Returns the value printed after a label, either on the same line ("SURNAME: DOE") or the next.
    private static func value(after labels: [String], in lines: [String]) -> String? {
        for (index, line) in lines.enumerated() {
            guard let label = labels.first(where: { line.contains($0) }) else { continue }
            if let range = line.range(of: label) {
                let rest = line[range.upperBound...]
                    .trimmingCharacters(in: CharacterSet(charactersIn: " :/.-"))
                if rest.count >= 2, !isLabel(rest) { return rest }
            }
            var next = index + 1
            while next < lines.count, next <= index + 2 {
                let candidate = lines[next].trimmingCharacters(in: CharacterSet(charactersIn: " :"))
                if !candidate.isEmpty, !isLabel(candidate) { return candidate }
                next += 1
            }
        }
        return nil
    }

    private static let labelWords = [
        "NAME", "JINA", "SEX", "JINSI", "DATE", "TAREHE", "BIRTH", "EXPIRY", "NUMBER", "NAMBA", "SIGNATURE",
        "SAHIHI", "NATIONALITY", "URAIA", "ADDRESS", "ANWANI", "ISSUE", "REPUBLIC", "JAMHURI",
    ]

    private static func isLabel(_ text: String) -> Bool {
        labelWords.contains { text.contains($0) }
    }

    private static func sex(in lines: [String]) -> IdentitySex? {
        guard let raw = value(after: ["SEX", "JINSI", "GENDER"], in: lines) else { return nil }
        let token = raw.split(separator: " ").first.map(String.init) ?? raw
        switch token {
        case "M", "ME", "MALE", "MWANAUME": return .male
        case "F", "KE", "FEMALE", "MWANAMKE": return .female
        default: return nil
        }
    }

    /// Accepts dd-mm-yyyy, dd/mm/yyyy, dd.mm.yyyy and yyyy-mm-dd.
    static func printedDate(_ text: String) -> Date? {
        let pattern = #"(\d{1,4})[\-/\. ](\d{1,2})[\-/\. ](\d{2,4})"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        let parts = (1...3).compactMap { Range(match.range(at: $0), in: text).flatMap { Int(text[$0]) } }
        guard parts.count == 3 else { return nil }
        let (year, month, day) = parts[0] > 31 ? (parts[0], parts[1], parts[2]) : (parts[2] < 100 ? parts[2] + 2000 : parts[2], parts[1], parts[0])
        return makeDate(year: year, month: month, day: day)
    }

    private static func compactDate(_ yyyymmdd: String) -> Date? {
        guard yyyymmdd.count == 8, let year = Int(yyyymmdd.prefix(4)),
              let month = Int(yyyymmdd.dropFirst(4).prefix(2)), let day = Int(yyyymmdd.suffix(2)) else { return nil }
        return makeDate(year: year, month: month, day: day)
    }

    private static func makeDate(year: Int, month: Int, day: Int) -> Date? {
        guard (1900...2100).contains(year), (1...12).contains(month), (1...31).contains(day) else { return nil }
        var components = DateComponents(year: year, month: month, day: day)
        components.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: components)
    }
}

private extension String {
    nonisolated var nilIfEmpty: String? { isEmpty ? nil : self }
}

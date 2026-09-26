import Foundation

/// Fields that the review screen can flag as uncertain.
nonisolated enum IDField: String, Hashable, Sendable, CaseIterable {
    case givenNames, surname, documentNumber, nationality, sex, dateOfBirth, expiryDate
}

/// What the scanner extracted from one document. Missing values stay nil — nothing is guessed.
nonisolated struct IDScanResult: Hashable, Sendable {
    var kind: IdentityDocumentKind
    var givenNames: String?
    var surname: String?
    var documentNumber: String?
    var nationality: String?
    var sex: IdentitySex?
    var dateOfBirth: Date?
    var expiryDate: Date?
    /// True when every ICAO 9303 check digit matched.
    var verifiedByChecksum: Bool = false
    /// Fields that were read but failed a check, or look unreliable.
    var uncertain: Set<IDField> = []

    /// Enough to auto-capture: a number, a name and a birth date.
    var isComplete: Bool {
        documentNumber?.isEmpty == false
            && (givenNames?.isEmpty == false || surname?.isEmpty == false)
            && dateOfBirth != nil
    }

    static let empty = IDScanResult(kind: .other)
}

/// ICAO 9303 machine-readable zone parser for TD1 (ID cards, 3×30), TD2 (2×36) and TD3 (passports, 2×44).
/// Tolerant of common OCR confusions and validates every check digit.
nonisolated enum MRZParser {
    static func parse(lines rawLines: [String]) -> IDScanResult? {
        let lines = rawLines.map(normalise).filter { $0.count >= 26 && $0.contains("<") }
        guard !lines.isEmpty else { return nil }

        for index in lines.indices {
            let first = lines[index]
            // TD3: passport, two lines of 44.
            if index + 1 < lines.count, first.hasPrefix("P"), abs(first.count - 44) <= 2, abs(lines[index + 1].count - 44) <= 2 {
                if let result = parseTD3(fit(first, 44), fit(lines[index + 1], 44)) { return result }
            }
            // TD1: ID card, three lines of 30.
            if index + 2 < lines.count, abs(first.count - 30) <= 2, abs(lines[index + 1].count - 30) <= 2, abs(lines[index + 2].count - 30) <= 2,
               let type = first.first, "IACD".contains(type) {
                if let result = parseTD1(fit(first, 30), fit(lines[index + 1], 30), fit(lines[index + 2], 30)) { return result }
            }
            // TD2: two lines of 36.
            if index + 1 < lines.count, abs(first.count - 36) <= 2, abs(lines[index + 1].count - 36) <= 2,
               let type = first.first, "IACPV".contains(type) {
                if let result = parseTD2(fit(first, 36), fit(lines[index + 1], 36)) { return result }
            }
        }
        return nil
    }

    // MARK: Formats

    private static func parseTD3(_ l1: [Character], _ l2: [Character]) -> IDScanResult? {
        let names = splitNames(String(l1[5..<44]))
        let doc = String(l2[0..<9]), docCheck = l2[9]
        let nationality = letters(String(l2[10..<13]))
        let dob = digits(String(l2[13..<19])), dobCheck = l2[19]
        let sex = l2[20]
        let expiry = digits(String(l2[21..<27])), expiryCheck = l2[27]
        let composite = String(l2[0..<10]) + String(l2[13..<20]) + String(l2[21..<43])
        return build(
            kind: .passport, issuing: letters(String(l1[2..<5])), names: names,
            doc: doc, docCheck: docCheck, nationality: nationality,
            dob: dob, dobCheck: dobCheck, sex: sex, expiry: expiry, expiryCheck: expiryCheck,
            composite: (composite, l2[43])
        )
    }

    private static func parseTD1(_ l1: [Character], _ l2: [Character], _ l3: [Character]) -> IDScanResult? {
        var doc = String(l1[5..<14])
        var docCheck = l1[14]
        // Document numbers longer than 9 characters continue in the optional field (ICAO 9303 §4.2.2).
        if docCheck == "<" {
            let optional = String(l1[15..<30])
            if let end = optional.firstIndex(of: "<"), end > optional.startIndex {
                let tail = String(optional[..<end])
                doc += String(tail.dropLast())
                docCheck = tail.last ?? "<"
            }
        }
        let names = splitNames(String(l3[0..<30]))
        let composite = String(l1[5..<30]) + String(l2[0..<7]) + String(l2[8..<15]) + String(l2[18..<29])
        let type = String(l1[0..<2])
        let issuing = letters(String(l1[2..<5]))
        return build(
            kind: kind(forType: type, issuing: issuing), issuing: issuing, names: names,
            doc: doc, docCheck: docCheck, nationality: letters(String(l2[15..<18])),
            dob: digits(String(l2[0..<6])), dobCheck: l2[6], sex: l2[7],
            expiry: digits(String(l2[8..<14])), expiryCheck: l2[14],
            composite: (composite, l2[29])
        )
    }

    private static func parseTD2(_ l1: [Character], _ l2: [Character]) -> IDScanResult? {
        let names = splitNames(String(l1[5..<36]))
        let composite = String(l2[0..<10]) + String(l2[13..<20]) + String(l2[21..<35])
        let type = String(l1[0..<2])
        let issuing = letters(String(l1[2..<5]))
        return build(
            kind: type.hasPrefix("P") ? .passport : kind(forType: type, issuing: issuing), issuing: issuing, names: names,
            doc: String(l2[0..<9]), docCheck: l2[9], nationality: letters(String(l2[10..<13])),
            dob: digits(String(l2[13..<19])), dobCheck: l2[19], sex: l2[20],
            expiry: digits(String(l2[21..<27])), expiryCheck: l2[27],
            composite: (composite, l2[35])
        )
    }

    private static func build(
        kind: IdentityDocumentKind, issuing: String, names: (surname: String, given: String),
        doc rawDoc: String, docCheck: Character, nationality: String,
        dob: String, dobCheck: Character, sex: Character, expiry: String, expiryCheck: Character,
        composite: (String, Character)
    ) -> IDScanResult? {
        var uncertain: Set<IDField> = []
        // Try the document number as read, then with digit/letter confusions corrected.
        let docCandidates = [rawDoc, digits(rawDoc)]
        let doc = docCandidates.first { verify($0, digitCharacter(docCheck)) } ?? rawDoc
        let docOK = verify(doc, digitCharacter(docCheck))
        if !docOK { uncertain.insert(.documentNumber) }
        let dobOK = verify(dob, digitCharacter(dobCheck))
        if !dobOK { uncertain.insert(.dateOfBirth) }
        let expiryOK = expiry.allSatisfy({ $0 == "<" }) || verify(expiry, digitCharacter(expiryCheck))
        if !expiryOK { uncertain.insert(.expiryDate) }
        let compositeOK = composite.1 == "<" || verify(composite.0, digitCharacter(composite.1))

        let birth = date(dob, isBirth: true)
        guard birth != nil || docOK else { return nil }
        if names.surname.isEmpty && names.given.isEmpty { uncertain.formUnion([.surname, .givenNames]) }
        let resolvedKind: IdentityDocumentKind = (kind == .nationalID && (issuing == "TZA" || nationality == "TZA")) ? .nida : kind

        return IDScanResult(
            kind: resolvedKind,
            givenNames: names.given.isEmpty ? nil : names.given,
            surname: names.surname.isEmpty ? nil : names.surname,
            documentNumber: doc.replacingOccurrences(of: "<", with: ""),
            nationality: nationality.isEmpty ? nil : nationality,
            sex: sex == "F" ? .female : sex == "M" ? .male : .unspecified,
            dateOfBirth: birth,
            expiryDate: date(expiry, isBirth: false),
            verifiedByChecksum: docOK && dobOK && expiryOK && compositeOK,
            uncertain: uncertain
        )
    }

    private static func kind(forType type: String, issuing: String) -> IdentityDocumentKind {
        switch type.first {
        case "P": .passport
        case "D": .drivingLicence
        case "A", "C": type == "AR" || type == "IR" ? .residencePermit : .nationalID
        default: issuing == "TZA" ? .nida : .nationalID
        }
    }

    // MARK: Check digits

    /// ICAO 9303 7-3-1 weighting. `<` counts as zero, letters as 10…35.
    static func checkDigit(_ value: String) -> Int {
        let weights = [7, 3, 1]
        var total = 0
        for (index, character) in value.enumerated() {
            let number: Int
            if let digit = character.wholeNumberValue { number = digit }
            else if let ascii = character.asciiValue, character.isLetter { number = Int(ascii) - 55 }
            else { number = 0 }
            total += number * weights[index % 3]
        }
        return total % 10
    }

    private static func verify(_ value: String, _ check: Character) -> Bool {
        guard let expected = check.wholeNumberValue else { return false }
        return checkDigit(value) == expected
    }

    // MARK: Cleaning

    /// Uppercases, strips spaces and maps the chevrons OCR commonly produces back to `<`.
    static func normalise(_ line: String) -> String {
        var text = line.uppercased()
        for glyph in ["«", "‹", "〈", "<<<".replacingOccurrences(of: "<", with: "«"), "(", "[", "{"] {
            text = text.replacingOccurrences(of: glyph, with: "<")
        }
        text = text.replacingOccurrences(of: " ", with: "")
        return String(text.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "<") })
    }

    private static func fit(_ line: String, _ length: Int) -> [Character] {
        var characters = Array(line.prefix(length))
        while characters.count < length { characters.append("<") }
        return characters
    }

    /// Corrects letters OCR confuses with digits inside numeric fields.
    private static func digits(_ value: String) -> String {
        String(value.map { character -> Character in
            switch character {
            case "O", "Q", "D": "0"
            case "I", "L": "1"
            case "Z": "2"
            case "S": "5"
            case "G": "6"
            case "B": "8"
            default: character
            }
        })
    }

    private static func digitCharacter(_ character: Character) -> Character {
        Character(digits(String(character)))
    }

    private static func letters(_ value: String) -> String {
        String(value.map { character -> Character in
            switch character {
            case "0": "O"
            case "1": "I"
            case "5": "S"
            case "8": "B"
            default: character
            }
        }).replacingOccurrences(of: "<", with: "")
    }

    private static func splitNames(_ field: String) -> (surname: String, given: String) {
        let cleaned = letters(field.replacingOccurrences(of: "<<", with: "|"))
        let parts = field.components(separatedBy: "<<")
        let surname = letters(parts.first ?? "").trimmingCharacters(in: .whitespaces)
        let given = parts.dropFirst()
            .joined(separator: " ")
            .replacingOccurrences(of: "<", with: " ")
            .split(separator: " ")
            .map { letters(String($0)) }
            .joined(separator: " ")
        _ = cleaned
        return (surname.replacingOccurrences(of: "<", with: " "), given)
    }

    /// YYMMDD → Date. Births in the future roll back a century; expiries assume 20YY.
    static func date(_ value: String, isBirth: Bool) -> Date? {
        guard value.count == 6, value.allSatisfy(\.isNumber),
              let yy = Int(value.prefix(2)), let mm = Int(value.dropFirst(2).prefix(2)), let dd = Int(value.suffix(2)),
              (1...12).contains(mm), (1...31).contains(dd) else { return nil }
        let calendar = Calendar(identifier: .gregorian)
        let currentYY = calendar.component(.year, from: Date()) % 100
        let year = isBirth ? (yy > currentYY ? 1900 + yy : 2000 + yy) : (yy >= 70 ? 1900 + yy : 2000 + yy)
        var components = DateComponents(year: year, month: mm, day: dd)
        components.timeZone = TimeZone(identifier: "UTC")
        return calendar.date(from: components)
    }
}

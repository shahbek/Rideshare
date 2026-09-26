import Foundation

/// Families of identity documents the scanner understands.
nonisolated enum IdentityDocumentKind: String, Codable, CaseIterable, Hashable, Sendable {
    case nida
    case passport
    case nationalID
    case drivingLicence
    case residencePermit
    case other
}

nonisolated enum IdentitySex: String, Codable, CaseIterable, Hashable, Sendable {
    case female
    case male
    case unspecified
}

/// What the passenger confirmed on the review screen. The ID image itself is never stored.
nonisolated struct IdentityRecord: Codable, Hashable, Sendable {
    var kind: IdentityDocumentKind
    var givenNames: String
    var surname: String
    var documentNumber: String
    /// ISO 3166 alpha-3 code where known (e.g. `TZA`), otherwise free text.
    var nationality: String
    var sex: IdentitySex
    var dateOfBirth: Date?
    var expiryDate: Date?
    var verifiedAt: Date
    /// True when the face crop from the card was kept as the profile photo.
    var usesCardPhoto: Bool

    var fullName: String {
        [givenNames, surname].filter { !$0.isEmpty }.joined(separator: " ")
    }
}

/// Minimum passenger age enforced by verification.
nonisolated enum IdentityRules {
    static let minimumAge = 18

    static func age(on date: Date = Date(), bornOn birth: Date) -> Int {
        let calendar = Calendar(identifier: .gregorian)
        return calendar.dateComponents([.year], from: birth, to: date).year ?? 0
    }

    static func isExpired(_ expiry: Date?, now: Date = Date()) -> Bool {
        guard let expiry else { return false }
        return expiry < Calendar(identifier: .gregorian).startOfDay(for: now)
    }
}

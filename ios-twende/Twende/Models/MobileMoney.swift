import Foundation

/// Why a mobile money payment was requested. Mirrors the backend's `purpose` field.
nonisolated enum MobileMoneyPurpose: String, Codable, Hashable, Sendable {
    case topUp
    case autoTopUp
    case ride
}

/// Server-side lifecycle of a USSD push payment. Terminal states never change again.
nonisolated enum MobileMoneyStatus: String, Codable, Hashable, Sendable {
    case pending = "PENDING"
    case success = "SUCCESS"
    case failed = "FAILED"
}

/// Normalised failure reasons so the UI can offer the right recovery.
nonisolated enum MobileMoneyFailure: String, Codable, Hashable, Sendable {
    case declined
    case wrongPin
    case timeout
    case insufficientFunds
    case network
    case rejected
}

/// One payment as reported by the Zuri payment server.
nonisolated struct MobileMoneyPayment: Codable, Hashable, Identifiable, Sendable {
    var orderReference: String
    var status: MobileMoneyStatus
    var reason: MobileMoneyFailure?
    var message: String?
    var amount: Int
    var method: PaymentMethod
    var purpose: MobileMoneyPurpose
    /// False while the server runs its simulated payment network (no ClickPesa keys yet).
    var live: Bool
    var expiresAt: String?

    var id: String { orderReference }
    var isTerminal: Bool { status != .pending }

    /// Parses the server's ISO-8601 timestamp (with or without fractional seconds).
    var expiryDate: Date? {
        guard let expiresAt else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: expiresAt) ?? ISO8601DateFormatter().date(from: expiresAt)
    }
}

/// Persisted until the server reports a terminal state, so a relaunch never loses or double-credits money.
nonisolated struct PendingMobileMoney: Codable, Hashable, Identifiable, Sendable {
    var reference: String
    var amount: Int
    var method: PaymentMethod
    var purpose: MobileMoneyPurpose
    var tripID: String?
    var createdAt: Date

    var id: String { reference }
}

/// "When my balance drops below `threshold`, add `amount` from `method`." Off by default.
nonisolated struct AutoTopUpRule: Codable, Hashable, Sendable {
    var isEnabled: Bool
    var threshold: Int
    var amount: Int
    var method: PaymentMethod?

    static let off = AutoTopUpRule(isEnabled: false, threshold: 5_000, amount: 20_000, method: nil)
}

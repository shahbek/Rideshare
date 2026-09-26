import Foundation

/// One movement of money through the passenger's Zuri wallet. Credits are positive, debits negative.
nonisolated struct WalletTransaction: Codable, Hashable, Identifiable, Sendable {
    nonisolated enum Kind: String, Codable, Hashable, Sendable {
        case topUp
        case ridePayment
        case refund
    }

    var id: String
    var kind: Kind
    var amount: Int
    var at: Date
    /// Mobile-money rail the top-up was funded from.
    var source: PaymentMethod?
    /// Trip reference for ride payments and refunds.
    var tripID: String?
    /// Destination name for ride payments.
    var detail: String?
    /// Payment-server order reference for mobile money top-ups.
    var reference: String?
    /// True when the top-up was triggered by the auto top-up rule.
    var isAutomatic: Bool?

    init(
        id: String = UUID().uuidString,
        kind: Kind,
        amount: Int,
        at: Date = Date(),
        source: PaymentMethod? = nil,
        tripID: String? = nil,
        detail: String? = nil,
        reference: String? = nil,
        isAutomatic: Bool? = nil
    ) {
        self.id = id
        self.kind = kind
        self.amount = amount
        self.at = at
        self.source = source
        self.tripID = tripID
        self.detail = detail
        self.reference = reference
        self.isAutomatic = isAutomatic
    }

    var isCredit: Bool { amount > 0 }
}

/// Limits shared by the top-up sheet, the store and the payment server.
nonisolated enum WalletRules {
    static let minimumTopUp = 1_000
    static let maximumTopUp = 500_000
    static let maximumBalance = 2_000_000
    static let historyLimit = 60
    /// Six digits covers the per-transaction cap.
    static let amountDigitLimit = 6
}

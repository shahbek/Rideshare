import Foundation

nonisolated struct PassengerProfile: Codable, Hashable, Sendable {
    var name: String
    var phone: String
    var email: String
    var joinedAt: Date

    var referralCode: String {
        let digits = phone.filter(\.isNumber)
        return "TW-" + String(digits.suffix(4))
    }
}

nonisolated struct EmergencyContact: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    var phone: String

    init(id: String = UUID().uuidString, name: String, phone: String) {
        self.id = id
        self.name = name
        self.phone = phone
    }
}

nonisolated struct Promotion: Hashable, Identifiable, Sendable {
    var code: String
    var title: LKey
    var detail: LKey
    var percentOff: Int
    var maxDiscount: Int
    var expires: Date

    var id: String { code }

    /// Discount in TZS, rounded down to the nearest 25 so totals stay tariff-like.
    func discount(on subtotal: Int) -> Int {
        let percent = subtotal * percentOff / 100
        let capped = min(percent, maxDiscount)
        return capped - capped % 25
    }
}

/// Everything persisted for the signed-in passenger.
nonisolated struct PassengerData: Codable, Sendable {
    var profile: PassengerProfile?
    var savedPlaces: [SavedPlace]
    var recents: [RecentPlace]
    var favouriteDriverIDs: [String]
    var notifyWhenOnline: [String]
    var mobileMoneyAccounts: [MobileMoneyAccount]
    var defaultPaymentMethod: PaymentMethod
    var emergencyContacts: [EmergencyContact]
    var shareTripsWithContacts: Bool
    var history: [Trip]
    var redeemedPromoCodes: [String]
    var notifyWhenDriversAvailable: Bool
    var notifyWhenZoneOpens: [String]
    var walletBalance: Int
    var walletTransactions: [WalletTransaction]
    /// Mobile money requests awaiting a final answer from the payment server.
    var pendingMobileMoney: [PendingMobileMoney]
    var autoTopUp: AutoTopUpRule
    /// Details the passenger confirmed after scanning an ID. Only confirmed fields are stored.
    var identity: IdentityRecord?

    static let empty = PassengerData()

    init() {
        profile = nil
        savedPlaces = []
        recents = []
        favouriteDriverIDs = []
        notifyWhenOnline = []
        mobileMoneyAccounts = []
        defaultPaymentMethod = .cash
        emergencyContacts = []
        shareTripsWithContacts = false
        history = []
        redeemedPromoCodes = []
        notifyWhenDriversAvailable = false
        notifyWhenZoneOpens = []
        walletBalance = 0
        walletTransactions = []
        pendingMobileMoney = []
        autoTopUp = .off
        identity = nil
    }

    private nonisolated enum CodingKeys: String, CodingKey {
        case profile, savedPlaces, recents, favouriteDriverIDs, notifyWhenOnline, mobileMoneyAccounts
        case defaultPaymentMethod, emergencyContacts, shareTripsWithContacts, history, redeemedPromoCodes
        case notifyWhenDriversAvailable, notifyWhenZoneOpens, walletBalance, walletTransactions
        case pendingMobileMoney, autoTopUp, identity
    }

    /// Fields added after launch decode with defaults so an older saved profile is never discarded.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        profile = try container.decodeIfPresent(PassengerProfile.self, forKey: .profile)
        savedPlaces = try container.decodeIfPresent([SavedPlace].self, forKey: .savedPlaces) ?? []
        recents = try container.decodeIfPresent([RecentPlace].self, forKey: .recents) ?? []
        favouriteDriverIDs = try container.decodeIfPresent([String].self, forKey: .favouriteDriverIDs) ?? []
        notifyWhenOnline = try container.decodeIfPresent([String].self, forKey: .notifyWhenOnline) ?? []
        mobileMoneyAccounts = try container.decodeIfPresent([MobileMoneyAccount].self, forKey: .mobileMoneyAccounts) ?? []
        defaultPaymentMethod = try container.decodeIfPresent(PaymentMethod.self, forKey: .defaultPaymentMethod) ?? .cash
        emergencyContacts = try container.decodeIfPresent([EmergencyContact].self, forKey: .emergencyContacts) ?? []
        shareTripsWithContacts = try container.decodeIfPresent(Bool.self, forKey: .shareTripsWithContacts) ?? false
        history = try container.decodeIfPresent([Trip].self, forKey: .history) ?? []
        redeemedPromoCodes = try container.decodeIfPresent([String].self, forKey: .redeemedPromoCodes) ?? []
        notifyWhenDriversAvailable = try container.decodeIfPresent(Bool.self, forKey: .notifyWhenDriversAvailable) ?? false
        notifyWhenZoneOpens = try container.decodeIfPresent([String].self, forKey: .notifyWhenZoneOpens) ?? []
        walletBalance = try container.decodeIfPresent(Int.self, forKey: .walletBalance) ?? 0
        walletTransactions = try container.decodeIfPresent([WalletTransaction].self, forKey: .walletTransactions) ?? []
        pendingMobileMoney = try container.decodeIfPresent([PendingMobileMoney].self, forKey: .pendingMobileMoney) ?? []
        autoTopUp = try container.decodeIfPresent(AutoTopUpRule.self, forKey: .autoTopUp) ?? .off
        identity = try container.decodeIfPresent(IdentityRecord.self, forKey: .identity)
    }
}

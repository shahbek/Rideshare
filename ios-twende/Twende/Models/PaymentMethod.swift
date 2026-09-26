import Foundation

/// Cash is the default; the prepaid Twende wallet is always present; the four mobile money rails are opt-in.
nonisolated enum PaymentMethod: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case cash
    case wallet
    case mpesa
    case mixx
    case airtel
    case halopesa

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .cash: "Cash"
        case .wallet: "Zuri Wallet"
        case .mpesa: "M-Pesa"
        case .mixx: "Mixx by Yas"
        case .airtel: "Airtel Money"
        case .halopesa: "HaloPesa"
        }
    }

    /// Short label for tight tiles.
    var shortName: String {
        switch self {
        case .mixx: "Mixx"
        case .airtel: "Airtel"
        default: displayName
        }
    }

    var operatorName: String {
        switch self {
        case .cash: ""
        case .wallet: "Zuri"
        case .mpesa: "Vodacom"
        case .mixx: "Yas"
        case .airtel: "Airtel"
        case .halopesa: "Halotel"
        }
    }

    /// Rails that must be linked by phone number before they can be chosen.
    var isMobileMoney: Bool { self != .cash && self != .wallet }

    var isWallet: Bool { self == .wallet }

    var symbol: String {
        switch self {
        case .cash: "banknote.fill"
        case .wallet: "wallet.pass.fill"
        default: "iphone.radiowaves.left.and.right"
        }
    }

    /// Official provider logo bundled in the asset catalogue; nil for cash and the Zuri wallet.
    var logoAsset: String? {
        switch self {
        case .mpesa: "logo_mpesa"
        case .mixx: "logo_mixx"
        case .airtel: "logo_airtel"
        case .halopesa: "logo_halopesa"
        case .cash, .wallet: nil
        }
    }

    /// Brand hue used for the small provider tile.
    var brandHex: UInt32 {
        switch self {
        case .cash, .wallet: 0xC5AA76
        case .mpesa: 0x3BB44A
        case .mixx: 0x14336F
        case .airtel: 0xED1C24
        case .halopesa: 0xF15A29
        }
    }

    /// Maps the server's network id ("mpesa", "mixx", ...) to a rail.
    static func mobileMoney(network: String?) -> PaymentMethod? {
        guard let network, let method = PaymentMethod(rawValue: network), method.isMobileMoney else { return nil }
        return method
    }

    /// Best local guess from the number prefix; the server confirms (numbers can be ported).
    static func guessNetwork(nationalDigits: String) -> PaymentMethod? {
        let digits = nationalDigits.filter(\.isNumber)
        guard digits.count >= 2 else { return nil }
        switch String(digits.prefix(2)) {
        case "65", "67", "71", "77": return .mixx
        case "74", "75", "76": return .mpesa
        case "68", "69", "78": return .airtel
        case "61", "62": return .halopesa
        default: return nil
        }
    }

    var shortCode: String {
        switch self {
        case .cash: "TZS"
        case .wallet: "TW"
        case .mpesa: "M"
        case .mixx: "Mx"
        case .airtel: "A"
        case .halopesa: "H"
        }
    }
}

nonisolated struct MobileMoneyAccount: Codable, Hashable, Identifiable, Sendable {
    var method: PaymentMethod
    var phone: String
    var isEnabled: Bool
    /// True only after the owner typed the SMS code sent to this number. Older saves decode as false.
    var isVerified: Bool = false
    /// Registered wallet name reported by the network, when available.
    var accountName: String? = nil

    var id: PaymentMethod { method }

    enum CodingKeys: String, CodingKey { case method, phone, isEnabled, isVerified, accountName }

    init(method: PaymentMethod, phone: String, isEnabled: Bool, isVerified: Bool = false, accountName: String? = nil) {
        self.method = method
        self.phone = phone
        self.isEnabled = isEnabled
        self.isVerified = isVerified
        self.accountName = accountName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        method = try container.decode(PaymentMethod.self, forKey: .method)
        phone = try container.decode(String.self, forKey: .phone)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        isVerified = try container.decodeIfPresent(Bool.self, forKey: .isVerified) ?? false
        accountName = try container.decodeIfPresent(String.self, forKey: .accountName)
    }
}

nonisolated enum PaymentState: String, Codable, Hashable, Sendable {
    case notStarted
    case pending
    case confirmed
    case failed
}

import Foundation

/// User-facing payment errors. Messages are safe to show; internals are never surfaced.
nonisolated enum PaymentGatewayError: Error, Sendable {
    case offline
    case rejected(String)
    case server
}

/// HTTP client for the Zuri payment server. The app never holds ClickPesa credentials; it only sends
/// the amount, wallet and phone number, then polls the server for the outcome.
nonisolated struct PaymentGateway: Sendable {
    /// Public backend host. Falls back to the provisioned URL when the build-time value is absent.
    static var baseURL: URL {
        let configured = Config.EXPO_PUBLIC_RORK_FUNCTIONS_URL.trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(string: configured.isEmpty ? "https://passenger-app-full-build-specification-p-backend.rork.app" : configured)
            ?? URL(string: "https://passenger-app-full-build-specification-p-backend.rork.app")!
    }

    /// Stable per-install identifier; payments are only readable by the device that created them.
    static var deviceID: String {
        let key = "zuri.payments.deviceID"
        if let existing = UserDefaults.standard.string(forKey: key), existing.count >= 8 { return existing }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }

    private struct ErrorBody: Decodable { let message: String? }
    struct ConfigBody: Decodable, Sendable { let live: Bool }

    private struct CollectBody: Encodable {
        let amount: Int
        let phone: String
        let method: String
        let purpose: String
        let simulation: String
    }

    private struct SimulateBody: Encodable {
        let action: String
        let pin: String?
    }

    /// Result of asking the server which network a number belongs to.
    struct WalletLookup: Decodable, Sendable {
        let phone: String
        let network: String?
        let accountName: String?
        let confirmed: Bool
    }

    /// An SMS code was sent; `testCode` is only filled while SMS is not connected yet.
    struct OTPChallenge: Decodable, Sendable {
        let verificationId: String
        let phone: String
        let network: String?
        let accountName: String?
        let resendAfter: Int
        let live: Bool
        let testCode: String?
    }

    struct OTPResult: Decodable, Sendable {
        let verified: Bool
        let phone: String
        let method: String
        let accountName: String?
    }

    private struct PhoneBody: Encodable { let phone: String }
    private struct SendCodeBody: Encodable { let phone: String; let method: String }
    private struct VerifyCodeBody: Encodable { let verificationId: String; let code: String }

    func lookupWallet(phone: String) async throws -> WalletLookup {
        try await send("wallets/lookup", method: "POST", body: PhoneBody(phone: phone))
    }

    func sendWalletCode(phone: String, method: PaymentMethod) async throws -> OTPChallenge {
        try await send("wallets/otp/send", method: "POST", body: SendCodeBody(phone: phone, method: method.rawValue))
    }

    func verifyWalletCode(verificationId: String, code: String) async throws -> OTPResult {
        try await send("wallets/otp/verify", method: "POST", body: VerifyCodeBody(verificationId: verificationId, code: code))
    }

    func config() async throws -> ConfigBody {
        try await send("payments/config", method: "GET", body: Optional<CollectBody>.none)
    }

    /// Asks the server to send the network PIN prompt to `phone`.
    func collect(amount: Int, phone: String, method: PaymentMethod, purpose: MobileMoneyPurpose) async throws -> MobileMoneyPayment {
        let body = CollectBody(
            amount: amount,
            phone: phone,
            method: method.rawValue,
            purpose: purpose.rawValue,
            simulation: purpose == .autoTopUp ? "auto" : "interactive"
        )
        return try await send("payments/collect", method: "POST", body: body)
    }

    func status(reference: String) async throws -> MobileMoneyPayment {
        try await send("payments/\(reference)", method: "GET", body: Optional<CollectBody>.none)
    }

    /// Test-mode only: stands in for the passenger acting on the phone's PIN prompt.
    func simulate(reference: String, action: String, pin: String?) async throws -> MobileMoneyPayment {
        try await send("payments/\(reference)/simulate", method: "POST", body: SimulateBody(action: action, pin: pin))
    }

    private func send<Body: Encodable, Decoded: Decodable>(_ path: String, method: String, body: Body?) async throws -> Decoded {
        var request = URLRequest(url: Self.baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue(Self.deviceID, forHTTPHeaderField: "X-Zuri-Device")
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw PaymentGatewayError.offline
        }
        guard let http = response as? HTTPURLResponse else { throw PaymentGatewayError.server }
        guard (200..<300).contains(http.statusCode) else {
            if (400..<500).contains(http.statusCode), let message = try? JSONDecoder().decode(ErrorBody.self, from: data).message {
                throw PaymentGatewayError.rejected(message)
            }
            print("[PaymentGateway] \(path) failed with status \(http.statusCode)")
            throw PaymentGatewayError.server
        }
        do {
            return try JSONDecoder().decode(Decoded.self, from: data)
        } catch {
            print("[PaymentGateway] Could not decode \(path)")
            throw PaymentGatewayError.server
        }
    }
}

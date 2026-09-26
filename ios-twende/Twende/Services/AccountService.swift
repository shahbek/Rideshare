import Foundation

/// What the Zuri server keeps for a signed-in passenger: their profile and saved app data.
nonisolated struct RemoteAccount: Codable, Sendable {
    var data: PassengerData?
    var updatedAt: String?
}

/// Reads and writes the signed-in passenger's account on the Zuri server. Every call carries the
/// Rork Auth bearer token; the server only ever returns the caller's own account.
nonisolated struct AccountService: Sendable {
    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func request(_ method: String, token: String, body: Data? = nil) -> URLRequest {
        var request = URLRequest(url: PaymentGateway.baseURL.appending(path: "account"))
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return request
    }

    /// The stored account, or nil when this Google account has never saved one.
    func fetch(token: String) async throws -> PassengerData? {
        let (data, response) = try await URLSession.shared.data(for: request("GET", token: token))
        guard let http = response as? HTTPURLResponse else { throw PaymentGatewayError.server }
        if http.statusCode == 404 { return nil }
        guard http.statusCode == 200 else { throw PaymentGatewayError.server }
        return try Self.decoder.decode(RemoteAccount.self, from: data).data
    }

    func save(_ passenger: PassengerData, token: String) async throws {
        let body = try Self.encoder.encode(RemoteAccount(data: passenger, updatedAt: nil))
        let (_, response) = try await URLSession.shared.data(for: request("PUT", token: token, body: body))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw PaymentGatewayError.server }
    }

    func delete(token: String) async throws {
        let (_, response) = try await URLSession.shared.data(for: request("DELETE", token: token))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw PaymentGatewayError.server }
    }
}

import AuthenticationServices
import CryptoKit
import Foundation
import Observation
import UIKit

/// Google sign-in through Rork Auth (OAuth + PKCE). Tokens live in the Keychain; the access token is
/// refreshed automatically and attached to account requests as a bearer token.
@Observable
final class AuthManager {
    nonisolated struct User: Codable, Hashable, Sendable {
        let id: String
        let email: String
        let name: String?
        let picture: String?
    }

    private(set) var user: User?
    private(set) var isLoading: Bool = true
    private(set) var isSigningIn: Bool = false
    var errorMessage: String?

    private let authURL = Config.EXPO_PUBLIC_RORK_AUTH_URL
    private let appKey = Config.EXPO_PUBLIC_RORK_APP_KEY
    private let projectID = Config.EXPO_PUBLIC_PROJECT_ID
    private var webAuthSession: ASWebAuthenticationSession?

    /// Injected by Rork into the managed simulator so sign-in can open in the developer's browser.
    private var developerHint: String? { UserDefaults.standard.string(forKey: "RORK_DEVELOPER_HINT") }

    private var authEnv: String {
        #if targetEnvironment(simulator)
        "simulator"
        #else
        "native"
        #endif
    }

    var isSignedIn: Bool { user != nil }

    init() {
        Task { await restore() }
    }

    // MARK: Session

    func restore() async {
        defer { isLoading = false }
        if let token = KeychainHelper.get("access_token"), let user = Self.user(fromToken: token) {
            self.user = user
            return
        }
        if refreshTokenValue() != nil { await refresh() }
    }

    /// A valid access token, refreshing it first when it has expired. Nil when signed out.
    func validAccessToken() async -> String? {
        if let token = KeychainHelper.get("access_token"), Self.user(fromToken: token) != nil { return token }
        await refresh()
        return KeychainHelper.get("access_token")
    }

    func signOut() {
        KeychainHelper.delete("access_token")
        KeychainHelper.delete("refresh_token")
        UserDefaults.standard.removeObject(forKey: "RORK_AUTH_REFRESH_TOKEN")
        user = nil
    }

    // MARK: Sign in

    /// Runs the Google OAuth flow. Returns true once a user is signed in.
    @discardableResult
    func signInWithGoogle() async -> Bool {
        guard !isSigningIn else { return false }
        isSigningIn = true
        errorMessage = nil
        defer { isSigningIn = false }
        do {
            let verifier = Self.randomVerifier()
            var body: [String: String] = [
                "app_key": appKey,
                "provider": "google",
                "code_challenge": Self.challenge(for: verifier),
                "target": "swift",
                "env": authEnv,
            ]
            if authEnv == "simulator", let hint = developerHint { body["developer_hint"] = hint }
            let initiate: InitiateResponse = try await post("/oauth/initiate", body: body)

            let code: String
            if initiate.flow == "popup" {
                do {
                    code = try await pollForCode(state: initiate.state)
                } catch AuthError.cancelledByUser {
                    code = try await runWebAuthSession(initiate.auth_url)
                }
            } else {
                code = try await runWebAuthSession(initiate.auth_url)
            }

            let tokens: TokenResponse = try await post("/oauth/token", body: [
                "app_key": appKey, "code": code, "code_verifier": verifier,
            ])
            KeychainHelper.set("access_token", value: tokens.access_token)
            KeychainHelper.set("refresh_token", value: tokens.refresh_token)
            user = tokens.user
            return true
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            return false
        } catch {
            print("[Auth] sign-in failed: \(type(of: error))")
            errorMessage = L(.signInFailed)
            return false
        }
    }

    private func refreshTokenValue() -> String? {
        #if targetEnvironment(simulator)
        if let injected = UserDefaults.standard.string(forKey: "RORK_AUTH_REFRESH_TOKEN") { return injected }
        #endif
        return KeychainHelper.get("refresh_token")
    }

    private func refresh() async {
        guard let refreshToken = refreshTokenValue() else { user = nil; return }
        do {
            let response: RefreshResponse = try await post("/oauth/refresh", body: ["app_key": appKey, "refresh_token": refreshToken])
            KeychainHelper.set("access_token", value: response.access_token)
            user = Self.user(fromToken: response.access_token)
        } catch AuthError.server {
            signOut()
        } catch {
            // Offline: keep the last known user; the next request retries the refresh.
            print("[Auth] refresh deferred: \(type(of: error))")
        }
    }

    private func pollForCode(state: String) async throws -> String {
        let deadline = Date().addingTimeInterval(5 * 60)
        while Date() < deadline {
            try await Task.sleep(for: .milliseconds(1500))
            guard let poll: PollCodeResponse = try? await post("/oauth/poll-code", body: ["app_key": appKey, "state": state]) else { continue }
            if poll.status == "cancelled" { throw AuthError.cancelledByUser }
            if poll.status == "ready", let code = poll.code { return code }
        }
        throw AuthError.timeout
    }

    private func runWebAuthSession(_ urlString: String) async throws -> String {
        guard let url = URL(string: urlString) else { throw AuthError.invalidURL }
        let scheme = "rork-\(projectID)"
        defer { webAuthSession = nil }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { callbackURL, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let callbackURL,
                      let code = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
                        .queryItems?.first(where: { $0.name == "code" })?.value else {
                    continuation.resume(throwing: AuthError.noCode)
                    return
                }
                continuation.resume(returning: code)
            }
            session.presentationContextProvider = WebAuthPresentationContext.shared
            session.prefersEphemeralWebBrowserSession = false
            webAuthSession = session
            session.start()
        }
    }

    // MARK: Networking

    private func post<Response: Decodable>(_ path: String, body: [String: String]) async throws -> Response {
        guard let url = URL(string: authURL + path) else { throw AuthError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw AuthError.server }
        return try JSONDecoder().decode(Response.self, from: data)
    }

    // MARK: Helpers

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func randomVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }

    private static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    /// Reads the (Rork-signed) JWT payload for the user and expiry.
    static func user(fromToken token: String) -> User? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var base64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        guard let data = Data(base64Encoded: base64),
              let payload = try? JSONDecoder().decode(JWTPayload.self, from: data) else { return nil }
        if let exp = payload.exp, Date(timeIntervalSince1970: exp) < Date() { return nil }
        return User(id: payload.sub, email: payload.email ?? "", name: payload.name, picture: payload.picture)
    }
}

private nonisolated struct JWTPayload: Decodable {
    let sub: String
    let email: String?
    let name: String?
    let picture: String?
    let exp: TimeInterval?
}

private nonisolated struct InitiateResponse: Decodable {
    let auth_url: String
    let state: String
    let flow: String?
}

private nonisolated struct PollCodeResponse: Decodable {
    let status: String
    let code: String?
}

private nonisolated struct TokenResponse: Decodable {
    let access_token: String
    let refresh_token: String
    let user: AuthManager.User
}

private nonisolated struct RefreshResponse: Decodable {
    let access_token: String
}

nonisolated enum AuthError: Error {
    case noCode, invalidURL, server, timeout, cancelledByUser
}

/// Anchors the sign-in sheet to the key window.
final class WebAuthPresentationContext: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = WebAuthPresentationContext()

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first { $0.isKeyWindow } ?? ASPresentationAnchor()
        }
    }
}

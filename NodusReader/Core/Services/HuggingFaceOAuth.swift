// SPDX-License-Identifier: AGPL-3.0-only
import CryptoKit
import Foundation
import Security

/// "Sign in with Hugging Face": an alternative to pasting an access token.
///
/// Nodus Reader is a public OAuth client (no secret ships in the app) that
/// uses PKCE. Its client id is a Client ID Metadata Document published in
/// this repository (`oauth/huggingface-client.json`, served as JSON by
/// jsDelivr at a fixed tag), so no app has to be registered on anyone's
/// account. The browser step runs in the system's authentication session; the
/// app only receives the authorization code on `nodusreader://oauth/huggingface`.
enum HuggingFaceOAuth {
    static let clientID = "https://cdn.jsdelivr.net/gh/jorgepb96/nodus-reader@hf-oauth-v2/oauth/huggingface-client.json"
    static let callbackScheme = "nodusreader"
    static let redirectURI = "nodusreader://oauth/huggingface"
    /// Profile for "Signed in as …" and read access to public gated models
    /// whose licence the user accepted. No access to private repositories.
    static let scope = "openid profile gated-repos"
    static let authorizeEndpoint = URL(string: "https://huggingface.co/oauth/authorize")!
    static let tokenEndpoint = URL(string: "https://huggingface.co/oauth/token")!

    /// One sign-in attempt: the PKCE verifier and the anti-forgery state.
    struct Request: Sendable {
        let verifier: String
        let state: String

        init(verifier: String = HuggingFaceOAuth.randomURLSafeString(byteCount: 32),
             state: String = HuggingFaceOAuth.randomURLSafeString(byteCount: 16)) {
            self.verifier = verifier
            self.state = state
        }

        /// RFC 7636 S256: base64url(SHA-256(verifier)) without padding.
        var challenge: String {
            HuggingFaceOAuth.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        }

        var authorizeURL: URL {
            var components = URLComponents(url: HuggingFaceOAuth.authorizeEndpoint, resolvingAgainstBaseURL: false)!
            components.queryItems = [
                URLQueryItem(name: "client_id", value: HuggingFaceOAuth.clientID),
                URLQueryItem(name: "redirect_uri", value: HuggingFaceOAuth.redirectURI),
                URLQueryItem(name: "response_type", value: "code"),
                URLQueryItem(name: "scope", value: HuggingFaceOAuth.scope),
                URLQueryItem(name: "state", value: state),
                URLQueryItem(name: "code_challenge", value: challenge),
                URLQueryItem(name: "code_challenge_method", value: "S256")
            ]
            return components.url!
        }

        /// The authorization code from the callback, after checking that the
        /// callback answers this request.
        func code(from callback: URL) throws -> String {
            let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
            func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
            if let error = value("error") {
                throw HuggingFaceOAuthError.denied(value("error_description") ?? error)
            }
            guard value("state") == state else { throw HuggingFaceOAuthError.stateMismatch }
            guard let code = value("code"), !code.isEmpty else { throw HuggingFaceOAuthError.invalidResponse }
            return code
        }

        func tokenRequest(code: String) -> URLRequest {
            HuggingFaceOAuth.formRequest([
                "grant_type": "authorization_code",
                "code": code,
                "redirect_uri": HuggingFaceOAuth.redirectURI,
                "client_id": HuggingFaceOAuth.clientID,
                "code_verifier": verifier
            ])
        }
    }

    /// Tokens kept in this device's Keychain; never synced.
    struct Session: Codable, Equatable, Sendable {
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Date?
        var account: String?

        /// Refresh a minute early so a request never carries a token that
        /// expires in flight.
        func isExpired(now: Date = Date()) -> Bool {
            guard let expiresAt else { return false }
            return expiresAt.addingTimeInterval(-60) <= now
        }
    }

    static func refreshRequest(refreshToken: String) -> URLRequest {
        formRequest([
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID
        ])
    }

    /// Decodes a token endpoint response into a session.
    static func session(fromTokenResponse data: Data, previous: Session? = nil,
                        now: Date = Date()) throws -> Session {
        struct Response: Decodable {
            let access_token: String
            let refresh_token: String?
            let expires_in: Double?
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data),
              !response.access_token.isEmpty else {
            throw HuggingFaceOAuthError.invalidResponse
        }
        return Session(accessToken: response.access_token,
                       refreshToken: response.refresh_token ?? previous?.refreshToken,
                       expiresAt: response.expires_in.map { now.addingTimeInterval($0) },
                       account: previous?.account)
    }

    // MARK: Network

    static func exchange(code: String, for request: Request) async throws -> Session {
        try await send(request.tokenRequest(code: code), previous: nil)
    }

    static func refresh(_ session: Session) async throws -> Session {
        guard let refreshToken = session.refreshToken else { throw HuggingFaceOAuthError.expired }
        return try await send(refreshRequest(refreshToken: refreshToken), previous: session)
    }

    private static func send(_ request: URLRequest, previous: Session?) async throws -> Session {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw HuggingFaceOAuthError.invalidResponse }
        guard http.statusCode == 200 else {
            if previous != nil, http.statusCode == 400 || http.statusCode == 401 {
                throw HuggingFaceOAuthError.expired
            }
            throw HuggingFaceTokenError.rejected(http.statusCode)
        }
        return try session(fromTokenResponse: data, previous: previous)
    }

    // MARK: Helpers

    static func formRequest(_ fields: [String: String]) -> URLRequest {
        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        request.httpBody = Data(fields.sorted { $0.key < $1.key }.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&").utf8)
        return request
    }

    static func randomURLSafeString(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        if SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes) != errSecSuccess {
            bytes = (0..<byteCount).map { _ in UInt8.random(in: 0...255) }
        }
        return base64URL(Data(bytes))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

enum HuggingFaceOAuthError: LocalizedError, Equatable {
    case denied(String)
    case stateMismatch
    case invalidResponse
    case expired

    var errorDescription: String? {
        switch self {
        case .denied(let reason):
            String(localized: "Hugging Face did not authorise Nodus Reader: \(reason)")
        case .stateMismatch:
            String(localized: "The sign-in response did not match this request. Try again.")
        case .invalidResponse:
            String(localized: "Hugging Face returned an unexpected response.")
        case .expired:
            String(localized: "Your Hugging Face sign-in has expired. Sign in again.")
        }
    }
}

/// Keychain storage for the OAuth session, next to the pasted token.
enum HuggingFaceSessionStore {
    private static let service = "ai.nodus.reader.huggingface.oauth"

    static func load() -> HuggingFaceOAuth.Session? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(HuggingFaceOAuth.Session.self, from: data)
    }

    static func save(_ session: HuggingFaceOAuth.Session) throws {
        delete()
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: try JSONEncoder().encode(session)
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw HuggingFaceTokenError.keychain(status) }
    }

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// A usable access token from the OAuth session, refreshed if needed.
    /// A refresh that fails because the grant is gone signs the user out.
    static func validAccessToken() async throws -> String? {
        guard var session = load() else { return nil }
        if session.isExpired() {
            do {
                session = try await HuggingFaceOAuth.refresh(session)
                try save(session)
            } catch HuggingFaceOAuthError.expired {
                delete()
                throw HuggingFaceOAuthError.expired
            }
        }
        return session.accessToken
    }
}

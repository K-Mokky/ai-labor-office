import Foundation
import AppKit
import CryptoKit

// MARK: - Own OAuth token pair (CLI-independent quota refresh)

/// Access/refresh pair this app owns outright.
struct OAuthPair: Codable {
    var access: String
    var refresh: String
    var expires: Double   // ms since epoch
}

/// Stores and refreshes the app's *own* Anthropic OAuth tokens.
///
/// The CLIs' access tokens die within minutes-to-hours of their last run, and
/// their refresh tokens rotate on use — spending one from here would race the
/// CLI's own copy and could break its login. Linking the account instead gives
/// this app a separate token family: refreshing it touches nobody else's
/// credentials, so the 5h/7d quota keeps updating with no CLI open at all.
enum AccountTokenStore {
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let redirectURI = "https://console.anthropic.com/oauth/code/callback"
    static let tokenURL = URL(string: "https://console.anthropic.com/v1/oauth/token")!

    static var fileURL: URL { SnapshotIO.directory.appendingPathComponent("oauth.json") }

    private static let lock = NSLock()
    private static var lastRefreshFailure: Date?

    // MARK: File IO

    static func load() -> OAuthPair? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(OAuthPair.self, from: data)
    }

    static func save(_ pair: OAuthPair) {
        try? FileManager.default.createDirectory(at: SnapshotIO.directory,
                                                 withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(pair) else { return }
        try? data.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: fileURL.path)
    }

    static func delete() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: Access token (refreshing our own pair when expired)

    /// Synchronous on purpose: the rate-limit probe runs on a background queue.
    static func validAccessToken() -> String? {
        guard let pair = load() else { return nil }
        if fresh(pair) { return pair.access }

        lock.lock()
        defer { lock.unlock() }
        // Another probe may have refreshed while we waited on the lock.
        if let p = load(), fresh(p) { return p.access }
        // Don't hammer the token endpoint after a failure (revoked token, offline…).
        if let f = lastRefreshFailure, Date().timeIntervalSince(f) < 15 * 60 { return nil }
        guard let refreshed = requestTokenSync([
            "grant_type": "refresh_token",
            "refresh_token": pair.refresh,
            "client_id": clientID,
        ]) else {
            lastRefreshFailure = Date()
            return nil
        }
        lastRefreshFailure = nil
        save(refreshed)
        return refreshed.access
    }

    private static func fresh(_ pair: OAuthPair) -> Bool {
        Date(timeIntervalSince1970: pair.expires / 1000).timeIntervalSinceNow > 60
    }

    // MARK: Token endpoint

    static func parsePair(_ data: Data) -> OAuthPair? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = obj["access_token"] as? String,
              let refresh = obj["refresh_token"] as? String else { return nil }
        let expiresIn = obj["expires_in"] as? Double ?? 3600
        return OAuthPair(access: access, refresh: refresh,
                         expires: (Date().timeIntervalSince1970 + expiresIn) * 1000)
    }

    static func tokenRequest(_ body: [String: Any]) -> URLRequest {
        var req = URLRequest(url: tokenURL,
                             cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                             timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return req
    }

    private static func requestTokenSync(_ body: [String: Any]) -> OAuthPair? {
        var pair: OAuthPair?
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: tokenRequest(body)) { data, response, _ in
            if (response as? HTTPURLResponse)?.statusCode == 200, let data {
                pair = parsePair(data)
            }
            done.signal()
        }.resume()
        guard done.wait(timeout: .now() + 20) == .success else { return nil }
        return pair
    }
}

// MARK: - Login flow (browser + pasted code)

/// UI-facing state machine for linking the Claude account with OAuth + PKCE.
@MainActor
final class AccountAuth: ObservableObject {
    static let shared = AccountAuth()

    @Published private(set) var isConnected: Bool

    private var pendingVerifier: String?

    private init() {
        isConnected = AccountTokenStore.load() != nil
    }

    /// Opens the browser at the authorize URL; the callback page shows a
    /// "code#state" string the user pastes back into the popover.
    func beginLogin() {
        let verifier = Self.randomURLSafe(64)
        pendingVerifier = verifier
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        var comps = URLComponents(string: "https://claude.ai/oauth/authorize")!
        comps.queryItems = [
            .init(name: "code", value: "true"),
            .init(name: "client_id", value: AccountTokenStore.clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: AccountTokenStore.redirectURI),
            .init(name: "scope", value: "org:create_api_key user:profile user:inference"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: verifier),
        ]
        if let url = comps.url { NSWorkspace.shared.open(url) }
    }

    /// Exchanges the pasted "code#state" for our own token pair.
    func complete(code raw: String) async throws {
        guard let verifier = pendingVerifier else {
            throw Self.err("먼저 '브라우저에서 로그인'을 눌러주세요")
        }
        let parts = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "#")
        guard let code = parts.first, !code.isEmpty else {
            throw Self.err("코드가 비어 있습니다")
        }
        let req = AccountTokenStore.tokenRequest([
            "grant_type": "authorization_code",
            "code": code,
            "state": parts.count > 1 ? parts[1] : verifier,
            "client_id": AccountTokenStore.clientID,
            "redirect_uri": AccountTokenStore.redirectURI,
            "code_verifier": verifier,
        ])
        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let pair = AccountTokenStore.parsePair(data) else {
            throw Self.err("코드 교환에 실패했습니다. 로그인부터 다시 시도해주세요")
        }
        AccountTokenStore.save(pair)
        pendingVerifier = nil
        isConnected = true
    }

    func disconnect() {
        AccountTokenStore.delete()
        isConnected = false
    }

    // MARK: Helpers

    private static func randomURLSafe(_ bytes: Int) -> String {
        var buf = [UInt8](repeating: 0, count: bytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &buf)
        return base64URL(Data(buf))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func err(_ msg: String) -> Error {
        NSError(domain: "AccountAuth", code: 1,
                userInfo: [NSLocalizedDescriptionKey: msg])
    }
}

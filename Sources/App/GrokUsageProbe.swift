import Foundation

/// Grok's official weekly quota — the SuperGrok credits window shown on
/// grok.com / the Grok app, which a CLI OIDC token can also read.
///
/// Auth reuses the grok CLI's own OIDC token in `~/.grok/auth.json`. When the
/// stored access token has lapsed we refresh it exactly the way the grok CLI
/// does — an OIDC `refresh_token` grant against the issuer — and write the
/// rotated tokens back to `auth.json`, so the CLI keeps working and the quota
/// keeps updating even when grok has not been run for a while. `XAI_API_KEY`
/// is the last-resort fallback.
///
/// The report comes from `GET https://cli-chat-proxy.grok.com/v1/billing?format=credits`
/// (the `format=credits` form the CLI itself uses in `billing.rs`). Without that
/// query `/v1/billing` returns only the monthly *dollar* meter — all zeros on a
/// flat subscription — hiding the weekly quota. The credits form carries
/// `creditUsagePercent` (0…100 of the weekly allotment), a
/// `USAGE_PERIOD_TYPE_WEEKLY` window, and a per-product usage split. Grok has no
/// 5-hour session quota.
enum GrokUsageProbe {
    private static let creditsURL = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!
    private static let timeout: TimeInterval = 8

    /// A quota report is only interesting live, so keep no cache — matching
    /// how the Anthropic quota probe avoids a stale replay.
    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        cfg.urlCache = nil
        cfg.timeoutIntervalForRequest = timeout
        return URLSession(configuration: cfg)
    }()

    /// The live weekly credits meter, or `nil` when no token can be obtained or
    /// the report is unreadable. Synchronous: callers run on a background queue.
    static func fetch() -> GrokBilling? {
        guard let token = accessToken() else { return nil }
        return fetchLive(token: token)
    }

    // MARK: - Credentials

    private static var authPath: String { SnapshotIO.realHome + "/.grok/auth.json" }

    /// A usable access token: the stored one while still valid, a freshly
    /// refreshed one (persisted back for the CLI), else `XAI_API_KEY`.
    private static func accessToken() -> String? {
        if let data = FileManager.default.contents(atPath: authPath),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // auth.json holds one entry keyed by "<issuer>::<client_id>".
            for (key, value) in obj {
                guard let entry = value as? [String: Any],
                      let access = entry["key"] as? String, !access.isEmpty else { continue }
                let expiry = (entry["expires_at"] as? String).flatMap(parseDate)
                if let expiry, expiry.timeIntervalSinceNow > 60 { return access }
                // Expired (or unknown expiry): refresh like the CLI, else use as-is.
                if let refreshed = refresh(entry: entry, key: key, all: obj) { return refreshed }
                if expiry == nil { return access }
            }
        }
        let env = ProcessInfo.processInfo.environment["XAI_API_KEY"]
        return (env?.isEmpty == false) ? env : nil
    }

    /// Runs the OIDC `refresh_token` grant and writes the rotated tokens back to
    /// `auth.json` (atomic, `0600`) so the grok CLI stays logged in. Returns the
    /// new access token, or `nil` on any failure.
    private static func refresh(entry: [String: Any], key: String, all: [String: Any]) -> String? {
        guard let refreshToken = entry["refresh_token"] as? String, !refreshToken.isEmpty,
              let clientID = entry["oidc_client_id"] as? String,
              let issuer = entry["oidc_issuer"] as? String,
              let url = URL(string: issuer + "/oauth2/token") else { return nil }

        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = formBody([
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
        ])

        guard let obj = post(req),
              let access = obj["access_token"] as? String, !access.isEmpty else { return nil }

        var updated = entry
        updated["key"] = access
        if let rotated = obj["refresh_token"] as? String, !rotated.isEmpty {
            updated["refresh_token"] = rotated
        }
        let expiresIn = numberValue(obj["expires_in"]) ?? 21600
        updated["expires_at"] = isoTimestamp(Date().addingTimeInterval(expiresIn))
        updated["create_time"] = isoTimestamp(Date())

        var merged = all
        merged[key] = updated
        writeAuth(merged)
        return access
    }

    /// Atomically rewrites `auth.json`, restoring owner-only permissions.
    private static func writeAuth(_ obj: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted])
        else { return }
        let url = URL(fileURLWithPath: authPath)
        guard (try? data.write(to: url, options: .atomic)) != nil else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authPath)
    }

    // MARK: - Live report

    private static func fetchLive(token: String) -> GrokBilling? {
        var req = URLRequest(url: creditsURL,
                             cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                             timeoutInterval: timeout)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("xai-grok-cli", forHTTPHeaderField: "X-XAI-Token-Auth")

        guard let obj = post(req),
              let config = obj["config"] as? [String: Any],
              let percent = numberValue(config["creditUsagePercent"]) else { return nil }

        let period = config["currentPeriod"] as? [String: Any]
        let end = parseDate(period?["end"] as? String)
            ?? parseDate(config["billingPeriodEnd"] as? String)
        let start = parseDate(period?["start"] as? String)
            ?? parseDate(config["billingPeriodStart"] as? String)

        var products: [GrokProductUsage] = []
        for row in config["productUsage"] as? [[String: Any]] ?? [] {
            guard let name = row["product"] as? String, !name.isEmpty else { continue }
            products.append(GrokProductUsage(name: name, percent: numberValue(row["usagePercent"])))
        }

        return GrokBilling(usedPercent: percent, periodStart: start,
                           periodEnd: end, products: products, fetchedAt: Date())
    }

    // MARK: - HTTP + parsing helpers

    /// Runs a request synchronously and returns its 200 JSON object, else nil.
    private static func post(_ req: URLRequest) -> [String: Any]? {
        var result: [String: Any]?
        let done = DispatchSemaphore(value: 0)
        session.dataTask(with: req) { data, response, _ in
            if (response as? HTTPURLResponse)?.statusCode == 200, let data {
                result = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + timeout + 2)
        return result
    }

    /// `application/x-www-form-urlencoded` body; values are RFC3986 unreserved-escaped.
    private static func formBody(_ fields: [String: String]) -> Data? {
        let unreserved = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let body = fields.map { key, value in
            let v = value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
            return "\(key)=\(v)"
        }.joined(separator: "&")
        return body.data(using: .utf8)
    }

    private static func numberValue(_ any: Any?) -> Double? {
        switch any {
        case let d as Double: return d
        case let i as Int: return Double(i)
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s)
        default: return nil
        }
    }

    private static func isoTimestamp(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    /// Parses `2026-08-23T16:23:48.614414+00:00` (and the no-fraction variant).
    private static func parseDate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return withFraction.date(from: raw) ?? plain.date(from: raw)
    }
}

struct GrokProductUsage: Identifiable {
    var name: String        // "GrokBuild" | "GrokChat" | "GrokImagine"
    var percent: Double?    // 0…100 of the weekly allotment; nil == unused/not reported
    var id: String { name }
}

/// Grok's weekly SuperGrok credits meter. `usedPercent` is 0…100 of the weekly
/// allotment (`creditUsagePercent`).
struct GrokBilling {
    var usedPercent: Double
    var periodStart: Date?
    var periodEnd: Date?
    var products: [GrokProductUsage]
    var fetchedAt: Date

    /// 0…1 share of the weekly credits window.
    var fraction: Double { min(max(usedPercent / 100, 0), 1) }

    /// The weekly window the rest of the app already knows how to draw
    /// (`limitWindow("7d")` → 주간 카드 / 메뉴바 주간 채움). No 5h window: Grok
    /// has no session quota.
    var weeklyWindow: LimitWindow {
        LimitWindow(id: "7d", label: "Grok Weekly",
                    usedFraction: fraction, resetsAt: periodEnd, asOf: fetchedAt)
    }
}

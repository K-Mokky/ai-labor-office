import Foundation

/// Grok's (xAI) official usage/limit numbers — the ones normally only visible on
/// grok.com or in the Grok app — read the same way the CLI's billing page does.
///
/// Auth reuses the grok CLI's own OIDC access token in `~/.grok/auth.json`
/// (read-only: its refresh token is rotated solely by the grok CLI, so we never
/// spend it), or the `XAI_API_KEY` environment key as a fallback. The token is
/// only valid for a few hours; when it has lapsed we report nothing and the UI
/// falls back to the estimate derived from local `~/.grok` logs.
///
/// The endpoint is `GET https://cli-chat-proxy.grok.com/v1/billing`, which
/// returns the billing meter: dollars used against the monthly / on-demand cap
/// over the current billing period. The per-query rate limits the web app shows
/// live behind a grok.com *web session* — an OIDC bearer is rejected there with
/// `oauth2-auth-forbidden` — so the billing meter is what a CLI token can read.
enum GrokUsageProbe {
    private static let endpoint = URL(string: "https://cli-chat-proxy.grok.com/v1/billing")!
    private static let timeout: TimeInterval = 8

    /// A billing report is only interesting live, so keep no cache — matching
    /// how the Anthropic quota probe avoids a stale replay.
    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        cfg.urlCache = nil
        cfg.timeoutIntervalForRequest = timeout
        return URLSession(configuration: cfg)
    }()

    /// The live billing meter, or `nil` when no valid token exists or the report
    /// is unreadable. Synchronous on purpose: callers run on a background queue.
    static func fetch() -> GrokBilling? {
        guard let token = accessToken() else { return nil }
        return fetchLive(token: token)
    }

    // MARK: - Credentials (read-only)

    /// The grok CLI's access token while it is still valid, else `XAI_API_KEY`.
    /// `auth.json` holds one entry keyed by `"<issuer>::<client_id>"`; `.key` is
    /// the bearer JWT and `expires_at` its wall-clock expiry.
    private static func accessToken() -> String? {
        let path = SnapshotIO.realHome + "/.grok/auth.json"
        if let data = FileManager.default.contents(atPath: path),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for case let entry as [String: Any] in obj.values {
                guard let key = entry["key"] as? String, !key.isEmpty else { continue }
                // Skip an expired token rather than send a doomed request.
                if let raw = entry["expires_at"] as? String, let exp = parseDate(raw),
                   exp.timeIntervalSinceNow <= 60 { continue }
                return key
            }
        }
        let env = ProcessInfo.processInfo.environment["XAI_API_KEY"]
        return (env?.isEmpty == false) ? env : nil
    }

    // MARK: - Live report

    private static func fetchLive(token: String) -> GrokBilling? {
        var req = URLRequest(url: endpoint,
                             cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                             timeoutInterval: timeout)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("xai-grok-cli", forHTTPHeaderField: "X-XAI-Token-Auth")

        var payload: Data?
        let done = DispatchSemaphore(value: 0)
        session.dataTask(with: req) { data, response, _ in
            if (response as? HTTPURLResponse)?.statusCode == 200 { payload = data }
            done.signal()
        }.resume()

        guard done.wait(timeout: .now() + timeout + 2) == .success,
              let payload,
              let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let config = obj["config"] as? [String: Any]
        else { return nil }

        return GrokBilling(
            used: money(config["used"]),
            monthlyLimit: money(config["monthlyLimit"]),
            onDemandCap: money(config["onDemandCap"]),
            onDemandUsed: money(currentCycle(config)?["onDemandUsed"]),
            periodStart: parseDate(config["billingPeriodStart"] as? String),
            periodEnd: parseDate(config["billingPeriodEnd"] as? String),
            fetchedAt: Date()
        )
    }

    /// The `history` row for the period `billingPeriodStart` falls in, if any —
    /// its `onDemandUsed` is the spend that counts against `onDemandCap`.
    private static func currentCycle(_ config: [String: Any]) -> [String: Any]? {
        guard let history = config["history"] as? [[String: Any]],
              let start = parseDate(config["billingPeriodStart"] as? String) else { return nil }
        let cal = Calendar.current
        let year = cal.component(.year, from: start)
        let month = cal.component(.month, from: start)
        return history.first { row in
            guard let cycle = row["billingCycle"] as? [String: Any] else { return false }
            return (cycle["year"] as? Int) == year && (cycle["month"] as? Int) == month
        }
    }

    /// xAI money values arrive as `{ "val": <number> }`; `val` may decode as an
    /// Int, Double, NSNumber, or numeric string depending on the amount.
    private static func money(_ any: Any?) -> Double {
        guard let wrapped = any as? [String: Any] else { return 0 }
        switch wrapped["val"] {
        case let d as Double: return d
        case let i as Int: return Double(i)
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s) ?? 0
        default: return 0
        }
    }

    /// Parses `2026-09-01T00:00:00+00:00` (and the fractional-seconds variant).
    private static func parseDate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return withFraction.date(from: raw) ?? plain.date(from: raw)
    }
}

/// Grok's billing meter for the current period. Dollar amounts; a limit of `0`
/// means the account has no dollar cap of that kind (e.g. a flat subscription).
struct GrokBilling {
    var used: Double
    var monthlyLimit: Double
    var onDemandCap: Double
    var onDemandUsed: Double
    var periodStart: Date?
    var periodEnd: Date?
    var fetchedAt: Date

    /// The dollar ceiling that actually applies, if any: the monthly/included
    /// limit when set, otherwise the on-demand cap.
    var effectiveLimit: Double? {
        if monthlyLimit > 0 { return monthlyLimit }
        if onDemandCap > 0 { return onDemandCap }
        return nil
    }

    /// Share of the applicable limit spent this period (0…1), or `nil` when the
    /// account has no dollar cap to measure against.
    var fraction: Double? {
        guard let limit = effectiveLimit, limit > 0 else { return nil }
        return min(max(used / limit, 0), 1)
    }
}

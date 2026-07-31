import Foundation
import SQLite3

/// Reads the quota windows Anthropic actually enforces (rolling 5 hour / 7 day).
///
/// Those percentages are metered provider-side and are *not* derivable from the
/// local logs: the meter is not dollars, and the plan ceiling is never written
/// to disk. Estimating them from local history is what made the menu bar report
/// 30% of "biggest session ever" while the real 5h window sat at 96% used.
///
/// gjc already fetches the authoritative report from `/api/oauth/usage` and
/// keeps both the OAuth token and the last response in `~/.gjc/agent/agent.db`.
/// This reads that database read-only: the cached report is used as-is, and when
/// the stored access token is still valid the report is refreshed with a plain
/// GET. Nothing is ever written back and the refresh token is never exercised,
/// so gjc's own login is left untouched.
enum RateLimitProbe {
    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let betaHeader = "oauth-2025-04-20"
    private static let timeout: TimeInterval = 8

    /// A quota report is only ever interesting live. `URLSession.shared` caches
    /// this endpoint on disk and replays it, which froze the menu bar on a stale
    /// percentage for as long as the entry stayed fresh — hence a session that
    /// keeps no cache at all.
    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        cfg.urlCache = nil
        cfg.timeoutIntervalForRequest = timeout
        return URLSession(configuration: cfg)
    }()

    /// Empty when the report is unreadable; callers then keep their local fallback.
    static func fetch() -> [LimitWindow] {
        guard let db = openAgentDBCopy() else { return [] }
        defer {
            sqlite3_close(db.handle)
            try? FileManager.default.removeItem(at: db.tmp)
        }
        // gjc only refreshes its cache while it is running, so a live read wins
        // when the token allows one. The cache is the offline fallback.
        if let token = validToken(db.handle), let live = fetchLive(token: token) {
            return live
        }
        return cachedWindows(db.handle)
    }

    // MARK: - agent.db

    private struct OpenDB {
        let handle: OpaquePointer
        let tmp: URL
    }

    /// Copies the DB (+wal/shm) to a temp dir so we never contend with gjc's
    /// writer, mirroring how stats.db is read.
    private static func openAgentDBCopy() -> OpenDB? {
        let fm = FileManager.default
        let src = SnapshotIO.realHome + "/.gjc/agent/agent.db"
        guard fm.fileExists(atPath: src) else { return nil }

        let tmp = fm.temporaryDirectory
            .appendingPathComponent("aiusage-agent-\(getpid())", isDirectory: true)
        try? fm.removeItem(at: tmp)
        guard (try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)) != nil
        else { return nil }

        for suffix in ["", "-wal", "-shm"] {
            let s = src + suffix
            if fm.fileExists(atPath: s) {
                try? fm.copyItem(atPath: s,
                                 toPath: tmp.appendingPathComponent("agent.db" + suffix).path)
            }
        }

        var handle: OpaquePointer?
        let path = tmp.appendingPathComponent("agent.db").path
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let handle else {
            sqlite3_close(handle)
            try? fm.removeItem(at: tmp)
            return nil
        }
        return OpenDB(handle: handle, tmp: tmp)
    }

    /// Newest `usage_cache:report:*` row gjc has written.
    private static func cachedWindows(_ db: OpaquePointer) -> [LimitWindow] {
        var stmt: OpaquePointer?
        let sql = "SELECT value FROM cache WHERE key LIKE 'usage_cache:report:%'"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        var newest: (fetchedAt: Double, windows: [LimitWindow])?
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let ptr = sqlite3_column_text(stmt, 0),
                  let obj = try? JSONSerialization
                      .jsonObject(with: Data(String(cString: ptr).utf8)) as? [String: Any],
                  let value = obj["value"] as? [String: Any],
                  let entries = value["limits"] as? [[String: Any]]
            else { continue }

            let windows = entries.compactMap(window(fromCache:))
            let fetchedAt = value["fetchedAt"] as? Double ?? 0
            if !windows.isEmpty, fetchedAt >= (newest?.fetchedAt ?? -1) {
                newest = (fetchedAt, windows)
            }
        }
        return newest?.windows ?? []
    }

    private static func window(fromCache entry: [String: Any]) -> LimitWindow? {
        guard let rawID = entry["id"] as? String,
              let amount = entry["amount"] as? [String: Any],
              let used = amount["usedFraction"] as? Double
        else { return nil }

        let id = rawID.components(separatedBy: ":").last ?? rawID   // "anthropic:5h" -> "5h"
        guard id == "5h" || id == "7d" else { return nil }

        let resetsAt = (entry["window"] as? [String: Any])?["resetsAt"] as? Double
        return LimitWindow(id: id,
                           label: entry["label"] as? String ?? defaultLabel(id),
                           usedFraction: used,
                           resetsAt: resetsAt.map { Date(timeIntervalSince1970: $0 / 1000) })
    }

    /// Returns the stored access token only while it is still valid — renewing it
    /// rotates gjc's refresh token, which is not ours to spend.
    private static func validToken(_ db: OpaquePointer) -> String? {
        var stmt: OpaquePointer?
        let sql = """
            SELECT data FROM auth_credentials
            WHERE provider = 'anthropic' AND credential_type = 'oauth'
            """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let ptr = sqlite3_column_text(stmt, 0),
                  let obj = try? JSONSerialization
                      .jsonObject(with: Data(String(cString: ptr).utf8)) as? [String: Any],
                  let token = obj["access"] as? String,
                  let expires = obj["expires"] as? Double
            else { continue }
            guard Date(timeIntervalSince1970: expires / 1000).timeIntervalSinceNow > 60
            else { continue }
            return token
        }
        return nil
    }

    // MARK: - Live report

    /// Synchronous on purpose: callers already run on a background queue.
    private static func fetchLive(token: String) -> [LimitWindow]? {
        var req = URLRequest(url: endpoint,
                             cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                             timeoutInterval: timeout)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(betaHeader, forHTTPHeaderField: "anthropic-beta")

        var payload: Data?
        let done = DispatchSemaphore(value: 0)
        session.dataTask(with: req) { data, response, _ in
            if (response as? HTTPURLResponse)?.statusCode == 200 { payload = data }
            done.signal()
        }.resume()

        guard done.wait(timeout: .now() + timeout + 2) == .success,
              let payload,
              let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
        else { return nil }

        let windows: [LimitWindow] = [("5h", "five_hour"), ("7d", "seven_day")]
            .compactMap { id, key in
                guard let w = obj[key] as? [String: Any],
                      let percent = w["utilization"] as? Double else { return nil }
                return LimitWindow(id: id,
                                   label: defaultLabel(id),
                                   usedFraction: percent / 100,
                                   resetsAt: parseDate(w["resets_at"] as? String))
            }
        return windows.isEmpty ? nil : windows
    }

    /// `2026-07-31T18:19:59.537947+00:00` carries more fractional digits than
    /// ISO8601DateFormatter accepts, so the fraction is dropped before parsing.
    private static func parseDate(_ raw: String?) -> Date? {
        guard var s = raw else { return nil }
        if let dot = s.firstIndex(of: "."),
           let tz = s[dot...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) {
            s.removeSubrange(dot..<tz)
        }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    private static func defaultLabel(_ id: String) -> String {
        id == "5h" ? "Claude 5 Hour" : "Claude 7 Day"
    }
}

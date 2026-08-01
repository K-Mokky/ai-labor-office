import Foundation
import SQLite3

/// Reads the quota windows Anthropic actually enforces (rolling 5 hour / 7 day).
///
/// Those percentages are metered provider-side and are *not* derivable from the
/// local logs: the meter is not dollars, and the plan ceiling is never written
/// to disk. Estimating them from local history is what made the menu bar report
/// 30% of "biggest session ever" while the real 5h window sat at 96% used.
///
/// The report comes from `/api/oauth/usage`, authenticated with the first
/// working access token among: the app's own linked account (refreshable
/// without any CLI — see `AccountTokenStore`), gjc's token in
/// `~/.gjc/agent/agent.db`, and Claude Code's token (Keychain item
/// "Claude Code-credentials" or `~/.claude/.credentials.json`). CLI stores are
/// only ever read: their refresh tokens rotate on use, so exercising one here
/// could break the CLI's own login. When every token is dead, gjc's cached
/// report is used and stamped with its fetch time so the UI can show staleness.
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
        let db = openAgentDBCopy()
        defer {
            if let db {
                sqlite3_close(db.handle)
                try? FileManager.default.removeItem(at: db.tmp)
            }
        }

        // Candidate tokens, most durable first; the first one the API accepts wins.
        var tokens: [String] = []
        if let t = AccountTokenStore.validAccessToken() { tokens.append(t) }  // linked account
        if let db, let t = validToken(db.handle) { tokens.append(t) }         // gjc CLI
        if let t = claudeCodeToken() { tokens.append(t) }                     // Claude Code CLI
        for token in tokens {
            if let live = fetchLive(token: token) { return live }
        }
        // Every token is dead → gjc's cached report, stamped so the UI can
        // say how old the numbers are instead of presenting them as live.
        return db.map { cachedWindows($0.handle) } ?? []
    }

    // MARK: - Claude Code credentials (read-only)

    /// Claude Code's own access token, when still valid. macOS default storage
    /// is the Keychain; `~/.claude/.credentials.json` is the file fallback.
    /// Read via the `security` CLI, which created the item and therefore sits
    /// in its ACL — no permission prompt, and nothing is ever written back.
    private static func claudeCodeToken() -> String? {
        for raw in [keychainClaudeCreds(), fileClaudeCreds()] {
            guard let raw,
                  let obj = try? JSONSerialization
                      .jsonObject(with: Data(raw.utf8)) as? [String: Any],
                  let oauth = obj["claudeAiOauth"] as? [String: Any],
                  let token = oauth["accessToken"] as? String,
                  let expires = oauth["expiresAt"] as? Double,
                  Date(timeIntervalSince1970: expires / 1000).timeIntervalSinceNow > 60
            else { continue }
            return token
        }
        return nil
    }

    private static func keychainClaudeCreds() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func fileClaudeCreds() -> String? {
        let path = SnapshotIO.realHome + "/.claude/.credentials.json"
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return String(data: data, encoding: .utf8)
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

            let fetchedAt = value["fetchedAt"] as? Double ?? 0
            let asOf = fetchedAt > 0 ? Date(timeIntervalSince1970: fetchedAt / 1000) : nil
            let windows = entries.compactMap(window(fromCache:)).map { w in
                var w = w
                w.asOf = asOf
                return w
            }
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

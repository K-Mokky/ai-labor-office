import Foundation
import SwiftUI
import SQLite3
import WidgetKit

struct UsageEvent {
    let ts: Date
    let model: String
    let tokens: Int
    let cost: Double
    let provider: String
}

final class UsageStore: ObservableObject {
    @Published var connections: [AIConnection]
    @Published var snapshots: [String: UsageSnapshot] = [:]  // connection id → snapshot
    @Published var combined: UsageSnapshot?                  // all connections (widgets)
    @Published var grokBilling: GrokBilling?                 // xAI billing meter (grok only)
    @Published var lastError: String?
    @Published var lastRefresh: Date?

    private var timer: Timer?
    /// Refresh runs on a background queue and can take a while on the first
    /// codex scan; the 60s timer must not stack a second pass on top of it.
    private var refreshInFlight = false
    private var refreshQueued = false

    init() {
        connections = ConnectionStore.load()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    // MARK: - Connection management

    func addConnection(source: SourceKind, color: Color) {
        guard !connections.contains(where: { $0.source == source }) else { return }
        connections.append(AIConnection(id: UUID().uuidString,
                                        source: source,
                                        name: source.defaultName,
                                        colorHex: color.hexRGB,
                                        metricKey: "session"))
        ConnectionStore.save(connections)
        refresh()
    }

    func removeConnection(id: String) {
        connections.removeAll { $0.id == id }
        snapshots[id] = nil
        ConnectionStore.save(connections)
        refresh()
    }

    func updateConnection(_ c: AIConnection) {
        guard let i = connections.firstIndex(where: { $0.id == c.id }) else { return }
        connections[i] = c
        ConnectionStore.save(connections)
    }

    // MARK: - Refresh

    func refresh() {
        guard !refreshInFlight else { refreshQueued = true; return }
        refreshInFlight = true
        let conns = connections
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var errors: [String] = []
            var bySource: [SourceKind: [UsageEvent]] = [:]
            // ChatGPT quota logged by Codex CLI alongside its usage events.
            var gptLimits: [LimitWindow] = []
            for source in Set(conns.map(\.source)) {
                switch source {
                case .gjc:
                    do { bySource[.gjc] = try Self.loadGJCStats() }
                    catch { errors.append("gjc: \(error.localizedDescription)") }
                case .claudeCode:
                    bySource[.claudeCode] = Self.loadClaudeProjects()
                case .codex:
                    let codex = Self.loadCodexSessions()
                    bySource[.codex] = codex.events
                    gptLimits = codex.limits
                case .gemini:
                    bySource[.gemini] = Self.loadGeminiSessions()
                case .cursor:
                    bySource[.cursor] = Self.loadCursorSessions()
                case .grok:
                    do { bySource[.grok] = try Self.loadGrokUsage() }
                    catch { errors.append("grok: \(error.localizedDescription)") }
                }
            }

            let now = Date()
            // Provider-enforced 5h/7d quotas — only worth the network round-trip
            // (and the Keychain/agent.db reads it does) when a Claude-backed
            // connection can actually display them. A grok/gemini/cursor-only
            // setup skipped this and stopped probing Anthropic every 60s.
            let wantsClaudeQuota = conns.contains {
                $0.source == .claudeCode || $0.source == .gjc
            }
            let claudeLimits = wantsClaudeQuota ? RateLimitProbe.fetch() : []
            // Grok's official billing meter, only when a Grok connection wants it.
            let grokBilling = conns.contains { $0.source == .grok }
                ? GrokUsageProbe.fetch() : nil
            var snaps: [String: UsageSnapshot] = [:]
            for c in conns {
                snaps[c.id] = Self.aggregate(events: bySource[c.source] ?? [],
                                             now: now, claudeLimits: claudeLimits,
                                             gptLimits: gptLimits)
            }
            let combined = Self.aggregate(events: bySource.values.flatMap { $0 },
                                          now: now, claudeLimits: claudeLimits,
                                          gptLimits: gptLimits)

            // Widgets can show the combined view or a single source.
            var payload = WidgetPayload(combined: combined)
            for c in conns {
                payload.sources[c.source.rawValue] = snaps[c.id]
                payload.names[c.source.rawValue] = c.name
            }

            DispatchQueue.main.async {
                self.refreshInFlight = false
                self.snapshots = snaps
                self.combined = combined
                self.grokBilling = grokBilling
                self.lastError = errors.isEmpty ? nil : errors.joined(separator: " / ")
                self.lastRefresh = Date()
                try? SnapshotIO.save(combined)          // legacy single-snapshot file
                try? SnapshotIO.savePayload(payload)
                WidgetCenter.shared.reloadAllTimelines()
                if self.refreshQueued {      // e.g. a connection changed mid-scan
                    self.refreshQueued = false
                    self.refresh()
                }
            }
        }
    }

    // MARK: - GJC stats.db (SQLite)

    enum StoreError: LocalizedError {
        case sqlite(String)
        var errorDescription: String? {
            switch self { case .sqlite(let m): return m }
        }
    }

    /// Copies a SQLite db (+wal/shm) to a temp dir — so reads never contend
    /// with the CLI writing it, and WAL reads work even without a live writer
    /// having set up the shm — then runs `body` on the open copy.
    static func withSQLiteCopy<T>(of src: String, label: String,
                                  _ body: (OpaquePointer) throws -> T) throws -> T {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
            .appendingPathComponent("aiusage-\(label)-\(getpid())", isDirectory: true)
        try? fm.removeItem(at: tmp)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        let name = (src as NSString).lastPathComponent
        for suffix in ["", "-wal", "-shm"] where fm.fileExists(atPath: src + suffix) {
            try? fm.copyItem(atPath: src + suffix,
                             toPath: tmp.appendingPathComponent(name + suffix).path)
        }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(tmp.appendingPathComponent(name).path, &handle,
                              SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db = handle else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(handle)
            throw StoreError.sqlite(msg)
        }
        defer { sqlite3_close(db) }
        return try body(db)
    }

    static func loadGJCStats() throws -> [UsageEvent] {
        let fm = FileManager.default
        let src = SnapshotIO.realHome + "/.gjc/stats.db"
        let sessionsRoot = SnapshotIO.realHome + "/.gjc/agent/sessions"
        guard fm.fileExists(atPath: src) else {
            // No stats.db yet — read usage straight from the session logs.
            return loadGJCSessionEvents(root: sessionsRoot, offsets: [:])
        }

        let (events, offsets) = try withSQLiteCopy(of: src, label: "gjc") { db in
            var stmt: OpaquePointer?
            var hasProvider = true
            let sql = "SELECT timestamp, model, total_tokens, cost_total, provider FROM messages"
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
                hasProvider = false
                let legacy = "SELECT timestamp, model, total_tokens, cost_total FROM messages"
                guard sqlite3_prepare_v2(db, legacy, -1, &stmt, nil) == SQLITE_OK else {
                    throw StoreError.sqlite(String(cString: sqlite3_errmsg(db)))
                }
            }
            defer { sqlite3_finalize(stmt) }

            var events: [UsageEvent] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let tsMs = sqlite3_column_int64(stmt, 0)
                guard let mPtr = sqlite3_column_text(stmt, 1) else { continue }
                let model = String(cString: mPtr)
                let tokens = Int(sqlite3_column_int64(stmt, 2))
                let cost = sqlite3_column_double(stmt, 3)
                let provider = hasProvider
                    ? sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? ""
                    : ""
                events.append(UsageEvent(
                    ts: Date(timeIntervalSince1970: Double(tsMs) / 1000),
                    model: model, tokens: tokens, cost: cost, provider: provider
                ))
            }

            var offsets: [String: UInt64] = [:]
            var offStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT session_file, offset FROM file_offsets", -1, &offStmt, nil) == SQLITE_OK {
                while sqlite3_step(offStmt) == SQLITE_ROW {
                    if let p = sqlite3_column_text(offStmt, 0) {
                        offsets[String(cString: p)] = UInt64(sqlite3_column_int64(offStmt, 1))
                    }
                }
            }
            sqlite3_finalize(offStmt)
            return (events, offsets)
        }
        // stats.db is a cache that gjc refreshes only occasionally, so it can
        // lag live usage by days. Parse whatever each session log appended past
        // the recorded ingestion offset so today/week/session include current use.
        return events + loadGJCSessionEvents(root: sessionsRoot, offsets: offsets)
    }

    /// Parses gjc session JSONL under `root`, skipping the byte prefix of each
    /// file already ingested into stats.db (per its `file_offsets` table).
    /// Offsets sit on line boundaries, so a tail read yields whole lines; a
    /// half-written final line simply fails JSON parsing and is skipped.
    static func loadGJCSessionEvents(root: String, offsets: [String: UInt64]) -> [UsageEvent] {
        let fm = FileManager.default
        guard let en = fm.enumerator(atPath: root) else { return [] }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()

        var byID: [String: UsageEvent] = [:]
        var anonymous: [UsageEvent] = []

        for case let rel as String in en where rel.hasSuffix(".jsonl") {
            let path = root + "/" + rel
            let start = offsets[path] ?? 0
            guard let fh = FileHandle(forReadingAtPath: path) else { continue }
            defer { try? fh.close() }
            guard let end = try? fh.seekToEnd(), end > start else { continue }
            try? fh.seek(toOffset: start)
            guard let data = try? fh.readToEnd(),
                  let text = String(data: data, encoding: .utf8) else { continue }

            for line in text.split(separator: "\n") {
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      obj["type"] as? String == "message",
                      let msg = obj["message"] as? [String: Any],
                      msg["role"] as? String == "assistant",
                      let model = msg["model"] as? String,
                      let usage = msg["usage"] as? [String: Any],
                      let tsStr = (obj["timestamp"] as? String) ?? (msg["timestamp"] as? String),
                      let ts = iso.date(from: tsStr) ?? isoPlain.date(from: tsStr)
                else { continue }

                let input = usage["input"] as? Int ?? 0
                let output = usage["output"] as? Int ?? 0
                let cacheRead = usage["cacheRead"] as? Int ?? 0
                let cacheWrite = usage["cacheWrite"] as? Int ?? 0
                let tokens = usage["totalTokens"] as? Int
                    ?? (input + output + cacheRead + cacheWrite)
                guard tokens > 0 else { continue }

                let cost = ((usage["cost"] as? [String: Any])?["total"] as? Double)
                    ?? estimateCost(model: model, input: input, output: output,
                                    cacheRead: cacheRead, cacheWrite: cacheWrite)
                let ev = UsageEvent(ts: ts, model: model, tokens: tokens, cost: cost,
                                    provider: msg["provider"] as? String ?? "")
                if let id = obj["id"] as? String {
                    byID[id] = ev
                } else {
                    anonymous.append(ev)
                }
            }
        }
        return Array(byID.values) + anonymous
    }

    // MARK: - Claude Code project JSONL

    static func loadClaudeProjects() -> [UsageEvent] {
        let fm = FileManager.default
        let root = SnapshotIO.realHome + "/.claude/projects"
        guard let en = fm.enumerator(atPath: root) else { return [] }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()

        // Streaming rewrites entries with the same message id; keep the last one.
        var byMessageID: [String: UsageEvent] = [:]
        var anonymous: [UsageEvent] = []

        for case let rel as String in en where rel.hasSuffix(".jsonl") {
            guard let data = fm.contents(atPath: root + "/" + rel),
                  let text = String(data: data, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      obj["type"] as? String == "assistant",
                      let msg = obj["message"] as? [String: Any],
                      let model = msg["model"] as? String,
                      model != "<synthetic>",
                      let usage = msg["usage"] as? [String: Any],
                      let tsStr = obj["timestamp"] as? String,
                      let ts = iso.date(from: tsStr) ?? isoPlain.date(from: tsStr)
                else { continue }

                let input = usage["input_tokens"] as? Int ?? 0
                let output = usage["output_tokens"] as? Int ?? 0
                let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
                let cacheWrite = usage["cache_creation_input_tokens"] as? Int ?? 0
                let tokens = input + output + cacheRead + cacheWrite
                guard tokens > 0 else { continue }

                let cost = (obj["costUSD"] as? Double)
                    ?? estimateCost(model: model, input: input, output: output,
                                    cacheRead: cacheRead, cacheWrite: cacheWrite)
                let ev = UsageEvent(ts: ts, model: model, tokens: tokens, cost: cost,
                                    provider: "anthropic")
                if let id = msg["id"] as? String {
                    byMessageID[id] = ev
                } else {
                    anonymous.append(ev)
                }
            }
        }
        return Array(byMessageID.values) + anonymous
    }

    // MARK: - Codex CLI rollout JSONL

    struct CodexData {
        var events: [UsageEvent]
        var limits: [LimitWindow]
    }

    /// Parses `~/.codex/sessions/**/rollout-*.jsonl`. Each turn appends an
    /// `event_msg`/`token_count` line whose `last_token_usage` is that
    /// response's tokens; those sum to local usage. The same line also carries
    /// the ChatGPT plan quota (`rate_limits.used_percent`) metered by the
    /// provider — the newest one becomes the GPT 5h/weekly limit windows.
    ///
    /// The sessions dir grows into gigabytes, so results are cached per file
    /// keyed by byte size: rollouts are append-only, meaning an unchanged size
    /// is an unchanged file. Only new/grown files are re-parsed each refresh.
    private struct CodexFileCache {
        var size: UInt64
        var events: [UsageEvent]
        var newestLimits: (ts: Date, windows: [LimitWindow])?
    }
    private static var codexCache: [String: CodexFileCache] = [:]

    static func loadCodexSessions() -> CodexData {
        let fm = FileManager.default
        let root = SnapshotIO.realHome + "/.codex/sessions"
        guard let en = fm.enumerator(atPath: root) else { return CodexData(events: [], limits: []) }

        var events: [UsageEvent] = []
        var newestLimits: (ts: Date, windows: [LimitWindow])?
        func offerLimits(_ candidate: (ts: Date, windows: [LimitWindow])?) {
            if let c = candidate, newestLimits == nil || c.ts > newestLimits!.ts {
                newestLimits = c
            }
        }

        for case let rel as String in en where rel.hasSuffix(".jsonl") {
            let path = root + "/" + rel
            let size = (try? fm.attributesOfItem(atPath: path)[.size] as? UInt64) ?? 0
            if let cached = codexCache[path], cached.size == size, size > 0 {
                events += cached.events
                offerLimits(cached.newestLimits)
                continue
            }
            let parsed = parseCodexRollout(path: path)
            codexCache[path] = CodexFileCache(size: size, events: parsed.events,
                                              newestLimits: parsed.newestLimits)
            events += parsed.events
            offerLimits(parsed.newestLimits)
        }
        // A window whose reset already passed describes an expired quota
        // period; showing it as current would be wrong, so drop it and let
        // percentages fall back to local history.
        let live = (newestLimits?.windows ?? []).filter { ($0.resetsAt ?? .distantFuture) > Date() }
        return CodexData(events: events, limits: live)
    }

    private static func parseCodexRollout(path: String)
        -> (events: [UsageEvent], newestLimits: (ts: Date, windows: [LimitWindow])?) {
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8) else { return ([], nil) }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()

        var events: [UsageEvent] = []
        var newestLimits: (ts: Date, windows: [LimitWindow])?
        var model = "gpt"   // rollouts name the model in turn_context lines

        for line in text.split(separator: "\n") {
            // Cheap prefilter: only two of the many line kinds matter.
            guard line.contains("\"token_count\"") || line.contains("\"turn_context\"")
            else { continue }
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let payload = obj["payload"] as? [String: Any] else { continue }

            if obj["type"] as? String == "turn_context" {
                if let m = payload["model"] as? String { model = m }
                continue
            }
            guard payload["type"] as? String == "token_count",
                  let tsStr = obj["timestamp"] as? String,
                  let ts = iso.date(from: tsStr) ?? isoPlain.date(from: tsStr)
            else { continue }

            if let info = payload["info"] as? [String: Any],
               let last = info["last_token_usage"] as? [String: Any] {
                let input = last["input_tokens"] as? Int ?? 0        // includes cached
                let cached = last["cached_input_tokens"] as? Int ?? 0
                let output = last["output_tokens"] as? Int ?? 0      // includes reasoning
                let tokens = last["total_tokens"] as? Int ?? (input + output)
                if tokens > 0 {
                    let cost = estimateCost(model: model, input: max(0, input - cached),
                                            output: output, cacheRead: cached, cacheWrite: 0)
                    events.append(UsageEvent(ts: ts, model: model, tokens: tokens,
                                             cost: cost, provider: "openai"))
                }
            }
            if let rl = payload["rate_limits"] as? [String: Any],
               newestLimits == nil || ts > newestLimits!.ts {
                let windows = codexWindows(rl, asOf: ts)
                if !windows.isEmpty { newestLimits = (ts, windows) }
            }
        }
        return (events, newestLimits)
    }

    /// `primary` is the rolling 5h window, `secondary` the weekly one. Only
    /// those two sizes map onto the app's 5h/7d slots; other plans (e.g. the
    /// free tier's 30-day window) don't fit and are dropped.
    private static func codexWindows(_ rl: [String: Any], asOf: Date) -> [LimitWindow] {
        func window(_ key: String) -> LimitWindow? {
            guard let w = rl[key] as? [String: Any],
                  let used = w["used_percent"] as? Double,
                  let minutes = w["window_minutes"] as? Int else { return nil }
            let id: String, label: String
            switch minutes {
            case ...360: (id, label) = ("5h", "GPT 5 Hour")
            case 10080: (id, label) = ("7d", "GPT Weekly")
            default: return nil
            }
            let resets = (w["resets_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
                ?? (w["resets_in_seconds"] as? Double).map { asOf.addingTimeInterval($0) }
            return LimitWindow(id: id, label: label, usedFraction: used / 100,
                               resetsAt: resets, asOf: asOf)
        }
        var out: [LimitWindow] = []
        if let p = window("primary") { out.append(p) }
        if let s = window("secondary"), !out.contains(where: { $0.id == s.id }) { out.append(s) }
        return out
    }

    // MARK: - Gemini CLI session JSON

    /// Parses `~/.gemini/tmp/<project>/chats/session-*.json`. Each "gemini"
    /// message carries its model and token counts. Checkpoint subfolders under
    /// chats/ hold resaved copies of the same messages, so only files sitting
    /// directly in chats/ count; message ids dedupe the rest.
    static func loadGeminiSessions() -> [UsageEvent] {
        let fm = FileManager.default
        let root = SnapshotIO.realHome + "/.gemini/tmp"
        guard let en = fm.enumerator(atPath: root) else { return [] }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()

        var byID: [String: UsageEvent] = [:]
        var anonymous: [UsageEvent] = []

        for case let rel as String in en {
            let comps = rel.split(separator: "/")
            guard comps.count >= 2, comps[comps.count - 2] == "chats",
                  let name = comps.last, name.hasPrefix("session-"), name.hasSuffix(".json")
            else { continue }
            guard let data = fm.contents(atPath: root + "/" + rel),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let messages = obj["messages"] as? [[String: Any]] else { continue }

            for m in messages {
                guard m["type"] as? String == "gemini",
                      let tok = m["tokens"] as? [String: Any],
                      let tsStr = m["timestamp"] as? String,
                      let ts = iso.date(from: tsStr) ?? isoPlain.date(from: tsStr)
                else { continue }

                let input = tok["input"] as? Int ?? 0        // includes cached
                let cached = tok["cached"] as? Int ?? 0
                let output = tok["output"] as? Int ?? 0
                let thoughts = tok["thoughts"] as? Int ?? 0
                let tool = tok["tool"] as? Int ?? 0
                let tokens = tok["total"] as? Int ?? (input + output + thoughts + tool)
                guard tokens > 0 else { continue }

                let model = m["model"] as? String ?? "gemini"
                let cost = estimateCost(model: model, input: max(0, input - cached),
                                        output: output + thoughts,
                                        cacheRead: cached, cacheWrite: 0)
                let ev = UsageEvent(ts: ts, model: model, tokens: tokens, cost: cost,
                                    provider: "google")
                if let id = m["id"] as? String { byID[id] = ev } else { anonymous.append(ev) }
            }
        }
        return Array(byID.values) + anonymous
    }

    // MARK: - Cursor agent transcripts

    /// Parses `~/.cursor/projects/**/agent-transcripts/**` — conversation
    /// transcripts written by cursor-agent (Cursor CLI and the IDE's background
    /// agents). Cursor records no token counts locally, so tokens are estimated
    /// from text length (~4 chars/token) and cost from those estimates. The
    /// model comes from Cursor's ai-code-tracking.db summaries when present,
    /// and every turn in a session shares the session's last-update timestamp
    /// (per-turn timestamps don't exist either).
    static func loadCursorSessions() -> [UsageEvent] {
        let fm = FileManager.default
        let root = SnapshotIO.realHome + "/.cursor/projects"
        guard let en = fm.enumerator(atPath: root) else { return [] }

        let summaries = loadCursorSummaries()

        // Composer-2 sessions ship a .jsonl and sometimes a .txt render of the
        // same turns; prefer the jsonl and drop its .txt twin.
        var rels: [String] = []
        var jsonlStems = Set<String>()
        for case let rel as String in en where rel.contains("agent-transcripts/") {
            if rel.hasSuffix(".jsonl") {
                rels.append(rel)
                jsonlStems.insert(String(rel.dropLast(6)))
            } else if rel.hasSuffix(".txt") {
                rels.append(rel)
            }
        }

        var events: [UsageEvent] = []
        for rel in rels {
            if rel.hasSuffix(".txt"), jsonlStems.contains(String(rel.dropLast(4))) { continue }
            let path = root + "/" + rel
            guard let data = fm.contents(atPath: path),
                  let text = String(data: data, encoding: .utf8) else { continue }

            let stem = ((rel as NSString).lastPathComponent as NSString).deletingPathExtension
            let summary = summaries[stem]
            let model = summary?.model ?? "cursor-auto"
            let ts = summary?.updatedAt
                ?? ((try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date)
                ?? Date()

            let turns = rel.hasSuffix(".jsonl") ? cursorJSONLTurns(text) : cursorTextTurns(text)
            for t in turns {
                let input = t.inputChars / 4
                let output = t.outputChars / 4
                guard input + output > 0 else { continue }
                let cost = estimateCost(model: model, input: input, output: output,
                                        cacheRead: 0, cacheWrite: 0)
                events.append(UsageEvent(ts: ts, model: model, tokens: input + output,
                                         cost: cost, provider: "cursor"))
            }
        }
        return events
    }

    private struct CursorSummary {
        var model: String?
        var updatedAt: Date?
    }

    /// Conversation metadata Cursor keeps in ai-code-tracking.db, keyed by the
    /// transcript's filename stem (conversationId).
    private static func loadCursorSummaries() -> [String: CursorSummary] {
        let src = SnapshotIO.realHome + "/.cursor/ai-tracking/ai-code-tracking.db"
        guard FileManager.default.fileExists(atPath: src) else { return [:] }
        return (try? withSQLiteCopy(of: src, label: "cursor") { db in
            var stmt: OpaquePointer?
            let sql = "SELECT conversationId, model, updatedAt FROM conversation_summaries"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [:] }
            defer { sqlite3_finalize(stmt) }
            var out: [String: CursorSummary] = [:]
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let idPtr = sqlite3_column_text(stmt, 0) else { continue }
                let ms = sqlite3_column_int64(stmt, 2)
                out[String(cString: idPtr)] = CursorSummary(
                    model: sqlite3_column_text(stmt, 1).map { String(cString: $0) },
                    updatedAt: ms > 0 ? Date(timeIntervalSince1970: Double(ms) / 1000) : nil)
            }
            return out
        }) ?? [:]
    }

    private struct CursorTurn {
        var inputChars = 0
        var outputChars = 0
    }

    /// JSONL transcript: `{role, message: {content: [{type: text|tool_use}]}}`.
    private static func cursorJSONLTurns(_ text: String) -> [CursorTurn] {
        var turns: [CursorTurn] = []
        var pendingInput = 0
        for line in text.split(separator: "\n") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let role = obj["role"] as? String,
                  let msg = obj["message"] as? [String: Any] else { continue }
            let chars = (msg["content"] as? [[String: Any]] ?? []).reduce(0) { sum, block in
                (block["type"] as? String) == "text"
                    ? sum + ((block["text"] as? String)?.count ?? 0) : sum
            }
            if role == "user" {
                pendingInput += chars
            } else if role == "assistant" {
                turns.append(CursorTurn(inputChars: pendingInput, outputChars: chars))
                pendingInput = 0
            }
        }
        return turns
    }

    /// Legacy text transcript: "user: ..." / "A: ..." blocks with [Thinking],
    /// [Tool call], [Tool result] markers. Tool lines carry no model text and
    /// are skipped; [Thinking] lines are reasoning output and count.
    private static func cursorTextTurns(_ text: String) -> [CursorTurn] {
        var turns: [CursorTurn] = []
        var pendingInput = 0
        var chars = 0
        var mode = 0   // 0 none, 1 user, 2 assistant
        func flush() {
            if mode == 1 { pendingInput += chars }
            if mode == 2 {
                turns.append(CursorTurn(inputChars: pendingInput, outputChars: chars))
                pendingInput = 0
            }
            chars = 0
        }
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.lowercased().hasPrefix("user:") {
                flush(); mode = 1; chars = line.count - 5
            } else if line.hasPrefix("A:") {
                flush(); mode = 2; chars = line.count - 2
            } else if mode == 2, line.hasPrefix("[Tool call]") || line.hasPrefix("[Tool result]") {
                continue
            } else if mode != 0 {
                chars += line.count
            }
        }
        flush()
        return turns
    }

    // MARK: - Grok (~/.grok)

    /// Grok usage exists in two layouts under `~/.grok`, depending on the CLI:
    /// the open-source grok-cli logs real token counts into `grok.db`
    /// (`usage_events` table, WAL SQLite), while xAI Grok Build writes
    /// official per-inference counts to `logs/unified.jsonl`. Sessions that
    /// never appear in those logs (rotated away, or older builds) fall back
    /// to estimating from the `_meta.totalTokens` curve in `updates.jsonl`.
    static func loadGrokUsage() throws -> [UsageEvent] {
        var events: [UsageEvent] = []
        let db = SnapshotIO.realHome + "/.grok/grok.db"
        if FileManager.default.fileExists(atPath: db) {
            events = try loadGrokDB(db)
        }
        let official = loadGrokOfficialLogs()
        events += official.events
        events += loadGrokBuildSessions(excluding: official.sessions)
        return events
    }

    /// `shell.turn.inference_done` lines from Grok Build. `prompt_tokens`
    /// already includes the cache hit; `completion_tokens` includes reasoning.
    private static func loadGrokOfficialLogs() -> (events: [UsageEvent], sessions: Set<String>) {
        let fm = FileManager.default
        let logDir = SnapshotIO.realHome + "/.grok/logs"
        guard let names = try? fm.contentsOfDirectory(atPath: logDir) else {
            return ([], [])
        }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        let models = grokSessionModels()

        var events: [UsageEvent] = []
        var sessions: Set<String> = []
        for name in names where name.hasSuffix(".jsonl") {
            guard let data = fm.contents(atPath: logDir + "/" + name),
                  let text = String(data: data, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                guard line.contains("inference_done"),
                      line.contains("prompt_tokens"),
                      let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      obj["msg"] as? String == "shell.turn.inference_done",
                      let ctx = obj["ctx"] as? [String: Any] else { continue }

                let prompt = jsonInt(ctx["prompt_tokens"])
                let cached = min(jsonInt(ctx["cached_prompt_tokens"]), prompt)
                let output = jsonInt(ctx["completion_tokens"])
                let tokens = prompt + output
                guard tokens > 0 else { continue }

                let tsStr = obj["ts"] as? String ?? ""
                let ts = iso.date(from: tsStr) ?? isoPlain.date(from: tsStr) ?? Date()
                let sid = obj["sid"] as? String ?? ""
                if !sid.isEmpty { sessions.insert(sid) }
                let model = models[sid] ?? "grok"
                let cost = estimateCost(model: model,
                                        input: max(0, prompt - cached),
                                        output: output,
                                        cacheRead: cached,
                                        cacheWrite: 0)
                events.append(UsageEvent(ts: ts, model: model, tokens: tokens,
                                         cost: cost, provider: "xai"))
            }
        }
        return (events, sessions)
    }

    private static func grokSessionModels() -> [String: String] {
        let fm = FileManager.default
        let root = SnapshotIO.realHome + "/.grok/sessions"
        guard let cwds = try? fm.contentsOfDirectory(atPath: root) else { return [:] }
        var models: [String: String] = [:]
        for cwd in cwds {
            let cwdPath = root + "/" + cwd
            guard let sessions = try? fm.contentsOfDirectory(atPath: cwdPath) else { continue }
            for session in sessions {
                guard let data = fm.contents(atPath: cwdPath + "/" + session + "/summary.json"),
                      let summary = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let model = summary["current_model_id"] as? String,
                      !model.isEmpty else { continue }
                models[session] = model
            }
        }
        return models
    }

    private static func jsonInt(_ any: Any?) -> Int {
        if let i = any as? Int { return i }
        if let n = any as? NSNumber { return n.intValue }
        if let d = any as? Double { return Int(d) }
        if let s = any as? String { return Int(s) ?? 0 }
        return 0
    }

    private static func loadGrokDB(_ src: String) throws -> [UsageEvent] {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        return try withSQLiteCopy(of: src, label: "grok") { db in
            var stmt: OpaquePointer?
            let sql = "SELECT created_at, model, input_tokens, output_tokens, total_tokens, cost_micros FROM usage_events"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw StoreError.sqlite(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            var events: [UsageEvent] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let tsPtr = sqlite3_column_text(stmt, 0) else { continue }
                let tsStr = String(cString: tsPtr)
                guard let ts = iso.date(from: tsStr) ?? isoPlain.date(from: tsStr) else { continue }
                let model = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? "grok"
                let input = Int(sqlite3_column_int64(stmt, 2))
                let output = Int(sqlite3_column_int64(stmt, 3))
                let tokens = max(Int(sqlite3_column_int64(stmt, 4)), input + output)
                guard tokens > 0 else { continue }
                let micros = sqlite3_column_double(stmt, 5)
                let cost = micros > 0
                    ? micros / 1_000_000    // cost_micros is micro-dollars
                    : estimateCost(model: model, input: input, output: output,
                                   cacheRead: 0, cacheWrite: 0)
                events.append(UsageEvent(ts: ts, model: model, tokens: tokens,
                                         cost: cost, provider: "xai"))
            }
            return events
        }
    }

    /// Fallback for Grok Build sessions that never got an official
    /// `inference_done` line. `updates.jsonl` carries a running
    /// `_meta.totalTokens` per streamed chunk but no billable split.
    /// Each turn (promptId) re-sends the grown context, so the unique
    /// context (peak summed per compaction segment) counts once as
    /// fresh input, the re-sent remainder as cache reads, and per-turn
    /// growth as output.
    private static func loadGrokBuildSessions(excluding covered: Set<String> = []) -> [UsageEvent] {
        let fm = FileManager.default
        let root = SnapshotIO.realHome + "/.grok/sessions"
        guard let cwds = try? fm.contentsOfDirectory(atPath: root) else { return [] }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()

        var events: [UsageEvent] = []
        for cwd in cwds {
            let cwdPath = root + "/" + cwd
            guard let sessions = try? fm.contentsOfDirectory(atPath: cwdPath) else { continue }
            for session in sessions {
                if covered.contains(session) { continue }
                let dir = cwdPath + "/" + session
                guard let sumData = fm.contents(atPath: dir + "/summary.json"),
                      let summary = try? JSONSerialization.jsonObject(with: sumData) as? [String: Any],
                      let updData = fm.contents(atPath: dir + "/updates.jsonl"),
                      let updates = String(data: updData, encoding: .utf8) else { continue }

                let (input, cacheRead, output) = grokBuildTokens(updates)
                guard input + output > 0 else { continue }

                let model = summary["current_model_id"] as? String ?? "grok"
                let tsStr = (summary["updated_at"] as? String)
                    ?? (summary["last_active_at"] as? String)
                    ?? (summary["created_at"] as? String) ?? ""
                let ts = iso.date(from: tsStr) ?? isoPlain.date(from: tsStr)
                    ?? ((try? fm.attributesOfItem(atPath: dir + "/updates.jsonl"))?[.modificationDate] as? Date)
                    ?? Date()
                let cost = estimateCost(model: model, input: input, output: output,
                                        cacheRead: cacheRead, cacheWrite: 0)
                events.append(UsageEvent(ts: ts, model: model,
                                         tokens: input + cacheRead + output,
                                         cost: cost, provider: "xai"))
            }
        }
        return events
    }

    private static func grokBuildTokens(_ text: String) -> (input: Int, cacheRead: Int, output: Int) {
        var turns: [String: (first: Int, last: Int)] = [:]
        var prevTotal = -1
        var segmentPeak = 0
        var inputFresh = 0
        for line in text.split(separator: "\n") {
            guard line.contains("\"totalTokens\""),
                  let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let params = obj["params"] as? [String: Any],
                  let meta = params["_meta"] as? [String: Any],
                  let total = meta["totalTokens"] as? Int else { continue }
            // A big drop means the context was compacted; close the segment so
            // pre-compaction context still counts as fresh input.
            if prevTotal >= 0, total < prevTotal / 2 {
                inputFresh += segmentPeak
                segmentPeak = 0
            }
            segmentPeak = max(segmentPeak, total)
            prevTotal = total
            if let promptId = meta["promptId"] as? String {
                if var t = turns[promptId] { t.last = total; turns[promptId] = t }
                else { turns[promptId] = (total, total) }
            }
        }
        inputFresh += segmentPeak
        var sumFirst = 0, output = 0
        for t in turns.values {
            sumFirst += t.first
            output += max(0, t.last - t.first)
        }
        return (inputFresh, max(0, sumFirst - inputFresh), output)
    }

    /// Rough public API pricing per million tokens, matched by model family substring.
    static func estimateCost(model: String, input: Int, output: Int, cacheRead: Int, cacheWrite: Int) -> Double {
        let m = model.lowercased()
        let (i, o, cr, cw): (Double, Double, Double, Double)
        if m.contains("gpt") || m.contains("codex")
            || m.hasPrefix("o1") || m.hasPrefix("o3") || m.hasPrefix("o4") {
            (i, o, cr, cw) = (1.25, 10, 0.125, 0)                            // gpt-5 family
        }
        else if m.contains("gemini") {
            (i, o, cr, cw) = m.contains("flash") ? (0.3, 2.5, 0.03, 0)
                                                 : (1.25, 10, 0.125, 0)      // pro
        }
        else if m.contains("grok") {
            (i, o, cr, cw) = m.contains("mini") ? (0.3, 0.5, 0.03, 0)
                           : m.contains("4.20") ? (2, 6, 0.2, 0)
                                                : (1.25, 2.5, 0.125, 0)      // grok-4 family
        }
        else if m.contains("composer") || m.contains("cursor") {
            (i, o, cr, cw) = (1.25, 10, 0.125, 0)                            // cursor composer
        }
        else if m.contains("opus") { (i, o, cr, cw) = (15, 75, 1.5, 18.75) }
        else if m.contains("haiku") { (i, o, cr, cw) = (0.8, 4, 0.08, 1) }
        else { (i, o, cr, cw) = (3, 15, 0.3, 3.75) } // sonnet & default
        return (Double(input) * i + Double(output) * o
                + Double(cacheRead) * cr + Double(cacheWrite) * cw) / 1_000_000
    }

    // MARK: - Aggregation

    /// The `ProviderKind` carrying the most cost across `events` (ties and an
    /// all-zero-cost set fall back to event count, then `.generic`).
    static func dominantProvider(_ events: [UsageEvent]) -> ProviderKind {
        guard !events.isEmpty else { return .generic }
        var costByKind: [ProviderKind: Double] = [:]
        var countByKind: [ProviderKind: Int] = [:]
        for e in events {
            let kind = ProviderKind.detect(provider: e.provider, model: e.model)
            costByKind[kind, default: 0] += Swift.max(e.cost, 0)
            countByKind[kind, default: 0] += 1
        }
        if let best = costByKind.max(by: { $0.value < $1.value }), best.value > 0 {
            return best.key
        }
        return countByKind.max(by: { $0.value < $1.value })?.key ?? .generic
    }

    static func aggregate(events: [UsageEvent], now: Date = Date(),
                          claudeLimits: [LimitWindow] = [],
                          gptLimits: [LimitWindow] = []) -> UsageSnapshot {
        let cal = Calendar.current
        let todayKey = dayKeyFormatter.string(from: now)
        let weekStart = cal.date(byAdding: .day, value: -6, to: cal.startOfDay(for: now))!

        var totalCost = 0.0, todayCost = 0.0, weekCost = 0.0
        var totalTokens = 0, todayTokens = 0, weekTokens = 0
        var totalMessages = 0
        var days: [String: DayUsage] = [:]
        var models: [String: ModelUsage] = [:]

        for e in events {
            totalCost += e.cost
            totalTokens += e.tokens
            totalMessages += 1

            let key = dayKeyFormatter.string(from: e.ts)
            var d = days[key] ?? DayUsage(date: key, cost: 0, tokens: 0, messages: 0)
            d.cost += e.cost; d.tokens += e.tokens; d.messages += 1
            days[key] = d

            if key == todayKey { todayCost += e.cost; todayTokens += e.tokens }
            if e.ts >= weekStart { weekCost += e.cost; weekTokens += e.tokens }

            var m = models[e.model] ?? ModelUsage(id: e.model, name: prettyModelName(e.model),
                                                  cost: 0, tokens: 0, messages: 0)
            m.cost += e.cost; m.tokens += e.tokens; m.messages += 1
            models[e.model] = m
        }

        // 5-hour session blocks (Claude-style billing blocks).
        let blockLen: TimeInterval = 5 * 3600
        struct Block { var start: Date; var cost: Double; var tokens: Int; var last: Date }

        let sorted = events.sorted { $0.ts < $1.ts }
        var blocks: [Block] = []
        for e in sorted {
            if var b = blocks.last,
               e.ts.timeIntervalSince(b.start) < blockLen,
               e.ts.timeIntervalSince(b.last) < blockLen {
                b.cost += e.cost; b.tokens += e.tokens; b.last = e.ts
                blocks[blocks.count - 1] = b
            } else {
                var comps = cal.dateComponents([.year, .month, .day, .hour], from: e.ts)
                comps.minute = 0; comps.second = 0
                blocks.append(Block(start: cal.date(from: comps) ?? e.ts,
                                    cost: e.cost, tokens: e.tokens, last: e.ts))
            }
        }

        var sessionCost = 0.0
        var sessionTokens = 0
        var sessionStart: Date?
        var sessionEnd: Date?
        var activeBlock = false
        if let b = blocks.last {
            let end = b.start.addingTimeInterval(blockLen)
            if now < end && now.timeIntervalSince(b.last) < blockLen {
                sessionCost = b.cost
                sessionTokens = b.tokens
                sessionStart = b.start
                sessionEnd = end
                activeBlock = true
            }
        }
        // Percent baseline: the biggest block ever completed (excluding the live one).
        let history = activeBlock ? blocks.dropLast() : blocks[...]
        let sessionMaxCost = history.map(\.cost).max() ?? 0
        let sessionMaxTokens = history.map(\.tokens).max() ?? 0

        // Attribute the quota to the provider that dominates this event set by
        // cost, not merely whichever event happened most recently: one stray
        // event of another provider must not flip which quota the snapshot
        // reports (this matters most for the merged "all connections" view).
        let provider = dominantProvider(events)
        // Quotas belong to the provider account and are shared by every client
        // billing to it: Anthropic's 5h/7d windows apply to any Claude-backed
        // connection, the ChatGPT plan windows to any GPT-backed one.
        let quota: [LimitWindow]
        switch provider {
        case .claude: quota = claudeLimits
        case .gpt: quota = gptLimits
        default: quota = []
        }

        return UsageSnapshot(
            generatedAt: now,
            totalCost: totalCost, totalTokens: totalTokens, totalMessages: totalMessages,
            todayCost: todayCost, todayTokens: todayTokens,
            weekCost: weekCost, weekTokens: weekTokens,
            sessionCost: sessionCost, sessionTokens: sessionTokens,
            sessionStart: sessionStart, sessionEnd: sessionEnd,
            sessionMaxCost: sessionMaxCost, sessionMaxTokens: sessionMaxTokens,
            provider: provider.rawValue,
            limits: quota.isEmpty ? nil : quota,
            models: models.values.sorted { $0.cost > $1.cost },
            days: days.values.sorted { $0.date < $1.date }
        )
    }
}

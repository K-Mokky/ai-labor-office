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
    @Published var lastError: String?
    @Published var lastRefresh: Date?

    private var timer: Timer?

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
        let conns = connections
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var errors: [String] = []
            var bySource: [SourceKind: [UsageEvent]] = [:]
            for source in Set(conns.map(\.source)) {
                switch source {
                case .gjc:
                    do { bySource[.gjc] = try Self.loadGJCStats() }
                    catch { errors.append("gjc: \(error.localizedDescription)") }
                case .claudeCode:
                    bySource[.claudeCode] = Self.loadClaudeProjects()
                }
            }

            let now = Date()
            // Provider-enforced 5h/7d quotas; empty when unreadable.
            let limits = RateLimitProbe.fetch()
            var snaps: [String: UsageSnapshot] = [:]
            for c in conns {
                snaps[c.id] = Self.aggregate(events: bySource[c.source] ?? [],
                                             now: now, limits: limits)
            }
            let combined = Self.aggregate(events: bySource.values.flatMap { $0 },
                                          now: now, limits: limits)

            // Widgets can show the combined view or a single source.
            var payload = WidgetPayload(combined: combined)
            for c in conns {
                payload.sources[c.source.rawValue] = snaps[c.id]
                payload.names[c.source.rawValue] = c.name
            }

            DispatchQueue.main.async {
                self.snapshots = snaps
                self.combined = combined
                self.lastError = errors.isEmpty ? nil : errors.joined(separator: " / ")
                self.lastRefresh = Date()
                try? SnapshotIO.save(combined)          // legacy single-snapshot file
                try? SnapshotIO.savePayload(payload)
                WidgetCenter.shared.reloadAllTimelines()
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

    static func loadGJCStats() throws -> [UsageEvent] {
        let fm = FileManager.default
        let src = SnapshotIO.realHome + "/.gjc/stats.db"
        let sessionsRoot = SnapshotIO.realHome + "/.gjc/agent/sessions"
        guard fm.fileExists(atPath: src) else {
            // No stats.db yet — read usage straight from the session logs.
            return loadGJCSessionEvents(root: sessionsRoot, offsets: [:])
        }

        // Copy db (+wal/shm) to a temp dir so we never contend with the writer
        // and WAL reads work even without a live writer having set up the shm.
        let tmp = fm.temporaryDirectory.appendingPathComponent("aiusage-db-\(getpid())", isDirectory: true)
        try? fm.removeItem(at: tmp)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        for suffix in ["", "-wal", "-shm"] {
            let s = src + suffix
            if fm.fileExists(atPath: s) {
                try? fm.copyItem(atPath: s, toPath: tmp.appendingPathComponent("stats.db" + suffix).path)
            }
        }

        var db: OpaquePointer?
        let path = tmp.appendingPathComponent("stats.db").path
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(db)
            throw StoreError.sqlite(msg)
        }
        defer { sqlite3_close(db) }

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
        // stats.db is a cache that gjc refreshes only occasionally, so it can
        // lag live usage by days. Parse whatever each session log appended past
        // the recorded ingestion offset so today/week/session include current use.
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

    /// Rough public API pricing per million tokens, matched by model family substring.
    static func estimateCost(model: String, input: Int, output: Int, cacheRead: Int, cacheWrite: Int) -> Double {
        let m = model.lowercased()
        let (i, o, cr, cw): (Double, Double, Double, Double)
        if m.contains("opus") { (i, o, cr, cw) = (15, 75, 1.5, 18.75) }
        else if m.contains("haiku") { (i, o, cr, cw) = (0.8, 4, 0.08, 1) }
        else { (i, o, cr, cw) = (3, 15, 0.3, 3.75) } // sonnet & default
        return (Double(input) * i + Double(output) * o
                + Double(cacheRead) * cr + Double(cacheWrite) * cw) / 1_000_000
    }

    // MARK: - Aggregation

    static func aggregate(events: [UsageEvent], now: Date = Date(),
                          limits: [LimitWindow] = []) -> UsageSnapshot {
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

        let provider = ProviderKind.detect(provider: sorted.last?.provider,
                                           model: sorted.last?.model)
        // The 5h/7d quotas belong to the Anthropic account and are shared by
        // every client billing to it, so they apply to any Claude-backed
        // connection — but never to a GPT/generic one.
        let quota = provider == .claude ? limits : []

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

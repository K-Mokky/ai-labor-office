import Foundation

// MARK: - Core data types (shared between app and widget)

struct DayUsage: Codable, Hashable {
    var date: String        // "yyyy-MM-dd" in local time zone
    var cost: Double
    var tokens: Int
    var messages: Int
}

struct ModelUsage: Codable, Identifiable, Hashable {
    var id: String          // raw model id, e.g. "claude-fable-5"
    var name: String        // pretty name, e.g. "Fable 5"
    var cost: Double
    var tokens: Int
    var messages: Int
}

/// One provider-enforced quota window — Anthropic's rolling 5h / 7d limits.
/// These percentages are metered by the provider and cannot be reproduced from
/// local cost logs, so they are read from the provider rather than estimated.
struct LimitWindow: Codable, Hashable, Identifiable {
    var id: String              // "5h" | "7d"
    var label: String           // "Claude 5 Hour"
    var usedFraction: Double    // 0…1, where 1 == quota exhausted
    var resetsAt: Date?
    /// When the report backing this window was fetched. `nil` == live fetch;
    /// an old date means the value is a stale cache fallback.
    var asOf: Date? = nil
}

struct UsageSnapshot: Codable {
    var generatedAt: Date

    var totalCost: Double
    var totalTokens: Int
    var totalMessages: Int

    var todayCost: Double
    var todayTokens: Int

    var weekCost: Double
    var weekTokens: Int

    var sessionCost: Double
    var sessionTokens: Int
    var sessionStart: Date?
    var sessionEnd: Date?

    var sessionMaxCost: Double?     // historical max 5h-block (percent baseline)
    var sessionMaxTokens: Int?

    var provider: String?           // "claude" | "gpt" | "generic"

    /// Provider-enforced quota windows. `nil` when they could not be read, in
    /// which case percentages fall back to local history.
    var limits: [LimitWindow]? = nil

    var models: [ModelUsage]
    var days: [DayUsage]

    var dayMap: [String: DayUsage] {
        Dictionary(uniqueKeysWithValues: days.map { ($0.date, $0) })
    }
}

// MARK: - Display metric selection

enum UnitKind: String, CaseIterable {
    case percent
    case cost
    case tokens

    var title: String {
        switch self {
        case .percent: return "사용률(%)"
        case .cost: return "비용($)"
        case .tokens: return "토큰"
        }
    }
}

enum MetricKind: Hashable {
    case total
    case today
    case week
    case session
    case model(String)

    var key: String {
        switch self {
        case .total: return "total"
        case .today: return "today"
        case .week: return "week"
        case .session: return "session"
        case .model(let id): return "model:\(id)"
        }
    }

    static func from(key: String) -> MetricKind {
        if key.hasPrefix("model:") { return .model(String(key.dropFirst(6))) }
        switch key {
        case "total": return .total
        case "today": return .today
        case "week": return .week
        default: return .session
        }
    }

    func title(in snapshot: UsageSnapshot?) -> String {
        switch self {
        case .total: return "전체 사용량"
        case .today: return "오늘 사용량"
        case .week: return "주간 사용량"
        case .session: return "세션 사용량"
        case .model(let id):
            let name = snapshot?.models.first(where: { $0.id == id })?.name ?? id
            return "\(name) 사용량"
        }
    }

    /// Short prefix used in the menu bar label.
    func shortPrefix(in snapshot: UsageSnapshot?) -> String {
        switch self {
        case .total: return "전체"
        case .today: return "오늘"
        case .week: return "주간"
        case .session: return "세션"
        case .model(let id):
            let name = snapshot?.models.first(where: { $0.id == id })?.name ?? id
            return name.components(separatedBy: " ").first ?? name
        }
    }

    func value(in snapshot: UsageSnapshot?, unit: UnitKind) -> String {
        guard let s = snapshot else { return "—" }
        if unit == .percent {
            return s.fraction(for: self).map(fmtPercent) ?? "—"
        }
        let (cost, tokens): (Double, Int)
        switch self {
        case .total: (cost, tokens) = (s.totalCost, s.totalTokens)
        case .today: (cost, tokens) = (s.todayCost, s.todayTokens)
        case .week: (cost, tokens) = (s.weekCost, s.weekTokens)
        case .session: (cost, tokens) = (s.sessionCost, s.sessionTokens)
        case .model(let id):
            let m = s.models.first(where: { $0.id == id })
            (cost, tokens) = (m?.cost ?? 0, m?.tokens ?? 0)
        }
        switch unit {
        case .percent: return "—" // handled above
        case .cost: return fmtCost(cost)
        case .tokens: return fmtTokens(tokens)
        }
    }
}

// MARK: - Formatting

func fmtCost(_ v: Double) -> String {
    if v >= 10_000 { return String(format: "$%.1fk", v / 1000) }
    if v >= 1000 { return String(format: "$%.2fk", v / 1000) }
    if v >= 100 { return String(format: "$%.0f", v) }
    if v >= 10 { return String(format: "$%.1f", v) }
    return String(format: "$%.2f", v)
}

func fmtTokens(_ n: Int) -> String {
    let v = Double(n)
    if v >= 1_000_000_000 { return String(format: "%.2fB", v / 1_000_000_000) }
    if v >= 1_000_000 { return String(format: "%.1fM", v / 1_000_000) }
    if v >= 1_000 { return String(format: "%.1fK", v / 1_000) }
    return "\(n)"
}

func fmtPercent(_ f: Double) -> String {
    String(format: "%.0f%%", f * 100)
}

/// Time left until `date`, coarsened for glanceable UI: "1일 13시간", "3시간 24분", "12분".
func fmtRemaining(_ date: Date) -> String {
    let mins = max(0, Int(date.timeIntervalSinceNow / 60))
    if mins >= 1440 { return "\(mins / 1440)일 \((mins % 1440) / 60)시간" }
    if mins >= 60 { return "\(mins / 60)시간 \(mins % 60)분" }
    return "\(mins)분"
}
/// How long ago `date` was, coarsened: "방금", "5분 전", "3시간 전", "2일 전".
func fmtAgo(_ date: Date) -> String {
    let mins = max(0, Int(Date().timeIntervalSince(date) / 60))
    if mins < 1 { return "방금" }
    if mins < 60 { return "\(mins)분 전" }
    if mins < 1440 { return "\(mins / 60)시간 전" }
    return "\(mins / 1440)일 전"
}

func prettyModelName(_ id: String) -> String {
    let parts = id.split(separator: "-").map(String.init)
    guard !parts.isEmpty else { return id }

    // "claude-fable-5" -> "Fable 5", "claude-opus-4-8" -> "Opus 4.8"
    if parts.first?.lowercased() == "claude" {
        let rest = Array(parts.dropFirst())
        guard let first = rest.first else { return id }
        let family = first.prefix(1).uppercased() + first.dropFirst()
        let nums = rest.dropFirst().filter { Int($0) != nil }
        if nums.isEmpty { return family }
        return "\(family) \(nums.joined(separator: "."))"
    }

    // "gpt-5.2-codex" -> "GPT 5.2 Codex", "gemini-3.1-pro-preview" -> "Gemini 3.1 Pro"
    let noise: Set<String> = ["preview", "latest", "exp", "001", "002"]
    let kept = parts.filter { !noise.contains($0.lowercased()) }
    let words = (kept.isEmpty ? parts : kept).map { p -> String in
        if p.lowercased() == "gpt" { return "GPT" }
        if p.first?.isNumber == true { return p }
        return p.prefix(1).uppercased() + p.dropFirst()
    }
    return words.joined(separator: " ")
}

// MARK: - Percent (usage vs historical max) & provider

extension UsageSnapshot {
    var providerKind: ProviderKind { ProviderKind(rawValue: provider ?? "") ?? .generic }

    var maxDayCost: Double { days.map(\.cost).max() ?? 0 }

    /// Max cost over any rolling 7-day window in history.
    var maxWeekCost: Double {
        let pts = days.compactMap { d in dayKeyFormatter.date(from: d.date).map { ($0, d.cost) } }
            .sorted { $0.0 < $1.0 }
        var best = 0.0, sum = 0.0
        var j = 0
        for i in 0..<pts.count {
            sum += pts[i].1
            while pts[i].0.timeIntervalSince(pts[j].0) > 6.5 * 86400 {
                sum -= pts[j].1
                j += 1
            }
            best = Swift.max(best, sum)
        }
        return best
    }

    /// The provider-enforced window with `id` ("5h" / "7d"), when it was readable.
    func limitWindow(_ id: String) -> LimitWindow? {
        limits?.first { $0.id == id }
    }

    /// Usage fraction shown by the percent unit.
    ///
    /// Session and week report the provider's real quota, so 1.0 means the
    /// quota is spent. Only when that is unavailable do they fall back to local
    /// history, where 1.0 merely matches the heaviest stretch on record.
    /// nil when there is no baseline to compare against.
    func fraction(for metric: MetricKind) -> Double? {
        switch metric {
        case .session:
            if let w = limitWindow("5h") { return w.usedFraction }
            guard let m = sessionMaxCost, m > 0 else { return nil }
            return sessionCost / m
        case .today:
            let m = maxDayCost
            return m > 0 ? todayCost / m : nil
        case .week:
            if let w = limitWindow("7d") { return w.usedFraction }
            let m = maxWeekCost
            return m > 0 ? weekCost / m : nil
        case .total:
            return nil
        case .model(let id):
            guard totalCost > 0, let mu = models.first(where: { $0.id == id }) else { return nil }
            return mu.cost / totalCost
        }
    }
}

let dayKeyFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = .current
    return f
}()

// MARK: - Snapshot IO (app writes, widget reads)

enum SnapshotIO {
    /// Real user home, even inside a sandboxed extension container.
    static var realHome: String {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return String(cString: dir)
        }
        return NSHomeDirectory()
    }

    static var directory: URL {
        let support = URL(fileURLWithPath: realHome)
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        let current = support.appendingPathComponent("AI Labor Office", isDirectory: true)
        let legacy = support.appendingPathComponent("AIUsage", isDirectory: true)
        let fm = FileManager.default
        if fm.fileExists(atPath: current.path) { return current }
        // App: move the old folder so tokens/snapshots/icons keep working.
        // Sandboxed widget: the move fails, so we keep reading the legacy path
        // (also listed in widget.entitlements) until the app has migrated it.
        if fm.fileExists(atPath: legacy.path) {
            try? fm.moveItem(at: legacy, to: current)
            if fm.fileExists(atPath: current.path) { return current }
            return legacy
        }
        return current
    }

    static var fileURL: URL { directory.appendingPathComponent("snapshot.json") }

    static func save(_ snapshot: UsageSnapshot) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys]
        let data = try enc.encode(snapshot)
        try data.write(to: fileURL, options: .atomic)
    }

    static func load() -> UsageSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(UsageSnapshot.self, from: data)
    }
}

// MARK: - Widget configuration & payload (app writes, widget reads)

/// Per-widget display settings, configured from the app's popover.
/// (AppIntents-based in-widget editing needs Xcode's metadata processor, which
/// this swiftc-only build doesn't have — so widgets are configured in the app.)
struct WidgetConfig: Codable, Equatable {
    /// "all" for every connection combined, or a `SourceKind` rawValue.
    var source: String
    /// "cost" | "tokens" — the primary number widgets display.
    var unit: String

    init(source: String = "all", unit: String = "cost") {
        self.source = source
        self.unit = unit
    }

    init(from decoder: Decoder) throws {
        let c = try? decoder.container(keyedBy: CodingKeys.self)
        source = (try? c?.decode(String.self, forKey: .source)) ?? "all"
        unit = (try? c?.decode(String.self, forKey: .unit)) ?? "cost"
    }

    var unitKind: UnitKind { unit == "tokens" ? .tokens : .cost }
}

/// Settings for the four widget kinds, persisted as one JSON file.
struct WidgetConfigs: Codable, Equatable {
    var contribution = WidgetConfig()
    var summary = WidgetConfig()
    var models = WidgetConfig()
    var session = WidgetConfig()

    init() {}

    init(from decoder: Decoder) throws {
        let c = try? decoder.container(keyedBy: CodingKeys.self)
        contribution = (try? c?.decode(WidgetConfig.self, forKey: .contribution)) ?? WidgetConfig()
        summary = (try? c?.decode(WidgetConfig.self, forKey: .summary)) ?? WidgetConfig()
        models = (try? c?.decode(WidgetConfig.self, forKey: .models)) ?? WidgetConfig()
        session = (try? c?.decode(WidgetConfig.self, forKey: .session)) ?? WidgetConfig()
    }

    func config(for kind: String) -> WidgetConfig {
        switch kind {
        case "contribution": return contribution
        case "summary": return summary
        case "models": return models
        case "session": return session
        default: return WidgetConfig()
        }
    }

    mutating func set(_ config: WidgetConfig, for kind: String) {
        switch kind {
        case "contribution": contribution = config
        case "summary": summary = config
        case "models": models = config
        case "session": session = config
        default: break
        }
    }
}

/// Everything widgets can render: the combined snapshot plus one per source.
struct WidgetPayload: Codable {
    var combined: UsageSnapshot?
    var sources: [String: UsageSnapshot] = [:]  // SourceKind rawValue → snapshot
    var names: [String: String] = [:]           // SourceKind rawValue → display name

    func snapshot(for config: WidgetConfig) -> UsageSnapshot? {
        config.source == "all" ? combined : (sources[config.source] ?? combined)
    }

    /// Display name of the selected source; nil for the combined view.
    func name(for config: WidgetConfig) -> String? {
        config.source == "all" ? nil : names[config.source]
    }
}

extension SnapshotIO {
    static var payloadURL: URL { directory.appendingPathComponent("widget-data.json") }
    static var widgetConfigURL: URL { directory.appendingPathComponent("widget-config.json") }

    static func savePayload(_ payload: WidgetPayload) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys]
        try enc.encode(payload).write(to: payloadURL, options: .atomic)
    }

    static func loadPayload() -> WidgetPayload? {
        guard let data = try? Data(contentsOf: payloadURL) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(WidgetPayload.self, from: data)
    }

    static func saveWidgetConfigs(_ configs: WidgetConfigs) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(configs) {
            try? data.write(to: widgetConfigURL, options: .atomic)
        }
    }

    static func loadWidgetConfigs() -> WidgetConfigs {
        guard let data = try? Data(contentsOf: widgetConfigURL),
              let configs = try? JSONDecoder().decode(WidgetConfigs.self, from: data)
        else { return WidgetConfigs() }
        return configs
    }
}

// MARK: - Placeholder (widget gallery preview)

extension UsageSnapshot {
    static var placeholder: UsageSnapshot {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var days: [DayUsage] = []
        for i in 0..<180 {
            guard let d = cal.date(byAdding: .day, value: -i, to: today) else { continue }
            let seed = (i * 37 + 11) % 17
            let cost = seed < 5 ? 0 : Double(seed) * 1.7
            days.append(DayUsage(date: dayKeyFormatter.string(from: d),
                                 cost: cost, tokens: Int(cost * 90_000), messages: seed))
        }
        return UsageSnapshot(
            generatedAt: Date(),
            totalCost: 698.68, totalTokens: 434_490_000, totalMessages: 4444,
            todayCost: 12.34, todayTokens: 8_400_000,
            weekCost: 88.20, weekTokens: 61_000_000,
            sessionCost: 3.42, sessionTokens: 2_100_000,
            sessionStart: Date().addingTimeInterval(-3600),
            sessionEnd: Date().addingTimeInterval(4 * 3600),
            sessionMaxCost: 8.0, sessionMaxTokens: 5_000_000,
            provider: "claude",
            models: [
                ModelUsage(id: "claude-fable-5", name: "Fable 5", cost: 518.21, tokens: 251_930_000, messages: 1871),
                ModelUsage(id: "claude-opus-4-8", name: "Opus 4.8", cost: 178.77, tokens: 174_640_000, messages: 2402),
                ModelUsage(id: "claude-sonnet-5", name: "Sonnet 5", cost: 1.70, tokens: 3_100_000, messages: 36),
            ],
            days: days.reversed()
        )
    }
}

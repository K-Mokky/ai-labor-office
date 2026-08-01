import SwiftUI
import AppKit

// MARK: - Connectable AI sources

/// A usage data source the app knows how to read.
enum SourceKind: String, Codable, CaseIterable, Identifiable {
    case claudeCode   // ~/.claude/projects/**/*.jsonl
    case gjc          // ~/.gjc/stats.db
    case codex        // ~/.codex/sessions/**/*.jsonl
    case gemini       // ~/.gemini/tmp/*/chats/session-*.json

    var id: String { rawValue }

    var defaultName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .gjc: return "GJC"
        case .codex: return "Codex CLI"
        case .gemini: return "Gemini CLI"
        }
    }

    var detail: String {
        switch self {
        case .claudeCode: return "~/.claude/projects"
        case .gjc: return "~/.gjc/stats.db"
        case .codex: return "~/.codex/sessions"
        case .gemini: return "~/.gemini/tmp"
        }
    }

    /// Whether the source's data actually exists on this machine.
    var isAvailable: Bool {
        let fm = FileManager.default
        switch self {
        case .claudeCode: return fm.fileExists(atPath: SnapshotIO.realHome + "/.claude/projects")
        case .gjc: return fm.fileExists(atPath: SnapshotIO.realHome + "/.gjc/stats.db")
        case .codex: return fm.fileExists(atPath: SnapshotIO.realHome + "/.codex/sessions")
        case .gemini: return fm.fileExists(atPath: SnapshotIO.realHome + "/.gemini/tmp")
        }
    }

    /// Glyph to show before any events are loaded.
    var fallbackProviderKind: ProviderKind {
        switch self {
        case .claudeCode: return .claude
        case .gjc: return .generic
        case .codex: return .gpt
        case .gemini: return .gemini
        }
    }
}

// MARK: - Connection (one menu bar icon per connection)

struct AIConnection: Codable, Identifiable, Equatable {
    var id: String
    var source: SourceKind
    var name: String
    var colorHex: String     // menu bar icon fill color
    var metricKey: String    // fill basis: "session" | "today" | "week"

    static let defaultColorHex = "00C7BE"   // mint
    static var defaultColor: Color { Color(hex: defaultColorHex) }

    var color: Color { Color(hex: colorHex) }
    var metric: MetricKind { MetricKind.from(key: metricKey) }
}

/// Persists connections as JSON in user defaults.
enum ConnectionStore {
    static let key = "aiConnections"

    static func load() -> [AIConnection] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let conns = try? JSONDecoder().decode([AIConnection].self, from: data)
        else { return [] }
        return conns
    }

    static func save(_ connections: [AIConnection]) {
        if let data = try? JSONEncoder().encode(connections) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

// MARK: - Color <-> hex

extension Color {
    /// Parses "RRGGBB" (with or without "#"); falls back to mint.
    init(hex: String) {
        var h = hex.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("#") { h.removeFirst() }
        var v: UInt64 = 0
        guard h.count == 6, Scanner(string: h).scanHexInt64(&v) else {
            self = .mint
            return
        }
        self.init(red: Double((v >> 16) & 0xFF) / 255,
                  green: Double((v >> 8) & 0xFF) / 255,
                  blue: Double(v & 0xFF) / 255)
    }

    var hexRGB: String {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .systemMint
        return String(format: "%02X%02X%02X",
                      Int(round(ns.redComponent * 255)),
                      Int(round(ns.greenComponent * 255)),
                      Int(round(ns.blueComponent * 255)))
    }
}

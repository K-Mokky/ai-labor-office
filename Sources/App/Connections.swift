import SwiftUI
import AppKit

// MARK: - Connectable AI sources

/// A usage data source the app knows how to read.
enum SourceKind: String, Codable, CaseIterable, Identifiable {
    case claudeCode   // ~/.claude/projects/**/*.jsonl
    case gjc          // ~/.gjc/stats.db
    case codex        // ~/.codex/sessions/**/*.jsonl
    case gemini       // ~/.gemini/tmp/*/chats/session-*.json
    case cursor       // ~/.cursor/projects/**/agent-transcripts/**
    case grok         // ~/.grok/grok.db + ~/.grok/sessions/**

    var id: String { rawValue }

    var defaultName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .gjc: return "GJC"
        case .codex: return "Codex CLI"
        case .gemini: return "Gemini CLI"
        case .cursor: return "Cursor"
        case .grok: return "Grok"
        }
    }

    var detail: String {
        switch self {
        case .claudeCode: return "~/.claude/projects"
        case .gjc: return "~/.gjc/stats.db"
        case .codex: return "~/.codex/sessions"
        case .gemini: return "~/.gemini/tmp"
        case .cursor: return "~/.cursor/projects"
        case .grok: return "~/.grok"
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
        case .cursor: return fm.fileExists(atPath: SnapshotIO.realHome + "/.cursor/projects")
        case .grok:
            return fm.fileExists(atPath: SnapshotIO.realHome + "/.grok/grok.db")
                || fm.fileExists(atPath: SnapshotIO.realHome + "/.grok/sessions")
        }
    }

    /// Glyph to show before any events are loaded.
    var fallbackProviderKind: ProviderKind {
        switch self {
        case .claudeCode: return .claude
        case .gjc: return .generic
        case .codex: return .gpt
        case .gemini: return .gemini
        case .cursor: return .cursor
        case .grok: return .grok
        }
    }
}

// MARK: - Menu bar icon style

/// Shape drawn in the menu bar for a connection. `.app` — the AI 노동청
/// starburst splat — is the default; `.auto` follows the detected provider.
enum IconStyle: String, CaseIterable, Identifiable {
    case app, auto, claude, gpt, gemini, cursor, grok, chart, photo

    var id: String { rawValue }

    var title: String {
        switch self {
        case .app: return "앱 아이콘"
        case .auto: return "자동 (프로바이더 감지)"
        case .claude: return "Claude"
        case .gpt: return "GPT"
        case .gemini: return "Gemini"
        case .cursor: return "Cursor"
        case .grok: return "Grok"
        case .chart: return "차트"
        case .photo: return "사진"
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
    var iconKey: String      // IconStyle rawValue; menu bar glyph shape

    static let defaultColorHex = "00C7BE"   // mint
    static var defaultColor: Color { Color(hex: defaultColorHex) }

    init(id: String, source: SourceKind, name: String, colorHex: String,
         metricKey: String, iconKey: String = IconStyle.app.rawValue) {
        self.id = id
        self.source = source
        self.name = name
        self.colorHex = colorHex
        self.metricKey = metricKey
        self.iconKey = iconKey
    }

    /// v2.5 and earlier persisted connections without `iconKey`; decoding must
    /// not wipe them, so the missing key falls back to the app-icon default.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        source = try c.decode(SourceKind.self, forKey: .source)
        name = try c.decode(String.self, forKey: .name)
        colorHex = try c.decode(String.self, forKey: .colorHex)
        metricKey = try c.decode(String.self, forKey: .metricKey)
        iconKey = (try? c.decode(String.self, forKey: .iconKey)) ?? IconStyle.app.rawValue
    }

    var color: Color { Color(hex: colorHex) }
    var metric: MetricKind { MetricKind.from(key: metricKey) }
    var icon: IconStyle { IconStyle(rawValue: iconKey) ?? .app }
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

// MARK: - Custom menu bar photos

/// Per-connection custom menu bar images (the `.photo` icon style). Stored as
/// small square PNGs under Application Support, keyed by connection id, so the
/// connection JSON in user defaults stays light.
enum IconStore {
    static var dir: URL {
        SnapshotIO.directory.appendingPathComponent("icons", isDirectory: true)
    }

    private static func url(for id: String) -> URL {
        dir.appendingPathComponent(id + ".png")
    }

    static func exists(_ id: String) -> Bool {
        !id.isEmpty && FileManager.default.fileExists(atPath: url(for: id).path)
    }

    static func load(_ id: String) -> NSImage? {
        guard !id.isEmpty else { return nil }
        return NSImage(contentsOf: url(for: id))
    }

    static func remove(_ id: String) {
        try? FileManager.default.removeItem(at: url(for: id))
    }

    /// Downscales `image` to a menu-bar-sized square PNG (aspect-fill) and saves it.
    @discardableResult
    static func save(_ image: NSImage, for id: String) -> Bool {
        guard !id.isEmpty, let png = squarePNG(image, side: 96) else { return false }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (try? png.write(to: url(for: id), options: .atomic)) != nil
    }

    private static func squarePNG(_ image: NSImage, side: Int) -> Data? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = NSSize(width: side, height: side)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        // Aspect-fill: cover the square, cropping the overflow.
        let s = image.size
        let scale = Swift.max(CGFloat(side) / Swift.max(s.width, 1),
                              CGFloat(side) / Swift.max(s.height, 1))
        let w = s.width * scale, h = s.height * scale
        image.draw(in: NSRect(x: (CGFloat(side) - w) / 2, y: (CGFloat(side) - h) / 2,
                              width: w, height: h),
                   from: .zero, operation: .copy, fraction: 1)
        return rep.representation(using: .png, properties: [:])
    }
}

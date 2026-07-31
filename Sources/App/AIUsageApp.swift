import SwiftUI
import AppKit
import Combine

// AppKit-managed status items. SwiftUI's MenuBarExtra(.window) proved unreliable
// for swiftc-built bundles, so status items and popovers are managed directly.
// One status item per connected AI; each icon fills bottom-to-top with the
// connection's usage fraction in the connection's color.
@main
struct AIUsageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Settings { EmptyView() }   // no windows; the status items drive the UI
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    /// `connectionID == ""` is the placeholder item shown when nothing is connected.
    private struct Entry {
        let connectionID: String
        let item: NSStatusItem
    }

    private let store = UsageStore()
    private let updater = Updater()
    private var updateTimer: Timer?
    private var entries: [Entry] = []
    private var popover: NSPopover?
    private var popoverAnchorID = ""
    private var lastPopoverClose = Date.distantPast
    private var lastPopoverCloseAnchorID = ""
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        store.$connections
            .receive(on: DispatchQueue.main)
            .sink { [weak self] conns in
                MainActor.assumeIsolated { self?.syncStatusItems(with: conns) }
            }
            .store(in: &cancellables)
        store.$snapshots
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.renderAllLabels() }
            }
            .store(in: &cancellables)

        syncStatusItems(with: store.connections)

        // Update check: shortly after launch, then every 6 hours.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            MainActor.assumeIsolated { self?.updater.check() }
        }
        updateTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updater.check() }
        }

        // First run: open the connect menu so the user can hook up an AI.
        if store.connections.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.popover == nil,
                          let entry = self.entries.first else { return }
                    self.openPopover(for: entry)
                }
            }
        }
    }

    // MARK: - Status items

    private func syncStatusItems(with conns: [AIConnection]) {
        let wantedIDs = conns.isEmpty ? [""] : conns.map(\.id)
        if wantedIDs != entries.map(\.connectionID) {
            closePopover()
            for e in entries { NSStatusBar.system.removeStatusItem(e.item) }
            entries = wantedIDs.map { id in
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                if let button = item.button {
                    button.target = self
                    button.action = #selector(statusItemClicked(_:))
                    button.sendAction(on: [.leftMouseUp, .rightMouseUp])
                }
                return Entry(connectionID: id, item: item)
            }
        }
        renderAllLabels()
    }

    // MARK: - Clicks

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let entry = entries.first(where: { $0.item.button === sender }) else { return }
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu(for: entry)
        } else {
            togglePopover(for: entry)
        }
    }

    private func togglePopover(for entry: Entry) {
        if let p = popover, p.isShown {
            let sameAnchor = popoverAnchorID == entry.connectionID
            p.performClose(nil)
            if sameAnchor { return }
        } else if Date().timeIntervalSince(lastPopoverClose) < 0.25,
                  lastPopoverCloseAnchorID == entry.connectionID {
            // The transient popover already closed on this click's mouse-down;
            // don't immediately reopen it on the mouse-up.
            return
        }
        openPopover(for: entry)
    }

    private func openPopover(for entry: Entry) {
        guard let button = entry.item.button else { return }
        let p = NSPopover()
        p.behavior = .transient
        p.animates = false
        p.delegate = self
        let root = PopoverView(store: store, updater: updater,
                               connectionID: entry.connectionID.isEmpty ? nil : entry.connectionID)
        let host = NSHostingController(rootView: root)
        host.sizingOptions = .preferredContentSize
        p.contentViewController = host
        popover = p
        popoverAnchorID = entry.connectionID
        NSApp.activate(ignoringOtherApps: true)
        p.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        p.contentViewController?.view.window?.makeKey()
    }

    private func closePopover() {
        popover?.performClose(nil)
        popover = nil
    }

    func popoverDidClose(_ notification: Notification) {
        lastPopoverClose = Date()
        lastPopoverCloseAnchorID = popoverAnchorID
        popover = nil
    }

    private func showContextMenu(for entry: Entry) {
        let menu = NSMenu()
        let refresh = NSMenuItem(title: "새로고침", action: #selector(refreshNow), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "종료", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        entry.item.menu = menu               // menu takes precedence over the button action
        entry.item.button?.performClick(nil) // runs the menu tracking loop
        entry.item.menu = nil                // restore left-click → popover
    }

    @objc private func refreshNow() { store.refresh() }
    @objc private func quitApp() { NSApp.terminate(nil) }

    // MARK: - Labels

    private func renderAllLabels() {
        for e in entries { renderLabel(for: e) }
    }

    /// Renders the connection's glyph gauge to a (colored, non-template) image.
    private func renderLabel(for entry: Entry) {
        guard let button = entry.item.button else { return }
        let view: FilledProviderIcon
        if let conn = store.connections.first(where: { $0.id == entry.connectionID }) {
            let snap = store.snapshots[conn.id]
            var kind = snap?.providerKind ?? .generic
            if kind == .generic { kind = conn.source.fallbackProviderKind }
            let fraction = snap.flatMap { $0.fraction(for: conn.metric) }
            view = FilledProviderIcon(kind: kind, fraction: fraction,
                                      size: 18, color: conn.color)
            var tip = "\(conn.name) — \(conn.metric.title(in: snap))"
            if let fraction { tip += " \(fmtPercent(fraction))" }
            if let resets = quotaWindow(for: conn.metric, in: snap)?.resetsAt, resets > Date() {
                tip += " · \(fmtRemaining(resets)) 후 초기화"
            }
            button.toolTip = tip
        } else {
            view = FilledProviderIcon(kind: .generic, fraction: nil,
                                      size: 18, color: AIConnection.defaultColor)
            button.toolTip = "AI 노동청 — 클릭해서 AI를 연결하세요"
        }
        let renderer = ImageRenderer(content: view.fixedSize())
        renderer.scale = button.window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor ?? 2
        guard let image = renderer.nsImage else { return }
        image.isTemplate = false   // keep the per-connection color
        button.image = image
        button.imagePosition = .imageOnly
    }
}

/// The provider quota window backing a metric, when the provider reported one.
private func quotaWindow(for metric: MetricKind, in snap: UsageSnapshot?) -> LimitWindow? {
    switch metric {
    case .session: return snap?.limitWindow("5h")
    case .week: return snap?.limitWindow("7d")
    default: return nil
    }
}

/// How much of a glyph's ink sits below a given height.
///
/// The provider marks are radial, so their bottom edge is nearly empty: wiping a
/// mask straight up to 28% height lit only 15% of the starburst's ink and looked
/// no different from 7%. Mapping the fraction through the glyph's own ink
/// distribution makes the lit share of the mark match the number it reports.
@MainActor
enum GlyphInkProfile {
    private static let samples = 96
    /// Per glyph: ink accumulated from the bottom row up, one entry per sample row.
    private static var cache: [ProviderKind: [Double]] = [:]

    /// Height (0…1 of the icon) at which the lit ink equals `fraction` of the total.
    static func maskHeight(kind: ProviderKind, fraction: Double) -> CGFloat {
        let f = min(max(fraction, 0), 1)
        guard f > 0 else { return 0 }
        guard f < 1 else { return 1 }
        // Without a profile, degrade to the plain height wipe rather than hide the gauge.
        guard let cumulative = profile(for: kind),
              let total = cumulative.last, total > 0 else { return CGFloat(f) }

        let target = f * total
        guard let row = cumulative.firstIndex(where: { $0 >= target }) else { return CGFloat(f) }
        let below = row == 0 ? 0 : cumulative[row - 1]
        let span = cumulative[row] - below
        let within = span > 0 ? (target - below) / span : 0
        return CGFloat((Double(row) + within) / Double(samples))
    }

    private static func profile(for kind: ProviderKind) -> [Double]? {
        if let cached = cache[kind] { return cached }

        let renderer = ImageRenderer(content:
            ProviderIcon(kind: kind, size: CGFloat(samples), color: .black).fixedSize())
        renderer.scale = 1
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }

        var inkFromBottom = [Double](repeating: 0, count: samples)
        for y in 0..<min(bitmap.pixelsHigh, samples) {
            var ink = 0.0
            for x in 0..<bitmap.pixelsWide {
                ink += Double(bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0)
            }
            inkFromBottom[samples - 1 - y] = ink   // bitmap row 0 is the top row
        }

        var cumulative: [Double] = []
        cumulative.reserveCapacity(samples)
        var running = 0.0
        for ink in inkFromBottom {
            running += ink
            cumulative.append(running)
        }
        cache[kind] = cumulative
        return cumulative
    }
}

/// Provider glyph as a gauge: a dim track with a bright copy on top, masked so
/// that `fraction` of the glyph's *ink* is lit. `fraction == nil` shows only the
/// track.
struct FilledProviderIcon: View {
    let kind: ProviderKind
    let fraction: Double?
    var size: CGFloat = 18
    var color: Color = AIConnection.defaultColor

    var body: some View {
        ZStack {
            ProviderIcon(kind: kind, size: size, color: color)
                .opacity(0.28)
            if let fraction, fraction > 0 {
                let height = GlyphInkProfile.maskHeight(kind: kind, fraction: fraction)
                ProviderIcon(kind: kind, size: size, color: color)
                    .mask(alignment: .bottom) {
                        Rectangle()
                            .frame(width: size, height: size * height)
                    }
            }
        }
        .frame(width: size, height: size)
    }
}

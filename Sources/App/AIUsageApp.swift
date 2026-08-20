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
extension Notification.Name {
    static let openLifetimeStats = Notification.Name("openLifetimeStats")
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
    private var statsWindow: NSWindow?
    private var statsConnectionID: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if migrateToASCIIBundleNameIfNeeded() { return }   // relaunching from the new path

        LoginItem.refreshAgentPathIfNeeded()
        NotificationCenter.default.addObserver(
            self, selector: #selector(openStatsFromNote(_:)),
            name: .openLifetimeStats, object: nil)


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

        // Refresh only while a menu bar icon is visible or the popover is open,
        // so a hidden/occluded app (fullscreen, asleep display, menu bar
        // overflow) does no periodic work.
        NotificationCenter.default.addObserver(
            self, selector: #selector(activityMayHaveChanged),
            name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(
                self, selector: #selector(activityMayHaveChanged), name: name, object: nil)
        }
        updateActivity()

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

    /// Korean bundle folder names (v2.4 "AI 노동청.app") break widget lookup:
    /// ExtensionKit asks LaunchServices with an NFD URL while LS stored NFC.
    /// The on-disk folder stays ASCII ("AI Labor Office.app"); Finder shows
    /// "AI 노동청" via ko.lproj. Older installs — including in-place self-
    /// updates that kept the previous folder name — move themselves once.
    private func migrateToASCIIBundleNameIfNeeded() -> Bool {
        let fm = FileManager.default
        let url = Bundle.main.bundleURL
        let canonical = "AI Labor Office.app"
        guard url.deletingLastPathComponent().path == "/Applications",
              url.lastPathComponent != canonical else { return false }
        let dest = url.deletingLastPathComponent().appendingPathComponent(canonical)
        try? fm.removeItem(at: dest)   // stale copy from an earlier attempt
        do { try fm.moveItem(at: url, to: dest) } catch { return false }

        let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks"
            + "/LaunchServices.framework/Support/lsregister"
        for args in [["-u", url.path],
                     ["-f", dest.path],
                     ["-f", dest.path + "/Contents/Extensions/AI Labor Office Widget.appex"]] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: lsregister)
            p.arguments = args
            try? p.run()
            p.waitUntilExit()
        }

        let opener = Process()
        opener.executableURL = URL(fileURLWithPath: "/bin/sh")
        opener.arguments = ["-c", "sleep 1; exec /usr/bin/open \"$0\"", dest.path]
        try? opener.run()
        DispatchQueue.main.async { NSApp.terminate(nil) }
        return true
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
        updateActivity()
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
        updateActivity()
    }

    private func closePopover() {
        popover?.performClose(nil)
        popover = nil
        updateActivity()
    }

    func popoverDidClose(_ notification: Notification) {
        lastPopoverClose = Date()
        lastPopoverCloseAnchorID = popoverAnchorID
        popover = nil
        updateActivity()
    }

    private func showContextMenu(for entry: Entry) {
        let menu = NSMenu()
        let stats = NSMenuItem(title: "전체 통계…", action: #selector(openLifetimeStats(_:)), keyEquivalent: "s")
        stats.target = self
        stats.representedObject = entry.connectionID
        menu.addItem(stats)
        if store.connections.count > 1 {
            let all = NSMenuItem(title: "연결한 AI 합산 통계…", action: #selector(openCombinedStats), keyEquivalent: "")
            all.target = self
            menu.addItem(all)
        }
        menu.addItem(.separator())
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
    @objc private func openStatsFromNote(_ note: Notification) {
        let combined = (note.userInfo?["combined"] as? Bool) ?? false
        let id = note.userInfo?["connectionID"] as? String
        showStatsWindow(connectionID: id, combined: combined)
    }


    @objc private func openLifetimeStats(_ sender: NSMenuItem) {
        let id = sender.representedObject as? String
        showStatsWindow(connectionID: (id?.isEmpty == false) ? id : nil)
    }

    @objc private func openCombinedStats() {
        showStatsWindow(connectionID: nil, combined: true)
    }

    /// Detached window of recorded-history totals (tokens, models, API vs subscription).
    fileprivate func showStatsWindow(connectionID: String?, combined: Bool = false) {
        closePopover()
        let key = combined ? "__combined__" : (connectionID ?? "")
        if let existing = statsWindow, statsConnectionID == key {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        statsWindow?.close()

        let root = LifetimeStatsView(store: store, connectionID: combined ? nil : connectionID,
                                     combined: combined)
        let host = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: host)
        window.title = combined ? "AI 노동청 · 합산 통계" : "AI 노동청 · 전체 통계"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 560, height: 640))
        window.minSize = NSSize(width: 480, height: 420)
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        statsWindow = window
        statsConnectionID = key
        updateActivity()
    }

    // MARK: - Activity gating

    @objc private func activityMayHaveChanged() { updateActivity() }

    /// The app is worth refreshing when the popover is open or any of its menu
    /// bar icons is actually on-screen (not hidden by overflow/fullscreen/sleep).
    private func updateActivity() {
        let popoverOpen = popover?.isShown == true
        let statsOpen = statsWindow?.isVisible == true
        let anyVisible = entries.contains { entry in
            guard let window = entry.item.button?.window else { return true }
            return window.occlusionState.contains(.visible)
        }
        store.setActive(popoverOpen || statsOpen || anyVisible)
    }

    // MARK: - Labels

    private func renderAllLabels() {
        for e in entries { renderLabel(for: e) }
    }

    /// Renders the connection's glyph gauge to a (colored, non-template) image.
    private func renderLabel(for entry: Entry) {
        guard let button = entry.item.button else { return }
        let view: FilledMenuBarIcon
        if let conn = store.connections.first(where: { $0.id == entry.connectionID }) {
            let snap = store.snapshots[conn.id]
            var kind = snap?.providerKind ?? .generic
            if kind == .generic { kind = conn.source.fallbackProviderKind }
            let fraction = snap.flatMap { $0.fraction(for: conn.metric) }
            let customImage = conn.icon == .photo ? IconStore.load(conn.id) : nil
            view = FilledMenuBarIcon(style: conn.icon, provider: kind, fraction: fraction,
                                     size: 18, color: conn.color, image: customImage)
            var tip = "\(conn.name) — \(conn.metric.title(in: snap))"
            if let fraction { tip += " \(fmtPercent(fraction))" }
            if let resets = quotaWindow(for: conn.metric, in: snap)?.resetsAt, resets > Date() {
                tip += " · \(fmtRemaining(resets)) 후 초기화"
            }
            button.toolTip = tip
        } else {
            view = FilledMenuBarIcon(style: .app, provider: .generic, fraction: nil,
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

/// The glyph a menu bar entry draws: the AI 노동청 splat, a provider mark, or
/// a chart. All shapes are silhouettes tinted with the connection color so the
/// ink-fill gauge reads the same across styles.
struct MenuBarGlyph: View {
    let style: IconStyle
    let provider: ProviderKind   // resolved source provider, used by .auto
    var size: CGFloat = 18
    var color: Color = AIConnection.defaultColor
    var image: NSImage? = nil    // custom photo for the .photo style

    var body: some View {
        switch style {
        case .app: AppIconGlyph(size: size, color: color)
        case .auto: ProviderIcon(kind: provider, size: size, color: color)
        case .claude: ProviderIcon(kind: .claude, size: size, color: color)
        case .gpt: ProviderIcon(kind: .gpt, size: size, color: color)
        case .gemini: ProviderIcon(kind: .gemini, size: size, color: color)
        case .cursor: ProviderIcon(kind: .cursor, size: size, color: color)
        case .grok: ProviderIcon(kind: .grok, size: size, color: color)
        case .chart: ProviderIcon(kind: .generic, size: size, color: color)
        case .photo:
            if let image {
                Image(nsImage: image).resizable().interpolation(.high)
                    .frame(width: size, height: size)
            } else {
                AppIconGlyph(size: size, color: color)   // no photo picked yet
            }
        }
    }
}

/// The app icon (starburst splat) as a tintable silhouette. The icns carries
/// the shape in its alpha channel; template rendering recolors it.
struct AppIconGlyph: View {
    var size: CGFloat
    var color: Color

    private static let image: NSImage? =
        NSImage(named: "AppIcon") ?? Bundle.main.image(forResource: "AppIcon")

    var body: some View {
        if let img = Self.image {
            Image(nsImage: img)
                .resizable()
                .renderingMode(.template)
                .foregroundStyle(color)
                .frame(width: size, height: size)
        } else {
            // Bundle without the icns (shouldn't happen) — closest vector shape.
            ProviderIcon(kind: .claude, size: size, color: color)
        }
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
    static let sampleSize = 96
    private static let samples = sampleSize
    /// Per glyph key: ink accumulated from the bottom row up, one entry per row.
    private static var cache: [String: [Double]] = [:]

    /// Height (0…1 of the icon) at which the lit ink equals `fraction` of the total.
    static func maskHeight(key: String, fraction: Double,
                           profileGlyph: () -> AnyView) -> CGFloat {
        let f = min(max(fraction, 0), 1)
        guard f > 0 else { return 0 }
        guard f < 1 else { return 1 }
        // Without a profile, degrade to the plain height wipe rather than hide the gauge.
        guard let cumulative = profile(key: key, glyph: profileGlyph()),
              let total = cumulative.last, total > 0 else { return CGFloat(f) }

        let target = f * total
        guard let row = cumulative.firstIndex(where: { $0 >= target }) else { return CGFloat(f) }
        let below = row == 0 ? 0 : cumulative[row - 1]
        let span = cumulative[row] - below
        let within = span > 0 ? (target - below) / span : 0
        return CGFloat((Double(row) + within) / Double(samples))
    }

    private static func profile(key: String, glyph: AnyView) -> [Double]? {
        if let cached = cache[key] { return cached }

        let renderer = ImageRenderer(content: glyph.fixedSize())
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
        cache[key] = cumulative
        return cumulative
    }
}

/// Menu bar glyph as a gauge: a dim track with a bright copy on top, masked so
/// that `fraction` of the glyph's *ink* is lit. `fraction == nil` shows only the
/// track.
struct FilledMenuBarIcon: View {
    let style: IconStyle
    let provider: ProviderKind
    let fraction: Double?
    var size: CGFloat = 18
    var color: Color = AIConnection.defaultColor
    var image: NSImage? = nil     // custom photo for the .photo style

    /// A photo without a chosen image falls back to the app glyph gauge.
    private var effectiveStyle: IconStyle { style == .photo ? .app : style }

    private var profileKey: String {
        effectiveStyle == .auto ? "auto-\(provider.rawValue)" : effectiveStyle.rawValue
    }

    var body: some View {
        if style == .photo, let image {
            // The photo style fills by opacity, not a bottom-up ink mask:
            // faint when idle, fully opaque at 100% usage.
            let f = fraction.map { Swift.min(Swift.max($0, 0), 1) } ?? 0
            Image(nsImage: image)
                .resizable().interpolation(.high)
                .frame(width: size, height: size)
                .opacity(0.15 + 0.85 * f)
        } else {
            inkGauge
        }
    }

    private var inkGauge: some View {
        ZStack {
            MenuBarGlyph(style: effectiveStyle, provider: provider, size: size, color: color)
                .opacity(0.28)
            if let fraction, fraction > 0 {
                let height = GlyphInkProfile.maskHeight(key: profileKey, fraction: fraction) {
                    AnyView(MenuBarGlyph(style: effectiveStyle, provider: provider,
                                         size: CGFloat(GlyphInkProfile.sampleSize),
                                         color: .black))
                }
                MenuBarGlyph(style: effectiveStyle, provider: provider, size: size, color: color)
                    .mask(alignment: .bottom) {
                        Rectangle()
                            .frame(width: size, height: size * height)
                    }
            }
        }
        .frame(width: size, height: size)
    }
}

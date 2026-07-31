import SwiftUI
import AppKit
import Combine

// AppKit-managed status item. SwiftUI's MenuBarExtra(.window) proved unreliable
// for swiftc-built bundles: the custom label (Canvas glyph + ring) collapsed to
// plain text and clicks never opened the window. NSStatusItem + NSPopover give
// deterministic click handling and full label rendering.
@main
struct AIUsageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Settings { EmptyView() }   // no windows; the status item drives the UI
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let store = UsageStore()
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var lastPopoverClose = Date.distantPast
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        if let button = item.button {
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        // Re-render the label whenever the snapshot or the display settings change.
        store.$snapshot
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.renderLabel() }
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.renderLabel() }
            }
            .store(in: &cancellables)
        renderLabel()
    }

    // MARK: - Clicks

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        if let p = popover, p.isShown {
            p.performClose(nil)
            return
        }
        // A transient popover already closed on this click's mouse-down;
        // don't immediately reopen it on the mouse-up.
        guard Date().timeIntervalSince(lastPopoverClose) > 0.25,
              let button = statusItem?.button else { return }

        let p = NSPopover()
        p.behavior = .transient
        p.animates = false
        p.delegate = self
        let host = NSHostingController(rootView: PopoverView(store: store))
        host.sizingOptions = .preferredContentSize
        p.contentViewController = host
        popover = p
        NSApp.activate(ignoringOtherApps: true)
        p.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        p.contentViewController?.view.window?.makeKey()
    }

    func popoverDidClose(_ notification: Notification) {
        lastPopoverClose = Date()
        popover = nil
    }

    private func showContextMenu() {
        guard let item = statusItem else { return }
        let menu = NSMenu()
        let refresh = NSMenuItem(title: "새로고침", action: #selector(refreshNow), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "종료", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu               // menu takes precedence over the button action
        item.button?.performClick(nil) // runs the menu tracking loop
        item.menu = nil                // restore left-click → popover
    }

    @objc private func refreshNow() { store.refresh() }
    @objc private func quitApp() { NSApp.terminate(nil) }

    // MARK: - Label

    /// Renders the SwiftUI label (glyph + ring + text) to a template image so
    /// Canvas drawing survives and the menu bar recolors it for light/dark.
    private func renderLabel() {
        guard let button = statusItem?.button else { return }
        let renderer = ImageRenderer(content: MenuBarLabel(store: store)
            .environment(\.colorScheme, .light)   // draw black-on-clear for template mode
            .fixedSize())
        renderer.scale = button.window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor ?? 2
        guard let image = renderer.nsImage else {
            button.image = nil
            button.title = "AI"
            return
        }
        image.isTemplate = true
        button.image = image
        button.imagePosition = .imageOnly
    }
}

struct MenuBarLabel: View {
    @ObservedObject var store: UsageStore
    @AppStorage("menuBarMetric") private var metricKey = "session"
    @AppStorage("menuBarUnit") private var unitKey = "percent"
    @AppStorage("menuBarPrefix") private var showPrefix = true

    private var metric: MetricKind { MetricKind.from(key: metricKey) }
    private var unit: UnitKind { UnitKind(rawValue: unitKey) ?? .percent }

    /// "[provider icon] 43% 사용" — the glyph stands in for the metric word.
    /// Non-session metrics keep their prefix so the number stays unambiguous.
    private var labelText: String {
        let value = metric.value(in: store.snapshot, unit: unit)
        if unit == .percent {
            guard value != "—" else { return "—" }
            let prefix = showPrefix && metric != .session
                ? "\(metric.shortPrefix(in: store.snapshot)) " : ""
            return "\(prefix)\(value) 사용"
        }
        return showPrefix
            ? "\(metric.shortPrefix(in: store.snapshot)) \(value)"
            : value
    }

    var body: some View {
        HStack(spacing: 4) {
            ProviderIcon(kind: store.snapshot?.providerKind ?? .generic,
                         size: 15, color: .primary)
            if unit == .percent {
                RingGauge(fraction: store.snapshot.flatMap { $0.fraction(for: metric) },
                          size: 14, lineWidth: 2.2)
            }
            Text(labelText).monospacedDigit()
        }
        .frame(height: 18)
    }
}

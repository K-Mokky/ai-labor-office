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
        let root = PopoverView(store: store,
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
            view = FilledProviderIcon(kind: kind,
                                      fraction: snap.flatMap { $0.fraction(for: conn.metric) },
                                      size: 18, color: conn.color)
            button.toolTip = "\(conn.name) — \(conn.metric.title(in: snap))"
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

/// Provider glyph as a gauge: a dim track with a bright copy on top, masked to
/// the bottom `fraction` of its height. `fraction == nil` shows only the track.
struct FilledProviderIcon: View {
    let kind: ProviderKind
    let fraction: Double?
    var size: CGFloat = 18
    var color: Color = AIConnection.defaultColor

    var body: some View {
        ZStack {
            ProviderIcon(kind: kind, size: size, color: color)
                .opacity(0.32)
            if let f = fraction, f > 0 {
                ProviderIcon(kind: kind, size: size, color: color)
                    .mask(alignment: .bottom) {
                        Rectangle()
                            .frame(width: size, height: size * min(f, 1))
                    }
            }
        }
        .frame(width: size, height: size)
    }
}

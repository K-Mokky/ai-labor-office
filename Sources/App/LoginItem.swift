import Foundation
import ServiceManagement

/// "Start at login" switch for the menu bar app.
///
/// `SMAppService.mainApp` is the sanctioned API on macOS 13+, but it registers
/// through LaunchServices and refuses bundles it cannot resolve (ad-hoc signed
/// builds run from a Downloads folder or a stale LS record hit this), so a
/// per-user LaunchAgent is kept as a fallback. Only one mechanism is ever
/// active: enabling prefers SMAppService and only writes the agent when the
/// registration throws, disabling tears both down.
enum LoginItem {
    static let label = "com.mokky.aiusage.launchatlogin"

    private static var agentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    /// Path launchd should open — the bundle, not the inner executable, so
    /// LaunchServices applies the app's activation policy.
    private static var bundlePath: String { Bundle.main.bundleURL.path }

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled || hasAgent
    }

    private static var hasAgent: Bool {
        FileManager.default.fileExists(atPath: agentURL.path)
    }

    /// Applies the requested state and reports what actually stuck, so the UI
    /// can snap the toggle back when the system refuses.
    @discardableResult
    static func setEnabled(_ on: Bool) -> Bool {
        if on {
            do {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
                removeAgent()          // SMAppService owns it now
            } catch {
                writeAgent()
            }
        } else {
            if SMAppService.mainApp.status == .enabled {
                try? SMAppService.mainApp.unregister()
            }
            removeAgent()
        }
        return isEnabled
    }

    /// The bundle moves (ASCII-name migration, self-update, drag to
    /// /Applications), which leaves a fallback agent pointing at a path that no
    /// longer exists. Called at launch; no-op unless the agent is stale.
    static func refreshAgentPathIfNeeded() {
        guard hasAgent,
              let plist = NSDictionary(contentsOf: agentURL) as? [String: Any],
              let args = plist["ProgramArguments"] as? [String],
              args.last != bundlePath else { return }
        writeAgent()
    }

    private static func writeAgent() {
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": ["/usr/bin/open", "-a", bundlePath],
            "RunAtLoad": true,
        ]
        let dir = agentURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0) else { return }
        try? data.write(to: agentURL, options: .atomic)
    }

    private static func removeAgent() {
        guard hasAgent else { return }
        try? FileManager.default.removeItem(at: agentURL)
    }
}

import SwiftUI
import AppKit

/// Self-update via GitHub Releases: when the latest release tag is newer than
/// the running app's CFBundleShortVersionString, download its .dmg asset and
/// replace the bundle in place, then relaunch.
@MainActor
final class Updater: ObservableObject {

    struct Release: Equatable {
        let tag: String            // e.g. "v2.3"
        let version: [Int]         // e.g. [2, 3]
        let dmgURL: URL
        var versionText: String { version.map(String.init).joined(separator: ".") }
    }

    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available(Release)
        case downloading(Release)
        case installing(Release)
        case failed(String)
    }

    static let repo = "K-Mokky/ai-labor-office"

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lastChecked: Date?

    static var currentVersionText: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }
    static var currentVersion: [Int] { parse(currentVersionText) ?? [0] }

    /// "v2.3" / "2.3.1" → [2,3] / [2,3,1]; nil when no numeric dot-version.
    static func parse(_ raw: String) -> [Int]? {
        let stripped = raw.trimmingCharacters(in: .whitespaces)
            .drop(while: { $0 == "v" || $0 == "V" })
        let parts = stripped.split(separator: ".")
        let ints = parts.compactMap { Int($0.prefix(while: \.isNumber)) }
        return ints.count == parts.count && !ints.isEmpty ? ints : nil
    }

    static func isNewer(_ a: [Int], than b: [Int]) -> Bool {
        for i in 0..<Swift.max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// Auto-install newer releases (settings toggle, default on).
    var autoInstall: Bool {
        UserDefaults.standard.object(forKey: "autoUpdate") as? Bool ?? true
    }

    private var isBusy: Bool {
        switch phase {
        case .checking, .downloading, .installing: return true
        default: return false
        }
    }

    // MARK: - Check

    func check() {
        guard !isBusy else { return }
        phase = .checking
        Task {
            do {
                let release = try await Self.fetchLatest()
                lastChecked = Date()
                if let release, Self.isNewer(release.version, than: Self.currentVersion) {
                    phase = .available(release)
                    if autoInstall { install(release) }
                } else {
                    phase = .upToDate
                }
            } catch {
                lastChecked = Date()
                phase = .failed("업데이트 확인 실패: \(error.localizedDescription)")
            }
        }
    }

    /// Latest (non-draft, non-prerelease) release; nil when the repo has none.
    static func fetchLatest() async throws -> Release? {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw err("응답이 없습니다") }
        if http.statusCode == 404 { return nil }               // no releases yet
        guard http.statusCode == 200 else { throw err("GitHub HTTP \(http.statusCode)") }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String else { throw err("릴리스 응답을 읽지 못했습니다") }
        guard let version = parse(tag) else { throw err("버전 태그가 아닙니다: \(tag)") }
        let assets = obj["assets"] as? [[String: Any]] ?? []
        let dmg = assets.compactMap { a -> URL? in
            guard let name = a["name"] as? String, name.hasSuffix(".dmg"),
                  let s = a["browser_download_url"] as? String else { return nil }
            return URL(string: s)
        }.first
        guard let dmg else { throw err("릴리스 \(tag)에 .dmg 에셋이 없습니다") }
        return Release(tag: tag, version: version, dmgURL: dmg)
    }

    // MARK: - Install

    func install(_ release: Release) {
        if case .downloading = phase { return }
        if case .installing = phase { return }
        phase = .downloading(release)
        Task {
            do {
                let dmg = try await Self.download(release.dmgURL)
                phase = .installing(release)
                let target = try await Task.detached {
                    try Self.replaceBundle(with: dmg)
                }.value
                if !Self.relaunch(target) {
                    // 새 번들은 이미 설치됨 — 다음 수동 실행 때 반영된다. busy 상태로
                    // 남으면 이후 업데이트 확인까지 막히므로 .failed로 풀어준다.
                    phase = .failed("업데이트는 설치되었지만 재시작에 실패했습니다 — 앱을 수동으로 다시 실행하세요")
                }
            } catch {
                NSLog("[Updater] install failed: %@", error.localizedDescription)
                phase = .failed("업데이트 실패: \(error.localizedDescription)")
            }
        }
    }

    nonisolated private static func download(_ url: URL) async throws -> URL {
        let (tmp, resp) = try await URLSession.shared.download(from: url)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw err("DMG 다운로드 실패")
        }
        let dst = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIUsage-update-\(UUID().uuidString).dmg")
        try FileManager.default.moveItem(at: tmp, to: dst)
        return dst
    }

    /// Mounts the DMG, swaps the running bundle for the .app inside, unmounts.
    /// Rolls the old bundle back if the copy fails.
    nonisolated private static func replaceBundle(with dmg: URL) throws -> URL {
        let fm = FileManager.default
        let mount = fm.temporaryDirectory
            .appendingPathComponent("AIUsage-mount-\(UUID().uuidString)")
        try run("/usr/bin/hdiutil", "attach", dmg.path,
                "-nobrowse", "-readonly", "-mountpoint", mount.path)
        defer {
            _ = try? run("/usr/bin/hdiutil", "detach", mount.path, "-force")
            try? fm.removeItem(at: dmg)
        }

        // 아무 .app이나 설치하면 위험하다 — 번들 ID가 우리 앱과 일치하는 것만 채택.
        let expectedID = Bundle.main.bundleIdentifier ?? "com.mokky.aiusage"
        let apps = try fm.contentsOfDirectory(atPath: mount.path).filter { $0.hasSuffix(".app") }
        var foundIDs: [String] = []
        var matched: String?
        for name in apps {
            let id = Bundle(url: mount.appendingPathComponent(name))?.bundleIdentifier ?? "(식별자 없음)"
            foundIDs.append(id)
            if id == expectedID { matched = name; break }
        }
        guard let appName = matched else {
            throw err(apps.isEmpty
                ? "DMG 안에 .app이 없습니다"
                : "DMG 안에 \(expectedID) 앱이 없습니다 (발견: \(foundIDs.joined(separator: ", ")))")
        }
        let source = mount.appendingPathComponent(appName)
        let target = Bundle.main.bundleURL
        let parked = fm.temporaryDirectory
            .appendingPathComponent("AIUsage-old-\(UUID().uuidString).app")

        try fm.moveItem(at: target, to: parked)
        do {
            try run("/usr/bin/ditto", source.path, target.path)
        } catch {
            try? fm.removeItem(at: target)
            try? fm.moveItem(at: parked, to: target)   // roll back
            throw error
        }
        _ = try? run("/usr/bin/xattr", "-r", "-d", "com.apple.quarantine", target.path)
        try? fm.removeItem(at: parked)
        return target
    }

    /// Spawns a detached opener that outlives this process, then quits so the
    /// new binary takes over the status items. Returns false when the opener
    /// could not be spawned — the caller must then keep the app running.
    nonisolated private static func relaunch(_ appURL: URL) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; exec /usr/bin/open \"$0\"", appURL.path]
        do {
            try p.run()
        } catch {
            NSLog("[Updater] relaunch spawn failed: %@", error.localizedDescription)
            return false
        }
        DispatchQueue.main.async { NSApp.terminate(nil) }
        return true
    }

    // MARK: - Helpers

    @discardableResult
    nonisolated private static func run(_ tool: String, _ args: String...) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                         encoding: .utf8) ?? ""
        guard p.terminationStatus == 0 else {
            let name = URL(fileURLWithPath: tool).lastPathComponent
            throw err("\(name) 실패(\(p.terminationStatus)): \(out.prefix(200))")
        }
        return out
    }

    nonisolated private static func err(_ msg: String) -> Error {
        NSError(domain: "Updater", code: 1,
                userInfo: [NSLocalizedDescriptionKey: msg])
    }
}

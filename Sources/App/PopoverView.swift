import SwiftUI
import AppKit
import WidgetKit

/// Persists per-widget settings and pokes WidgetKit when they change.
final class WidgetSettingsStore: ObservableObject {
    @Published var configs: WidgetConfigs = SnapshotIO.loadWidgetConfigs() {
        didSet {
            SnapshotIO.saveWidgetConfigs(configs)
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
}

struct PopoverView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var updater: Updater
    var connectionID: String? = nil          // nil → onboarding (no connections yet)
    @AppStorage("menuBarUnit") private var unitKey = "percent"
    @AppStorage("autoUpdate") private var autoUpdate = false
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var showSettings = false
    @StateObject private var widgetSettings = WidgetSettingsStore()
    @ObservedObject private var account = AccountAuth.shared
    @State private var loginStarted = false
    @State private var loginCode = ""
    @State private var loginBusy = false
    @State private var loginError: String?

    private var unit: UnitKind { UnitKind(rawValue: unitKey) ?? .percent }

    private var connection: AIConnection? {
        store.connections.first { $0.id == connectionID } ?? store.connections.first
    }
    private var snapshot: UsageSnapshot? {
        connection.flatMap { store.snapshots[$0.id] }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    updateBanner
                    if connection == nil {
                        onboarding
                        connectSection
                    } else {
                        summaryCards
                        modelSection
                        heatmapSection
                        if showSettings {
                            settingsSection
                            widgetSection
                            accountSection
                            connectSection
                        }
                    }
                    footer
                }
                .padding(14)
            }
        }
        .frame(width: 384)
        .frame(maxHeight: 680)
    }

    // MARK: Update banner

    @ViewBuilder private var updateBanner: some View {
        switch updater.phase {
        case .available(let r):
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text("새 버전 \(r.tag) 사용 가능").font(.caption.bold())
                    Text("현재 v\(Updater.currentVersionText)")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Button("업데이트") { updater.install(r) }.font(.caption)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(.tint.opacity(0.12)))
        case .downloading(let r):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("\(r.tag) 다운로드 중…").font(.caption)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(.tint.opacity(0.12)))
        case .installing(let r):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("\(r.tag) 설치 중 — 곧 재시작됩니다").font(.caption)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(.tint.opacity(0.12)))
        case .failed(let msg):
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                Text(msg).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("재시도") { updater.check() }.font(.caption)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))
        default:
            EmptyView()
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            if let c = connection {
                Circle().fill(c.color).frame(width: 9, height: 9)
                Text("AI 노동청 · \(c.name)").font(.headline)
            } else {
                Text("AI 노동청").font(.headline)
            }
            Spacer()
            if let t = store.lastRefresh {
                Text(t, style: .time).font(.caption2).foregroundStyle(.secondary)
            }
            if connection != nil {
                Button {
                    withAnimation { showSettings.toggle() }
                } label: {
                    Image(systemName: showSettings ? "gearshape.fill" : "gearshape")
                }
                .buttonStyle(.borderless)
                .help("설정")
            }
            Button {
                store.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("새로고침")
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.borderless)
            .help("종료")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: Onboarding (no connections yet)

    private var onboarding: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("내 AI가 노동착취를 얼마나 당했는지 확인할 수 있는 앱")
                .font(.callout)
            Text("아래에서 사용량을 집계할 AI를 연결하세요. 연결한 AI마다 메뉴바에 아이콘이 하나씩 생깁니다.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Summary cards

    private var summaryCards: some View {
        let s = snapshot
        let tint = connection?.color ?? .accentColor
        return VStack(spacing: 8) {
            HStack(spacing: 8) {
                StatCard(title: "전체 사용량", cost: s?.totalCost, tokens: s?.totalTokens,
                         sub: s.map { "\($0.totalMessages)개 메시지" })
                StatCard(title: "오늘 사용량", cost: s?.todayCost, tokens: s?.todayTokens, sub: nil)
            }
            HStack(alignment: .top, spacing: 8) {
                if connection?.source == .grok {
                    // Grok has no 5h session quota; its session slot instead
                    // breaks the weekly credits down by product (Build/Chat/Imagine).
                    grokProductCard(tint: tint)
                } else {
                    StatCard(title: "세션 사용량", cost: s?.sessionCost, tokens: s?.sessionTokens,
                             sub: sessionSub, fraction: s.flatMap { $0.fraction(for: .session) },
                             tint: tint)
                }
                StatCard(title: "주간 사용량", cost: s?.weekCost, tokens: s?.weekTokens,
                         sub: weekSub,
                         fraction: weekFraction,
                         tint: tint)
            }
        }
    }

    /// Grok's weekly percent comes only from its real quota window — never the
    /// local-history fallback, which would misleadingly read ~100%.
    private var weekFraction: Double? {
        guard let s = snapshot else { return nil }
        if connection?.source == .grok { return s.limitWindow("7d")?.usedFraction }
        return s.fraction(for: .week)
    }

    /// Prefers the provider's real 5h quota; falls back to the locally derived block.
    private var sessionSub: String? {
        guard let s = snapshot else { return nil }
        if let w = s.limitWindow("5h") {
            return "5시간 한도 · \(resetText(w.resetsAt))\(staleSuffix(w))"
        }
        guard let end = s.sessionEnd, end > Date() else { return "활성 세션 없음" }
        return "종료까지 \(fmtRemaining(end))"
    }

    private var weekSub: String? {
        guard let s = snapshot else { return nil }
        if let w = s.limitWindow("7d") {
            return "7일 한도 · \(resetText(w.resetsAt))\(staleSuffix(w))"
        }
        // Grok has no local-history baseline worth showing; prompt a refresh.
        if connection?.source == .grok { return "grok 실행 시 갱신" }
        return "최근 7일 · 역대 최고 대비"
    }

    /// " · N시간 전 기준" when the window came from a stale cached report.
    private func staleSuffix(_ w: LimitWindow) -> String {
        guard let asOf = w.asOf, Date().timeIntervalSince(asOf) > 15 * 60 else { return "" }
        return " · \(fmtAgo(asOf)) 기준"
    }

    private func resetText(_ date: Date?) -> String {
        guard let date, date > Date() else { return "곧 초기화" }
        return "\(fmtRemaining(date)) 후 초기화"
    }

    // MARK: Grok weekly per-product usage (fills the session slot for Grok)

    /// Grok has no 5h session quota, so the session card is replaced with the
    /// weekly SuperGrok credits broken down by product as horizontal bars.
    private func grokProductCard(tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("제품별 주간 사용").font(.caption).foregroundStyle(.secondary)
            if let products = store.grokBilling?.products, !products.isEmpty {
                ForEach(products) { p in
                    HStack(spacing: 6) {
                        Text(prettyGrokProduct(p.name))
                            .font(.caption2).lineLimit(1)
                            .frame(width: 54, alignment: .leading)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(.quaternary)
                                Capsule().fill(tint)
                                    .frame(width: Swift.max(3, geo.size.width * barFraction(p.percent)))
                            }
                        }
                        .frame(height: 5)
                        Text(p.percent.map { fmtPercent($0 / 100) } ?? "—")
                            .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                            .frame(width: 30, alignment: .trailing)
                    }
                }
            } else {
                Text("grok CLI 토큰이 없어요 — grok을 한 번 실행하면 갱신돼요.")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))
    }

    /// 0…1 bar length for a product's weekly usage percent (0…100).
    private func barFraction(_ percent: Double?) -> Double {
        Swift.min(Swift.max((percent ?? 0) / 100, 0), 1)
    }

    private func prettyGrokProduct(_ raw: String) -> String {
        switch raw {
        case "GrokBuild": return "Build"
        case "GrokChat": return "Chat"
        case "GrokImagine": return "Imagine"
        default: return raw
        }
    }

    // MARK: Models

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("모델별 사용량").font(.subheadline.bold())
            if let models = snapshot?.models, !models.isEmpty {
                let maxCost = models.map(\.cost).max() ?? 1
                let maxTok = models.map(\.tokens).max() ?? 1
                ForEach(models) { m in
                    ModelRow(model: m, fraction: unit != .tokens
                             ? m.cost / Swift.max(maxCost, 0.0001)
                             : Double(m.tokens) / Double(Swift.max(maxTok, 1)),
                             unit: unit)
                }
            } else {
                Text("데이터 없음").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))
    }

    // MARK: Heatmap

    private var heatmapSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("기여 그래프").font(.subheadline.bold())
                Spacer()
                Text(unit == .tokens ? "일일 토큰 기준" : "일일 비용 기준")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            HeatmapView(dayMap: snapshot?.dayMap ?? [:],
                        weeks: 24, cellSize: 10.5, spacing: 3,
                        unit: unit == .tokens ? .tokens : .cost)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))
    }

    // MARK: Icon settings (per connection)

    private var metricBinding: Binding<String> {
        Binding(get: { connection?.metricKey ?? "session" },
                set: { key in
                    guard var c = connection else { return }
                    c.metricKey = key
                    store.updateConnection(c)
                })
    }

    private var colorBinding: Binding<Color> {
        Binding(get: { connection?.color ?? AIConnection.defaultColor },
                set: { color in
                    guard var c = connection else { return }
                    c.colorHex = color.hexRGB
                    store.updateConnection(c)
                })
    }

    private var iconBinding: Binding<String> {
        Binding(get: { connection?.iconKey ?? IconStyle.app.rawValue },
                set: { key in
                    guard var c = connection else { return }
                    c.iconKey = key
                    store.updateConnection(c)
                })
    }

    /// Provider kind the `.auto` icon style resolves to for this connection.
    private var iconPreviewProvider: ProviderKind {
        guard let c = connection else { return .generic }
        let kind = snapshot?.providerKind ?? .generic
        return kind == .generic ? c.source.fallbackProviderKind : kind
    }

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("아이콘 설정").font(.subheadline.bold())
            Picker("채움 기준", selection: metricBinding) {
                Text("세션 사용량").tag("session")
                Text("오늘 사용량").tag("today")
                Text("주간 사용량").tag("week")
            }
            .pickerStyle(.segmented)
            HStack(spacing: 10) {
                Picker("아이콘 모양", selection: iconBinding) {
                    ForEach(IconStyle.allCases) { s in
                        Text(s.title).tag(s.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .font(.caption)
                MenuBarGlyph(style: connection?.icon ?? .app,
                             provider: iconPreviewProvider,
                             size: 16,
                             color: connection?.color ?? AIConnection.defaultColor)
            }
            ColorPicker("아이콘 색", selection: colorBinding, supportsOpacity: false)
                .font(.caption)
            Picker("단위 (모델별·히트맵 표시)", selection: $unitKey) {
                ForEach(UnitKind.allCases, id: \.rawValue) { u in
                    Text(u.title).tag(u.rawValue)
                }
            }
            .pickerStyle(.menu)
            .font(.caption)
            Divider()
            HStack {
                Text("버전 v\(Updater.currentVersionText)")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if updater.phase == .checking {
                    ProgressView().controlSize(.small)
                } else {
                    if updater.phase == .upToDate {
                        Text("최신 버전").font(.caption2).foregroundStyle(.secondary)
                    }
                    Button("업데이트 확인") { updater.check() }.font(.caption)
                }
            }
            Toggle("컴퓨터를 켤 때 자동으로 실행", isOn: $launchAtLogin)
                .font(.caption)
                .onChange(of: launchAtLogin) { _, on in
                    let applied = LoginItem.setEnabled(on)
                    if applied != on { launchAtLogin = applied }   // system refused
                }
            Toggle("새 버전이 있으면 자동으로 설치", isOn: $autoUpdate)
                .font(.caption)
            Text("메뉴바 아이콘은 채움 기준 지표의 사용률만큼 아래에서 위로 채워집니다. 세션·주간은 프로바이더가 실제 적용하는 한도 기준입니다(100% = 한도 소진) — Claude는 Anthropic 5시간·7일 한도, Codex는 ChatGPT 플랜의 5시간·주간 한도, Grok은 SuperGrok 주간 크레딧 한도(세션 한도는 없음). 한도를 읽지 못하면(예: Gemini) 역대 최대 기록 대비로 표시하고, 오늘은 항상 최고 일간 대비입니다.")
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .onAppear { launchAtLogin = LoginItem.isEnabled }   // may have changed in System Settings
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))
    }

    // MARK: Widget settings

    private var widgetSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("위젯 설정").font(.subheadline.bold())
            widgetRow("기여 그래프", kind: "contribution")
            widgetRow("요약", kind: "summary")
            widgetRow("모델별", kind: "models")
            widgetRow("세션", kind: "session")
            Text("위젯마다 어떤 AI의 데이터를 어떤 단위로 보여줄지 고릅니다. 변경 즉시 위젯에 반영됩니다.")
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))
    }

    private func widgetRow(_ title: String, kind: String) -> some View {
        let sourceBinding = Binding<String>(
            get: { widgetSettings.configs.config(for: kind).source },
            set: { v in
                var c = widgetSettings.configs.config(for: kind)
                c.source = v
                widgetSettings.configs.set(c, for: kind)
            })
        let unitBinding = Binding<String>(
            get: { widgetSettings.configs.config(for: kind).unit },
            set: { v in
                var c = widgetSettings.configs.config(for: kind)
                c.unit = v
                widgetSettings.configs.set(c, for: kind)
            })
        return HStack(spacing: 6) {
            Text(title).font(.caption).frame(width: 72, alignment: .leading)
            Picker("", selection: sourceBinding) {
                Text("전체 합산").tag("all")
                ForEach(store.connections) { c in
                    Text(c.name).tag(c.source.rawValue)
                }
            }
            .labelsHidden()
            .controlSize(.small)
            Picker("", selection: unitBinding) {
                Text("비용($)").tag("cost")
                Text("토큰").tag("tokens")
            }
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 92)
        }
    }

    // MARK: Account link (CLI-independent quota refresh)

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("한도 계정 연결").font(.subheadline.bold())
            if account.isConnected {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                    Text("Claude 계정 연결됨 — CLI를 열지 않아도 5시간·7일 한도가 계속 갱신됩니다.")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("해제") {
                        account.disconnect()
                        store.refresh()
                    }
                    .font(.caption)
                    .foregroundStyle(.red)
                    .buttonStyle(.borderless)
                }
            } else {
                Text("5시간·7일 한도는 CLI(gjc·Claude Code)가 남긴 토큰이 살아 있는 동안만 실시간으로 읽힙니다. 계정을 직접 연결하면 CLI를 열지 않아도 항상 갱신됩니다.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button(loginStarted ? "브라우저 다시 열기" : "브라우저에서 로그인") {
                        loginError = nil
                        account.beginLogin()
                        loginStarted = true
                    }
                    .font(.caption)
                    if loginStarted && account.awaitingCallback {
                        ProgressView().controlSize(.small)
                        Text("브라우저에서 로그인을 마치면 자동으로 연결됩니다.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                // Manual paste — only needed when the localhost callback
                // couldn't bind (e.g. Claude Code is mid-login on the port).
                if loginStarted && !account.awaitingCallback {
                    HStack(spacing: 8) {
                        TextField("코드 붙여넣기 (code#state)", text: $loginCode)
                            .textFieldStyle(.roundedBorder)
                            .font(.caption)
                        if loginBusy {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("연결") { completeLogin() }
                                .font(.caption)
                                .disabled(loginCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                    Text("자동 연결 포트를 열지 못했습니다. 브라우저에 표시된 코드를 붙여넣고 '연결'을 누르세요.")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                if let e = loginError ?? account.autoError {
                    Text(e).font(.caption2).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))
        .onChange(of: account.isConnected) { _, connected in
            if connected {
                loginStarted = false
                loginCode = ""
                store.refresh()   // pull the live 5h/7d report right away
            }
        }
    }

    private func completeLogin() {
        loginBusy = true
        loginError = nil
        let code = loginCode
        Task {
            do {
                try await account.complete(code: code)
                loginCode = ""
                loginStarted = false
                store.refresh()   // pull the live 5h/7d report right away
            } catch {
                loginError = error.localizedDescription
            }
            loginBusy = false
        }
    }

    // MARK: Connections

    private var connectSection: some View {
        let unconnected = SourceKind.allCases.filter { s in
            !store.connections.contains { $0.source == s }
        }
        return VStack(alignment: .leading, spacing: 10) {
            Text("AI 연결").font(.subheadline.bold())
            ForEach(store.connections) { c in
                HStack(spacing: 8) {
                    Circle().fill(c.color).frame(width: 9, height: 9)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(c.name).font(.caption.bold())
                        Text(c.source.detail).font(.caption2).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    if c.id == connection?.id {
                        Text("현재 보는 중").font(.caption2).foregroundStyle(.secondary)
                    }
                    Button("해제") { store.removeConnection(id: c.id) }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            ForEach(unconnected) { source in
                ConnectRow(source: source, store: store)
            }
            Text("연결한 AI마다 메뉴바에 아이콘이 하나씩 생기고, 아이콘을 클릭하면 해당 AI의 통계와 설정이 열립니다.")
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let err = store.lastError {
                Text(err).font(.caption2).foregroundStyle(.red)
            }
            Text("위젯: 데스크탑 우클릭 → '위젯 편집' 또는 알림 센터에서 'AI 노동청' 위젯을 추가하세요.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("Made by KMokky")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .opacity(0.45)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 6)
        }
    }
}

/// Row offering an unconnected source; the color picked here becomes the
/// connection's menu bar icon color (mint by default).
private struct ConnectRow: View {
    let source: SourceKind
    let store: UsageStore
    @State private var color: Color = AIConnection.defaultColor

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(source.defaultName).font(.caption.bold())
                Text(source.detail).font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            if source.isAvailable {
                ColorPicker("", selection: $color, supportsOpacity: false)
                    .labelsHidden()
                    .help("메뉴바 아이콘 색")
                Button("연결") { store.addConnection(source: source, color: color) }
                    .font(.caption)
            } else {
                Text("감지되지 않음").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Components

private struct StatCard: View {
    let title: String
    let cost: Double?
    let tokens: Int?
    let sub: String?
    var fraction: Double? = nil
    var tint: Color = .accentColor

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(cost.map(fmtCost) ?? "—")
                    .font(.title3.bold()).monospacedDigit()
                HStack(spacing: 4) {
                    Text("\(tokens.map(fmtTokens) ?? "—") tok")
                        .font(.caption2).foregroundStyle(.secondary)
                    if let sub {
                        Text("· \(sub)").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
            if let fraction {
                Spacer(minLength: 0)
                RingGauge(fraction: fraction, size: 34, lineWidth: 3.5,
                          tint: tint, showLabel: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))
    }
}

private struct ModelRow: View {
    let model: ModelUsage
    let fraction: Double
    let unit: UnitKind

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(model.name).font(.caption.bold())
                Text(model.id).font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Text("\(fmtCost(model.cost)) · \(fmtTokens(model.tokens)) tok · \(model.messages)회")
                    .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(.tint)
                        .frame(width: Swift.max(3, geo.size.width * fraction))
                }
            }
            .frame(height: 5)
        }
    }

}

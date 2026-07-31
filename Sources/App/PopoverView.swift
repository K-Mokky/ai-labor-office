import SwiftUI
import AppKit

struct PopoverView: View {
    @ObservedObject var store: UsageStore
    var connectionID: String? = nil          // nil → onboarding (no connections yet)
    @AppStorage("menuBarUnit") private var unitKey = "percent"
    @State private var showSettings = false

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
                    if connection == nil {
                        onboarding
                        connectSection
                    } else {
                        summaryCards
                        modelSection
                        heatmapSection
                        if showSettings {
                            settingsSection
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
            HStack(spacing: 8) {
                StatCard(title: "세션 사용량", cost: s?.sessionCost, tokens: s?.sessionTokens,
                         sub: sessionSub, fraction: s.flatMap { $0.fraction(for: .session) },
                         tint: tint)
                StatCard(title: "주간 사용량", cost: s?.weekCost, tokens: s?.weekTokens,
                         sub: weekSub,
                         fraction: s.flatMap { $0.fraction(for: .week) },
                         tint: tint)
            }
        }
    }

    /// Prefers the provider's real 5h quota; falls back to the locally derived block.
    private var sessionSub: String? {
        guard let s = snapshot else { return nil }
        if let w = s.limitWindow("5h") { return "5시간 한도 · \(resetText(w.resetsAt))" }
        guard let end = s.sessionEnd, end > Date() else { return "활성 세션 없음" }
        return "종료까지 \(fmtRemaining(end))"
    }

    private var weekSub: String? {
        guard let s = snapshot else { return nil }
        if let w = s.limitWindow("7d") { return "7일 한도 · \(resetText(w.resetsAt))" }
        return "최근 7일 · 역대 최고 대비"
    }

    private func resetText(_ date: Date?) -> String {
        guard let date, date > Date() else { return "곧 초기화" }
        return "\(fmtRemaining(date)) 후 초기화"
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

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("아이콘 설정").font(.subheadline.bold())
            Picker("채움 기준", selection: metricBinding) {
                Text("세션 사용량").tag("session")
                Text("오늘 사용량").tag("today")
                Text("주간 사용량").tag("week")
            }
            .pickerStyle(.segmented)
            ColorPicker("아이콘 색", selection: colorBinding, supportsOpacity: false)
                .font(.caption)
            Picker("단위 (모델별·히트맵 표시)", selection: $unitKey) {
                ForEach(UnitKind.allCases, id: \.rawValue) { u in
                    Text(u.title).tag(u.rawValue)
                }
            }
            .pickerStyle(.menu)
            .font(.caption)
            Text("메뉴바 아이콘은 채움 기준 지표의 사용률만큼 아래에서 위로 채워집니다. 세션·주간은 Anthropic이 실제 적용하는 5시간·7일 한도 기준입니다(100% = 한도 소진). 한도를 읽지 못하면 역대 최대 기록 대비로 표시하고, 오늘은 항상 최고 일간 대비입니다.")
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))
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

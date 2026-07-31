import SwiftUI
import AppKit

struct PopoverView: View {
    @ObservedObject var store: UsageStore
    @AppStorage("menuBarMetric") private var metricKey = "session"
    @AppStorage("menuBarUnit") private var unitKey = "percent"

    private var unit: UnitKind { UnitKind(rawValue: unitKey) ?? .percent }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    summaryCards
                    modelSection
                    heatmapSection
                    settingsSection
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
            ProviderIcon(kind: store.snapshot?.providerKind ?? .generic, size: 16)
            Text("AI 사용량").font(.headline)
            Spacer()
            if let t = store.lastRefresh {
                Text(t, style: .time).font(.caption2).foregroundStyle(.secondary)
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

    // MARK: Summary cards

    private var summaryCards: some View {
        let s = store.snapshot
        return VStack(spacing: 8) {
            HStack(spacing: 8) {
                StatCard(title: "전체 사용량", cost: s?.totalCost, tokens: s?.totalTokens,
                         sub: s.map { "\($0.totalMessages)개 메시지" })
                StatCard(title: "오늘 사용량", cost: s?.todayCost, tokens: s?.todayTokens, sub: nil)
            }
            HStack(spacing: 8) {
                StatCard(title: "세션 사용량", cost: s?.sessionCost, tokens: s?.sessionTokens,
                         sub: sessionSub, fraction: s.flatMap { $0.fraction(for: .session) })
                StatCard(title: "주간 사용량", cost: s?.weekCost, tokens: s?.weekTokens,
                         sub: "최근 7일")
            }
        }
    }

    private var sessionSub: String? {
        guard let s = store.snapshot else { return nil }
        guard let end = s.sessionEnd, end > Date() else { return "활성 세션 없음" }
        let mins = Int(end.timeIntervalSinceNow / 60)
        return "종료까지 \(mins / 60)시간 \(mins % 60)분"
    }

    // MARK: Models

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("모델별 사용량").font(.subheadline.bold())
            if let models = store.snapshot?.models, !models.isEmpty {
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
            HeatmapView(dayMap: store.snapshot?.dayMap ?? [:],
                        weeks: 24, cellSize: 10.5, spacing: 3,
                        unit: unit == .tokens ? .tokens : .cost)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))
    }

    // MARK: Settings

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("표시 설정").font(.subheadline.bold())
            Picker("메뉴바 채움 기준", selection: $metricKey) {
                Text("세션 사용량").tag("session")
                Text("전체 사용량").tag("total")
                Text("오늘 사용량").tag("today")
                Text("주간 사용량").tag("week")
                ForEach(store.snapshot?.models ?? []) { m in
                    Text("\(m.name) 사용량").tag("model:\(m.id)")
                }
            }
            .pickerStyle(.menu)
            Picker("단위", selection: $unitKey) {
                ForEach(UnitKind.allCases, id: \.rawValue) { u in
                    Text(u.title).tag(u.rawValue)
                }
            }
            .pickerStyle(.segmented)
            Text("메뉴바 아이콘은 선택한 지표의 사용률만큼 아래에서 위로 채워집니다. 사용률은 역대 최대 기록 대비 비율 — 세션: 최대 5시간 세션, 오늘: 최고 일간, 주간: 최고 7일, 모델: 전체 중 비중.")
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
            Text("위젯: 데스크탑 우클릭 → '위젯 편집' 또는 알림 센터에서 'AI Usage' 위젯을 추가하세요.")
                .font(.caption2)
                .foregroundStyle(.secondary)
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
                          tint: .accentColor, showLabel: true)
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

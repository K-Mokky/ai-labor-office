import SwiftUI

/// Recorded-history totals for one connection (or every connected source).
/// Opened from the menu-bar context menu or the popover — not a quota ring.
struct LifetimeStatsView: View {
    @ObservedObject var store: UsageStore
    var connectionID: String?
    var combined: Bool

    private var connection: AIConnection? {
        guard !combined else { return nil }
        return store.connections.first { $0.id == connectionID } ?? store.connections.first
    }

    private var snapshot: UsageSnapshot? {
        if combined { return store.combined }
        return connection.flatMap { store.snapshots[$0.id] }
    }

    private var sources: [SourceKind] {
        if combined { return store.connections.map(\.source) }
        if let source = connection?.source { return [source] }
        return []
    }

    private var subscriptions: [(label: String, usd: Double)] {
        SourceKind.uniqueSubscriptions(in: sources)
    }

    private var monthlySub: Double {
        subscriptions.reduce(0) { $0 + $1.usd }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                totals
                subscription
                models
                heatmap
            }
            .padding(18)
        }
        .frame(minWidth: 480, minHeight: 360)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.title2.bold())
            if let range = snapshot?.historyRange {
                Text("기록 \(fmtDayKey(range.first)) – \(fmtDayKey(range.last)) · \(range.days)일 · 사용일 \(snapshot?.activeDayCount ?? 0)일")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Text("아직 기록된 사용량이 없어요.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var title: String {
        if combined { return "연결한 AI 합산 통계" }
        if let name = connection?.name { return "\(name) 전체 통계" }
        return "전체 통계"
    }

    private var totals: some View {
        let s = snapshot
        return VStack(alignment: .leading, spacing: 8) {
            Text("누적").font(.headline)
            HStack(spacing: 8) {
                LifetimeStat(title: "총 토큰", value: s.map { fmtTokens($0.totalTokens) } ?? "—")
                LifetimeStat(title: "API 추정 비용", value: s.map { fmtCost($0.totalCost) } ?? "—")
                LifetimeStat(title: "메시지", value: s.map { "\($0.totalMessages)개" } ?? "—")
            }
            HStack(spacing: 8) {
                LifetimeStat(title: "사용일 평균 토큰",
                             value: s.map { fmtTokens($0.averageDailyTokens) } ?? "—")
                LifetimeStat(title: "사용일 평균 비용",
                             value: s.map { fmtCost($0.averageDailyCost) } ?? "—")
                LifetimeStat(title: "오늘",
                             value: s.map { "\(fmtTokens($0.todayTokens)) · \(fmtCost($0.todayCost))" } ?? "—")
            }
            Text("API 추정 비용은 공개 단가로 환산한 값이에요. 구독 한도·크레딧과는 단위가 다릅니다.")
                .font(.caption).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var subscription: some View {
        if !subscriptions.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("구독").font(.headline)
                ForEach(Array(subscriptions.enumerated()), id: \.offset) { _, item in
                    HStack {
                        Text(item.label)
                        Spacer()
                        Text("\(fmtCost(item.usd)) /월")
                            .monospacedDigit()
                    }
                    .font(.callout)
                }
                if subscriptions.count > 1 {
                    HStack {
                        Text("합계").foregroundStyle(.secondary)
                        Spacer()
                        Text("\(fmtCost(monthlySub)) /월")
                            .monospacedDigit()
                    }
                    .font(.callout)
                }
                if let s = snapshot, let range = s.historyRange, monthlySub > 0 {
                    let months = max(1.0, Double(range.days) / 30.44)
                    let billed = monthlySub * months
                    Text("같은 기간 구독료 약 \(fmtCost(billed)) (\(fmtCost(monthlySub))/월 × \(String(format: "%.1f", months))개월). API 추정 \(fmtCost(s.totalCost))와는 별개입니다.")
                        .font(.caption).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))
        }
    }

    @ViewBuilder
    private var models: some View {
        let list = snapshot?.models ?? []
        VStack(alignment: .leading, spacing: 8) {
            Text("모델별").font(.headline)
            if list.isEmpty {
                Text("데이터 없음").font(.callout).foregroundStyle(.secondary)
            } else {
                let maxTok = list.map(\.tokens).max() ?? 1
                ForEach(list) { m in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(m.name).font(.caption.bold())
                            Text(m.id).font(.caption2).foregroundStyle(.tertiary)
                            Spacer()
                            Text("\(fmtTokens(m.tokens)) tok · \(fmtCost(m.cost)) · \(m.messages)회")
                                .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                        }
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(.quaternary)
                                Capsule().fill(.tint)
                                    .frame(width: max(3, geo.size.width * Double(m.tokens) / Double(max(maxTok, 1))))
                            }
                        }
                        .frame(height: 5)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))
    }

    private var heatmap: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("기여 그래프 (전체 기간)").font(.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                HeatmapView(dayMap: snapshot?.dayMap ?? [:],
                            weeks: snapshot?.historyWeeks ?? 24,
                            cellSize: 8.5, spacing: 2.5,
                            unit: .tokens)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))
    }
}

private struct LifetimeStat: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.bold()).monospacedDigit()
                .lineLimit(2)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))
    }
}

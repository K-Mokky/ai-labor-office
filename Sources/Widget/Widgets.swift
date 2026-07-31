import WidgetKit
import SwiftUI

// MARK: - Timeline

struct UsageEntry: TimelineEntry {
    let date: Date
    let snapshot: UsageSnapshot?
    let isPlaceholder: Bool
}

struct UsageProvider: TimelineProvider {
    func placeholder(in context: Context) -> UsageEntry {
        UsageEntry(date: Date(), snapshot: .placeholder, isPlaceholder: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        if context.isPreview {
            completion(UsageEntry(date: Date(), snapshot: SnapshotIO.load() ?? .placeholder, isPlaceholder: false))
        } else {
            completion(currentEntry())
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        let entry = currentEntry()
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(15 * 60))))
    }

    private func currentEntry() -> UsageEntry {
        UsageEntry(date: Date(), snapshot: SnapshotIO.load(), isPlaceholder: false)
    }
}

// MARK: - Widget bundle

@main
struct AIUsageWidgetBundle: WidgetBundle {
    var body: some Widget {
        ContributionWidget()
        SummaryWidget()
        ModelsWidget()
        SessionWidget()
    }
}

// MARK: - Contribution graph widget

struct ContributionWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "contribution", provider: UsageProvider()) { entry in
            ContributionView(entry: entry)
                .containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("AI 기여 그래프")
        .description("깃허브 스타일의 일별 AI 사용량 히트맵입니다.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

struct ContributionView: View {
    let entry: UsageEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let s = entry.snapshot {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    ProviderIcon(kind: s.providerKind, size: 13)
                    Text("AI 기여 그래프").font(.caption.bold())
                    Spacer()
                    Text("오늘 \(fmtCost(s.todayCost))")
                        .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                }
                GeometryReader { geo in
                    let weeks = family == .systemLarge ? 21 : 22
                    let spacing: CGFloat = 2.5
                    let cell = min(
                        (geo.size.width - 18) / CGFloat(weeks) - spacing,
                        (geo.size.height - 14) / 7 - spacing
                    )
                    HeatmapView(dayMap: s.dayMap, weeks: weeks, cellSize: max(cell, 4),
                                spacing: spacing, unit: .cost, interactive: false)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }
                if family == .systemLarge {
                    Divider()
                    HStack {
                        WidgetStat(title: "전체", value: fmtCost(s.totalCost))
                        Spacer()
                        WidgetStat(title: "주간", value: fmtCost(s.weekCost))
                        Spacer()
                        WidgetStat(title: "오늘", value: fmtCost(s.todayCost))
                        Spacer()
                        WidgetStat(title: "세션", value: fmtCost(s.sessionCost))
                    }
                }
            }
        } else {
            NoDataView()
        }
    }
}

// MARK: - Summary widget

struct SummaryWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "summary", provider: UsageProvider()) { entry in
            SummaryView(entry: entry)
                .containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("AI 사용량 요약")
        .description("전체 · 오늘 · 세션 사용량을 한눈에 보여줍니다.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct SummaryView: View {
    let entry: UsageEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let s = entry.snapshot {
            if family == .systemSmall {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 4) {
                        ProviderIcon(kind: s.providerKind, size: 12)
                        Text("AI 사용량").font(.caption2.bold())
                    }
                    Spacer(minLength: 0)
                    BigStat(title: "전체", cost: s.totalCost, tokens: s.totalTokens)
                    BigStat(title: "오늘", cost: s.todayCost, tokens: s.todayTokens)
                    BigStat(title: "세션", cost: s.sessionCost, tokens: s.sessionTokens)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 4) {
                        ProviderIcon(kind: s.providerKind, size: 13)
                        Text("AI 사용량 요약").font(.caption.bold())
                        Spacer()
                        Text("\(s.totalMessages)개 메시지")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    HStack(alignment: .top) {
                        BigStat(title: "전체", cost: s.totalCost, tokens: s.totalTokens)
                        Spacer()
                        BigStat(title: "주간", cost: s.weekCost, tokens: s.weekTokens)
                        Spacer()
                        BigStat(title: "오늘", cost: s.todayCost, tokens: s.todayTokens)
                        Spacer()
                        BigStat(title: "세션", cost: s.sessionCost, tokens: s.sessionTokens)
                    }
                    Spacer(minLength: 0)
                    if let top = s.models.first {
                        Text("최다 사용 모델: \(top.name) (\(fmtCost(top.cost)))")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            NoDataView()
        }
    }
}

// MARK: - Model breakdown widget

struct ModelsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "models", provider: UsageProvider()) { entry in
            ModelsView(entry: entry)
                .containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("모델별 AI 사용량")
        .description("Fable, Opus 등 모델별 사용량을 보여줍니다.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct ModelsView: View {
    let entry: UsageEntry

    var body: some View {
        if let s = entry.snapshot, !s.models.isEmpty {
            let maxCost = s.models.map(\.cost).max() ?? 1
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: "cpu").font(.caption2).foregroundStyle(.green)
                    Text("모델별 사용량").font(.caption2.bold())
                }
                Spacer(minLength: 0)
                ForEach(s.models.prefix(4)) { m in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(m.name).font(.caption2.bold())
                            Spacer()
                            Text(fmtCost(m.cost)).font(.caption2).monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(.quaternary)
                                Capsule().fill(.green)
                                    .frame(width: max(2, geo.size.width * m.cost / max(maxCost, 0.0001)))
                            }
                        }
                        .frame(height: 4)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            NoDataView()
        }
    }
}

// MARK: - Session widget

struct SessionWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "session", provider: UsageProvider()) { entry in
            SessionView(entry: entry)
                .containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("AI 세션 사용량")
        .description("현재 5시간 세션의 사용률(%)과 남은 시간을 보여줍니다.")
        .supportedFamilies([.systemSmall])
    }
}

struct SessionView: View {
    let entry: UsageEntry

    var body: some View {
        if let s = entry.snapshot {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: "clock.fill").font(.caption2).foregroundStyle(.green)
                    Text("세션 사용량").font(.caption2.bold())
                }
                Spacer(minLength: 0)
                HStack(spacing: 10) {
                    RingGauge(fraction: s.fraction(for: .session), size: 46, lineWidth: 5,
                              tint: .green, showLabel: true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(fmtCost(s.sessionCost))
                            .font(.system(size: 17, weight: .bold)).monospacedDigit()
                        Text("\(fmtTokens(s.sessionTokens)) tok")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                if let start = s.sessionStart, let end = s.sessionEnd, end > entry.date {
                    ProgressView(value: entry.date.timeIntervalSince(start),
                                 total: end.timeIntervalSince(start))
                        .tint(.green)
                    Text("종료까지 \(remaining(end))")
                        .font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text("활성 세션 없음").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            NoDataView()
        }
    }

    private func remaining(_ end: Date) -> String {
        let mins = max(0, Int(end.timeIntervalSince(entry.date) / 60))
        return mins >= 60 ? "\(mins / 60)시간 \(mins % 60)분" : "\(mins)분"
    }
}

// MARK: - Small components

struct WidgetStat: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.bold()).monospacedDigit()
        }
    }
}

struct BigStat: View {
    let title: String
    let cost: Double
    let tokens: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(fmtCost(cost)).font(.callout.bold()).monospacedDigit()
            Text("\(fmtTokens(tokens)) tok").font(.caption2).foregroundStyle(.tertiary)
        }
    }
}

struct NoDataView: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "exclamationmark.chart.bar")
                .font(.title3).foregroundStyle(.secondary)
            Text("AI Usage 앱을 실행하면\n데이터가 표시됩니다")
                .font(.caption2).multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

import WidgetKit
import SwiftUI

// MARK: - Timeline

struct UsageEntry: TimelineEntry {
    let date: Date
    let snapshot: UsageSnapshot?
    let unit: UnitKind          // primary number: cost or tokens (widget setting)
    let sourceName: String?     // non-nil when a single source is selected
    let isPlaceholder: Bool
}

/// Reads the app-written payload and per-widget settings. Widgets can't host
/// their own edit UI in this swiftc-only build (AppIntents needs Xcode's
/// metadata processor), so "위젯 설정" lives in the app's popover instead.
struct UsageProvider: TimelineProvider {
    let kind: String

    func placeholder(in context: Context) -> UsageEntry {
        UsageEntry(date: Date(), snapshot: .placeholder, unit: .cost,
                   sourceName: nil, isPlaceholder: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        if context.isPreview {
            let entry = currentEntry()
            completion(entry.snapshot == nil
                ? UsageEntry(date: Date(), snapshot: .placeholder, unit: .cost,
                             sourceName: nil, isPlaceholder: false)
                : entry)
        } else {
            completion(currentEntry())
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        let entry = currentEntry()
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(15 * 60))))
    }

    private func currentEntry() -> UsageEntry {
        let config = SnapshotIO.loadWidgetConfigs().config(for: kind)
        let payload = SnapshotIO.loadPayload()
        // Older app versions only write snapshot.json; fall back to it.
        let snapshot = payload?.snapshot(for: config) ?? SnapshotIO.load()
        return UsageEntry(date: Date(), snapshot: snapshot,
                          unit: config.unitKind,
                          sourceName: payload?.name(for: config),
                          isPlaceholder: false)
    }
}

/// "제목 · 소스" when a single source is selected in 위젯 설정.
private func widgetTitle(_ base: String, _ entry: UsageEntry) -> String {
    entry.sourceName.map { "\(base) · \($0)" } ?? base
}

/// Primary/secondary value strings honoring the widget's unit setting.
private func primaryValue(cost: Double, tokens: Int, unit: UnitKind) -> String {
    unit == .tokens ? fmtTokens(tokens) : fmtCost(cost)
}

private func secondaryValue(cost: Double, tokens: Int, unit: UnitKind) -> String {
    unit == .tokens ? fmtCost(cost) : "\(fmtTokens(tokens)) tok"
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
        StaticConfiguration(kind: "contribution", provider: UsageProvider(kind: "contribution")) { entry in
            ContributionView(entry: entry)
                .containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("AI 기여 그래프")
        .description("깃허브 스타일의 일별 AI 사용량 히트맵입니다. 앱의 '위젯 설정'에서 데이터 소스와 단위를 바꿀 수 있습니다.")
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
                    Text(widgetTitle("AI 기여 그래프", entry)).font(.caption.bold())
                    Spacer()
                    Text("오늘 \(primaryValue(cost: s.todayCost, tokens: s.todayTokens, unit: entry.unit))")
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
                                spacing: spacing,
                                unit: entry.unit == .tokens ? .tokens : .cost,
                                interactive: false)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }
                if family == .systemLarge {
                    Divider()
                    HStack {
                        WidgetStat(title: "전체", value: primaryValue(cost: s.totalCost, tokens: s.totalTokens, unit: entry.unit))
                        Spacer()
                        WidgetStat(title: "주간", value: primaryValue(cost: s.weekCost, tokens: s.weekTokens, unit: entry.unit))
                        Spacer()
                        WidgetStat(title: "오늘", value: primaryValue(cost: s.todayCost, tokens: s.todayTokens, unit: entry.unit))
                        Spacer()
                        WidgetStat(title: "세션", value: primaryValue(cost: s.sessionCost, tokens: s.sessionTokens, unit: entry.unit))
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
        StaticConfiguration(kind: "summary", provider: UsageProvider(kind: "summary")) { entry in
            SummaryView(entry: entry)
                .containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("AI 사용량 요약")
        .description("전체 · 오늘 · 세션 사용량을 한눈에 보여줍니다. 앱의 '위젯 설정'에서 데이터 소스와 단위를 바꿀 수 있습니다.")
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
                        Text(widgetTitle("AI 사용량", entry)).font(.caption2.bold())
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    BigStat(title: "전체", cost: s.totalCost, tokens: s.totalTokens, unit: entry.unit)
                    BigStat(title: "오늘", cost: s.todayCost, tokens: s.todayTokens, unit: entry.unit)
                    BigStat(title: "세션", cost: s.sessionCost, tokens: s.sessionTokens, unit: entry.unit)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 4) {
                        ProviderIcon(kind: s.providerKind, size: 13)
                        Text(widgetTitle("AI 사용량 요약", entry)).font(.caption.bold())
                            .lineLimit(1)
                        Spacer()
                        Text("\(s.totalMessages)개 메시지")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    HStack(alignment: .top) {
                        BigStat(title: "전체", cost: s.totalCost, tokens: s.totalTokens, unit: entry.unit)
                        Spacer()
                        BigStat(title: "주간", cost: s.weekCost, tokens: s.weekTokens, unit: entry.unit)
                        Spacer()
                        BigStat(title: "오늘", cost: s.todayCost, tokens: s.todayTokens, unit: entry.unit)
                        Spacer()
                        BigStat(title: "세션", cost: s.sessionCost, tokens: s.sessionTokens, unit: entry.unit)
                    }
                    Spacer(minLength: 0)
                    if let top = s.models.first {
                        Text("최다 사용 모델: \(top.name) (\(entry.unit == .tokens ? fmtTokens(top.tokens) : fmtCost(top.cost)))")
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
        StaticConfiguration(kind: "models", provider: UsageProvider(kind: "models")) { entry in
            ModelsView(entry: entry)
                .containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("모델별 AI 사용량")
        .description("Fable, Opus 등 모델별 사용량을 보여줍니다. 앱의 '위젯 설정'에서 데이터 소스와 단위를 바꿀 수 있습니다.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct ModelsView: View {
    let entry: UsageEntry

    var body: some View {
        if let s = entry.snapshot, !s.models.isEmpty {
            let byTokens = entry.unit == .tokens
            let maxCost = s.models.map(\.cost).max() ?? 1
            let maxTokens = s.models.map(\.tokens).max() ?? 1
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: "cpu").font(.caption2).foregroundStyle(.green)
                    Text(widgetTitle("모델별 사용량", entry)).font(.caption2.bold())
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                ForEach(s.models.prefix(4)) { m in
                    let fraction = byTokens
                        ? Double(m.tokens) / Double(Swift.max(maxTokens, 1))
                        : m.cost / Swift.max(maxCost, 0.0001)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(m.name).font(.caption2.bold())
                            Spacer()
                            Text(byTokens ? fmtTokens(m.tokens) : fmtCost(m.cost))
                                .font(.caption2).monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(.quaternary)
                                Capsule().fill(.green)
                                    .frame(width: max(2, geo.size.width * fraction))
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
        StaticConfiguration(kind: "session", provider: UsageProvider(kind: "session")) { entry in
            SessionView(entry: entry)
                .containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("AI 세션 사용량")
        .description("현재 5시간 세션의 사용률(%)과 남은 시간을 보여줍니다. 앱의 '위젯 설정'에서 데이터 소스와 단위를 바꿀 수 있습니다.")
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
                    Text(widgetTitle("세션 사용량", entry)).font(.caption2.bold())
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                HStack(spacing: 10) {
                    RingGauge(fraction: s.fraction(for: .session), size: 46, lineWidth: 5,
                              tint: .green, showLabel: true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(primaryValue(cost: s.sessionCost, tokens: s.sessionTokens, unit: entry.unit))
                            .font(.system(size: 17, weight: .bold)).monospacedDigit()
                        Text(secondaryValue(cost: s.sessionCost, tokens: s.sessionTokens, unit: entry.unit))
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
    var unit: UnitKind = .cost

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(primaryValue(cost: cost, tokens: tokens, unit: unit))
                .font(.callout.bold()).monospacedDigit()
            Text(secondaryValue(cost: cost, tokens: tokens, unit: unit))
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }
}

struct NoDataView: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "exclamationmark.chart.bar")
                .font(.title3).foregroundStyle(.secondary)
            Text("AI 노동청 앱을 실행하면\n데이터가 표시됩니다")
                .font(.caption2).multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

import SwiftUI

@main
struct AIUsageApp: App {
    @StateObject private var store = UsageStore()

    var body: some Scene {
        MenuBarExtra {
            PopoverView(store: store)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)
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
    }
}

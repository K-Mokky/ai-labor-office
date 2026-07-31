import SwiftUI

/// GitHub-style contribution heatmap of daily AI usage.
struct HeatmapView: View {
    let dayMap: [String: DayUsage]
    var weeks: Int = 20
    var cellSize: CGFloat = 11
    var spacing: CGFloat = 3
    var unit: UnitKind = .cost
    var interactive: Bool = true
    var showMonthLabels: Bool = true
    var showWeekdayLabels: Bool = true

    @Environment(\.colorScheme) private var colorScheme
    @State private var hovered: DayUsage?
    @State private var hoveredDate: Date?

    private var leftGutter: CGFloat { showWeekdayLabels ? 18 : 0 }
    private var topGutter: CGFloat { showMonthLabels ? 14 : 0 }

    private var gridWidth: CGFloat { CGFloat(weeks) * (cellSize + spacing) - spacing }
    private var gridHeight: CGFloat { 7 * (cellSize + spacing) - spacing }

    var totalSize: CGSize {
        CGSize(width: leftGutter + gridWidth, height: topGutter + gridHeight)
    }

    /// First rendered date: Sunday of the column `weeks-1` weeks before this week's Sunday.
    private var gridStart: Date {
        let cal = calendar
        let today = cal.startOfDay(for: Date())
        let weekday = cal.component(.weekday, from: today) // 1 = Sunday
        let thisSunday = cal.date(byAdding: .day, value: -(weekday - 1), to: today)!
        return cal.date(byAdding: .day, value: -7 * (weeks - 1), to: thisSunday)!
    }

    private var calendar: Calendar {
        var c = Calendar.current
        c.firstWeekday = 1
        return c
    }

    private var maxValue: Double {
        var m = 0.0
        for d in dayMap.values {
            let v = unit == .cost ? d.cost : Double(d.tokens)
            if v > m { m = v }
        }
        return m
    }

    private func level(_ v: Double, max: Double) -> Int {
        guard v > 0, max > 0 else { return 0 }
        let r = v / max
        if r > 0.6 { return 4 }
        if r > 0.3 { return 3 }
        if r > 0.12 { return 2 }
        return 1
    }

    static func palette(dark: Bool) -> [Color] {
        func hex(_ v: UInt32) -> Color {
            Color(red: Double((v >> 16) & 0xFF) / 255,
                  green: Double((v >> 8) & 0xFF) / 255,
                  blue: Double(v & 0xFF) / 255)
        }
        return dark
            ? [hex(0x2D333B), hex(0x0E4429), hex(0x006D32), hex(0x26A641), hex(0x39D353)]
            : [hex(0xEBEDF0), hex(0x9BE9A8), hex(0x40C463), hex(0x30A14E), hex(0x216E39)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            canvas
                .frame(width: totalSize.width, height: totalSize.height)
            if interactive {
                footer
            }
        }
    }

    private var canvas: some View {
        let colors = Self.palette(dark: colorScheme == .dark)
        let cal = calendar
        let start = gridStart
        let today = cal.startOfDay(for: Date())
        let maxV = maxValue

        return Canvas { ctx, _ in
            // Month labels
            if showMonthLabels {
                var lastMonth = -1
                for w in 0..<weeks {
                    guard let d = cal.date(byAdding: .day, value: w * 7, to: start) else { continue }
                    let month = cal.component(.month, from: d)
                    if month != lastMonth {
                        let x = leftGutter + CGFloat(w) * (cellSize + spacing)
                        ctx.draw(
                            Text("\(month)월").font(.system(size: 9)).foregroundColor(.secondary),
                            at: CGPoint(x: x, y: 5), anchor: .leading
                        )
                        lastMonth = month
                    }
                }
            }
            // Weekday labels (Mon/Wed/Fri, Sunday-first rows)
            if showWeekdayLabels {
                for (row, label) in [(1, "월"), (3, "수"), (5, "금")] {
                    let y = topGutter + CGFloat(row) * (cellSize + spacing) + cellSize / 2
                    ctx.draw(
                        Text(label).font(.system(size: 8)).foregroundColor(.secondary),
                        at: CGPoint(x: 0, y: y), anchor: .leading
                    )
                }
            }
            // Cells
            for w in 0..<weeks {
                for r in 0..<7 {
                    guard let d = cal.date(byAdding: .day, value: w * 7 + r, to: start),
                          d <= today else { continue }
                    let key = dayKeyFormatter.string(from: d)
                    let day = dayMap[key]
                    let v = unit == .cost ? (day?.cost ?? 0) : Double(day?.tokens ?? 0)
                    let rect = CGRect(
                        x: leftGutter + CGFloat(w) * (cellSize + spacing),
                        y: topGutter + CGFloat(r) * (cellSize + spacing),
                        width: cellSize, height: cellSize
                    )
                    var color = colors[level(v, max: maxV)]
                    if let hd = hoveredDate, cal.isDate(hd, inSameDayAs: d) {
                        color = color.opacity(0.7)
                    }
                    ctx.fill(Path(roundedRect: rect, cornerRadius: 2.5), with: .color(color))
                }
            }
        }
        .onContinuousHover { phase in
            guard interactive else { return }
            switch phase {
            case .active(let p):
                let w = Int((p.x - leftGutter) / (cellSize + spacing))
                let r = Int((p.y - topGutter) / (cellSize + spacing))
                guard w >= 0, w < weeks, r >= 0, r < 7,
                      let d = cal.date(byAdding: .day, value: w * 7 + r, to: start),
                      d <= today else {
                    hovered = nil; hoveredDate = nil
                    return
                }
                hoveredDate = d
                let key = dayKeyFormatter.string(from: d)
                hovered = dayMap[key] ?? DayUsage(date: key, cost: 0, tokens: 0, messages: 0)
            case .ended:
                hovered = nil; hoveredDate = nil
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if let h = hovered {
                Text("\(prettyDay(h.date))  ·  \(fmtCost(h.cost))  ·  \(fmtTokens(h.tokens)) tok  ·  \(h.messages)회")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            } else {
                Text("적음").font(.system(size: 9)).foregroundStyle(.secondary)
                HStack(spacing: 3) {
                    ForEach(0..<5, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Self.palette(dark: colorScheme == .dark)[i])
                            .frame(width: 9, height: 9)
                    }
                }
                Text("많음").font(.system(size: 9)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(height: 14)
        .padding(.leading, leftGutter)
    }

    private func prettyDay(_ key: String) -> String {
        guard let d = dayKeyFormatter.date(from: key) else { return key }
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "M월 d일 (E)"
        return f.string(from: d)
    }

    private var cal: Calendar { calendar }
    private var start: Date { gridStart }
    private var today: Date { calendar.startOfDay(for: Date()) }
}

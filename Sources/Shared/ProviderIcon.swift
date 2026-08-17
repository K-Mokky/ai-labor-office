import SwiftUI

// MARK: - Provider detection

enum ProviderKind: String {
    case claude, gpt, gemini, cursor, grok, generic

    /// Detects the provider from a raw provider string (gjc stats.db) or a model id.
    static func detect(provider: String?, model: String?) -> ProviderKind {
        let p = (provider ?? "").lowercased()
        let m = (model ?? "").lowercased()
        // Cursor runs Claude/GPT models under its own subscription, so its
        // provider string must win over the model id checks below.
        if p.contains("cursor") || m.contains("composer") || m.contains("cursor") {
            return .cursor
        }
        if p.contains("xai") || p.contains("x-ai") || p.contains("grok") || m.contains("grok") {
            return .grok
        }
        if p.contains("anthropic") || p.contains("claude") || m.contains("claude") {
            return .claude
        }
        if p.contains("google") || p.contains("gemini") || m.contains("gemini") {
            return .gemini
        }
        if p.contains("openai") || p.contains("gpt") || p.contains("codex")
            || m.hasPrefix("gpt") || m.hasPrefix("o1") || m.hasPrefix("o3")
            || m.hasPrefix("o4") || m.contains("codex") {
            return .gpt
        }
        return .generic
    }

    var brandColor: Color {
        switch self {
        case .claude: return Color(red: 0.85, green: 0.47, blue: 0.34)  // Anthropic terracotta
        case .gpt: return Color(red: 0.06, green: 0.64, blue: 0.50)     // OpenAI teal
        case .gemini: return Color(red: 0.35, green: 0.49, blue: 0.95)  // Gemini blue
        case .cursor: return Color(red: 0.42, green: 0.47, blue: 0.60)  // Cursor slate
        case .grok: return Color(red: 0.58, green: 0.58, blue: 0.62)    // xAI neutral
        case .generic: return .accentColor
        }
    }
}

// MARK: - Provider glyph

/// Small vector glyph for the AI provider currently in use.
/// `color == nil` uses the provider brand color.
struct ProviderIcon: View {
    let kind: ProviderKind
    var size: CGFloat = 15
    var color: Color? = nil

    var body: some View {
        let c = color ?? kind.brandColor
        switch kind {
        case .claude: claude(c)
        case .gpt: gpt(c)
        case .gemini: gemini(c)
        case .cursor: cursor(c)
        case .grok: grok(c)
        case .generic:
            Image(systemName: "chart.bar.fill")
                .font(.system(size: size * 0.75))
                .foregroundStyle(c)
                .frame(width: size, height: size)
        }
    }

    /// Claude: irregular starburst (asterisk) mark.
    private func claude(_ color: Color) -> some View {
        Canvas { ctx, sz in
            let center = CGPoint(x: sz.width / 2, y: sz.height / 2)
            let lens: [CGFloat] = [1, 0.62, 0.88, 0.6, 0.97, 0.64,
                                   1, 0.62, 0.9, 0.6, 0.95, 0.64]
            for i in 0..<12 {
                let a = CGFloat(i) / 12 * 2 * .pi - .pi / 2 + 0.13
                let r = sz.width * 0.46 * lens[i]
                var p = Path()
                p.move(to: CGPoint(x: center.x + cos(a) * sz.width * 0.07,
                                   y: center.y + sin(a) * sz.width * 0.07))
                p.addLine(to: CGPoint(x: center.x + cos(a) * r,
                                      y: center.y + sin(a) * r))
                ctx.stroke(p, with: .color(color),
                           style: StrokeStyle(lineWidth: sz.width * 0.12, lineCap: .round))
            }
        }
        .frame(width: size, height: size)
    }

    /// GPT: hexagram weave (simplified OpenAI knot).
    private func gpt(_ color: Color) -> some View {
        Canvas { ctx, sz in
            let center = CGPoint(x: sz.width / 2, y: sz.height / 2)
            let r = sz.width * 0.44
            func vertex(_ i: Int) -> CGPoint {
                let a = CGFloat(i) / 6 * 2 * .pi - .pi / 2
                return CGPoint(x: center.x + cos(a) * r, y: center.y + sin(a) * r)
            }
            for i in 0..<6 {
                var p = Path()
                p.move(to: vertex(i))
                p.addLine(to: vertex((i + 2) % 6))
                ctx.stroke(p, with: .color(color),
                           style: StrokeStyle(lineWidth: sz.width * 0.11, lineCap: .round))
            }
        }
        .frame(width: size, height: size)
    }

    /// Cursor: isometric cube — hexagon outline with the front-corner edges.
    private func cursor(_ color: Color) -> some View {
        Canvas { ctx, sz in
            let c = CGPoint(x: sz.width / 2, y: sz.height / 2)
            let r = sz.width * 0.44
            func vertex(_ i: Int) -> CGPoint {
                let a = CGFloat(i) / 6 * 2 * .pi - .pi / 2
                return CGPoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r)
            }
            let stroke = StrokeStyle(lineWidth: sz.width * 0.1,
                                     lineCap: .round, lineJoin: .round)
            var hex = Path()
            hex.move(to: vertex(0))
            for i in 1..<6 { hex.addLine(to: vertex(i)) }
            hex.closeSubpath()
            ctx.stroke(hex, with: .color(color), style: stroke)
            for i in stride(from: 0, to: 6, by: 2) {
                var p = Path()
                p.move(to: c)
                p.addLine(to: vertex(i))
                ctx.stroke(p, with: .color(color), style: stroke)
            }
        }
        .frame(width: size, height: size)
    }

    /// Grok (xAI): elongated X — a long diagonal crossed by a broken stroke.
    private func grok(_ color: Color) -> some View {
        Canvas { ctx, sz in
            let w = sz.width
            let stroke = StrokeStyle(lineWidth: w * 0.13, lineCap: .round)
            var main = Path()
            main.move(to: CGPoint(x: w * 0.14, y: w * 0.86))
            main.addLine(to: CGPoint(x: w * 0.86, y: w * 0.14))
            ctx.stroke(main, with: .color(color), style: stroke)
            var top = Path()
            top.move(to: CGPoint(x: w * 0.14, y: w * 0.14))
            top.addLine(to: CGPoint(x: w * 0.38, y: w * 0.38))
            ctx.stroke(top, with: .color(color), style: stroke)
            var bottom = Path()
            bottom.move(to: CGPoint(x: w * 0.62, y: w * 0.62))
            bottom.addLine(to: CGPoint(x: w * 0.86, y: w * 0.86))
            ctx.stroke(bottom, with: .color(color), style: stroke)
        }
        .frame(width: size, height: size)
    }

    /// Gemini: four-point spark with concave edges.
    private func gemini(_ color: Color) -> some View {
        Canvas { ctx, sz in
            let c = CGPoint(x: sz.width / 2, y: sz.height / 2)
            let r = sz.width * 0.5
            let pinch = r * 0.18
            var p = Path()
            p.move(to: CGPoint(x: c.x, y: c.y - r))
            p.addQuadCurve(to: CGPoint(x: c.x + r, y: c.y),
                           control: CGPoint(x: c.x + pinch, y: c.y - pinch))
            p.addQuadCurve(to: CGPoint(x: c.x, y: c.y + r),
                           control: CGPoint(x: c.x + pinch, y: c.y + pinch))
            p.addQuadCurve(to: CGPoint(x: c.x - r, y: c.y),
                           control: CGPoint(x: c.x - pinch, y: c.y + pinch))
            p.addQuadCurve(to: CGPoint(x: c.x, y: c.y - r),
                           control: CGPoint(x: c.x - pinch, y: c.y - pinch))
            p.closeSubpath()
            ctx.fill(p, with: .color(color))
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Ring gauge

/// Circular usage gauge; a full ring = 100%.
/// `fraction == nil` renders the empty track with an em dash label.
struct RingGauge: View {
    var fraction: Double?
    var size: CGFloat = 14
    var lineWidth: CGFloat = 2.5
    var tint: Color = .primary
    var showLabel: Bool = false

    var body: some View {
        ZStack {
            Circle().stroke(tint.opacity(0.22), lineWidth: lineWidth)
            if let f = fraction {
                Circle()
                    .trim(from: 0, to: CGFloat(min(max(f, 0.004), 1)))
                    .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            if showLabel {
                Text(fraction.map(fmtPercent) ?? "—")
                    .font(.system(size: size * 0.28, weight: .bold))
                    .monospacedDigit()
            }
        }
        .padding(lineWidth / 2)
        .frame(width: size, height: size)
    }
}

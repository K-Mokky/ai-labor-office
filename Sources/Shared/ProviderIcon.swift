import SwiftUI

// MARK: - Provider detection

enum ProviderKind: String {
    case claude, gpt, generic

    /// Detects the provider from a raw provider string (gjc stats.db) or a model id.
    static func detect(provider: String?, model: String?) -> ProviderKind {
        let p = (provider ?? "").lowercased()
        let m = (model ?? "").lowercased()
        if p.contains("anthropic") || p.contains("claude") || m.contains("claude") {
            return .claude
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

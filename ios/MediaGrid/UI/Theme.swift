import SwiftUI

enum Theme {
    static let pink = Color(hex: 0xFF5FA2)
    static let violet = Color(hex: 0x8F6BFF)
    static let cyan = Color(hex: 0x2FD4FF)
    static let mint = Color(hex: 0x3CF2B5)
    static let ink = Color(hex: 0x0B0A16)

    static let brand = LinearGradient(colors: [pink, violet, cyan], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let palettes: [[Color]] = [
        [Color(hex: 0xFF5FA2), Color(hex: 0xFF8A5B)],
        [Color(hex: 0x8F6BFF), Color(hex: 0x5B3BEA)],
        [Color(hex: 0x2FD4FF), Color(hex: 0x3D7BFF)],
        [Color(hex: 0x3CF2B5), Color(hex: 0x17B8C9)],
        [Color(hex: 0xF7971E), Color(hex: 0xFF5F6D)],
        [Color(hex: 0x614385), Color(hex: 0x516395)],
    ]
}

/// Deep animated backdrop that the Liquid Glass picks colour up from.
struct AppBackground: View {
    @State private var t = false
    var body: some View {
        ZStack {
            Theme.ink
            Circle().fill(Theme.violet.opacity(0.45)).frame(width: 420).blur(radius: 120)
                .offset(x: t ? -120 : -60, y: t ? -260 : -320)
            Circle().fill(Theme.pink.opacity(0.28)).frame(width: 360).blur(radius: 120)
                .offset(x: t ? 160 : 120, y: t ? 40 : -20)
            Circle().fill(Theme.cyan.opacity(0.22)).frame(width: 380).blur(radius: 130)
                .offset(x: t ? -80 : -140, y: t ? 420 : 360)
        }
        .ignoresSafeArea()
        .onAppear { withAnimation(.easeInOut(duration: 14).repeatForever(autoreverses: true)) { t.toggle() } }
    }
}

struct GlassCard<Content: View>: View {
    var radius: CGFloat = 26
    var tint: Color? = nil
    @ViewBuilder var content: () -> Content
    var body: some View {
        content()
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(tint.map { Glass.regular.tint($0.opacity(0.25)) } ?? Glass.regular, in: .rect(cornerRadius: radius))
    }
}

struct SectionHeader: View {
    let title: String
    var action: String? = nil
    var onAction: (() -> Void)? = nil
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.title2.weight(.bold))
            Spacer()
            if let action, let onAction {
                Button(action, action: onAction).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
    }
}

struct StatusDot: View {
    let state: LinkState
    @State private var pulse = false
    var color: Color {
        switch state {
        case .online: return Theme.mint
        case .connecting: return .orange
        default: return .red
        }
    }
    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8)
            .overlay(Circle().stroke(color.opacity(0.6), lineWidth: 6).scaleEffect(pulse ? 2 : 1).opacity(pulse ? 0 : 1))
            .onAppear { withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { pulse = true } }
    }
}

/// Animated equalizer bars shown next to the song that's playing.
struct EqualizerBars: View {
    var playing: Bool
    var color: Color = Theme.violet
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.12, paused: !playing)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<3, id: \.self) { i in
                    Capsule().fill(color)
                        .frame(width: 3, height: playing ? 4 + 10 * abs(sin(t * (3 + Double(i)) + Double(i))) : 4)
                }
            }
            .frame(width: 15, height: 14, alignment: .bottom)
            .animation(.easeInOut(duration: 0.12), value: t)
        }
    }
}

extension View {
    func cardShadow() -> some View { shadow(color: .black.opacity(0.35), radius: 18, y: 10) }
}

extension Date {
    var relative: String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: self, relativeTo: .now)
    }
}

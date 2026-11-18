import SwiftUI

/// Monochrome theme: black & white only. The "accent" is white on dark and black on light,
/// so everything adapts to the system appearance. Colour only ever comes from cover art.
enum Theme {
    static var accent: Color { Color(UIColor { $0.userInterfaceStyle == .dark ? .white : .black }) }
    static var onAccent: Color { Color(UIColor { $0.userInterfaceStyle == .dark ? .black : .white }) }
    static var violet: Color { accent }
    static var cyan: Color { accent }
    static var pink: Color { accent }
    static var mint: Color { accent }
    static var brand: Color { accent }
    static let ink = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.04, alpha: 1) : UIColor(white: 0.96, alpha: 1) })
    static let palettes: [[Color]] = [0x2A2A2E, 0x38383D, 0x46464C, 0x1F1F23, 0x54545B, 0x303035].map { [Color(hex: $0)] }
}

/// Plain grey Material surface; Liquid Glass elements sit on top of it.
struct AppBackground: View {
    var body: some View { Theme.ink.ignoresSafeArea() }
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
        case .online: return Theme.accent
        case .connecting: return .gray
        default: return Theme.accent.opacity(0.3)
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

/// Scroll direction of whichever tab is on screen, so the tab bar can expand again the moment you scroll up.
@MainActor final class TabChrome: ObservableObject {
    static let shared = TabChrome()
    @Published var scrollingUp = false
}

extension View {
    /// No-op: the tab bar uses the system `.onScrollDown` minimise behaviour again.
    func trackScrollDirection() -> some View { self }
}

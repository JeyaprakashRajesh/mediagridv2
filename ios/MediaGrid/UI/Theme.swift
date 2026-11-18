import SwiftUI

/// Monochrome theme: black & white only. The "accent" is white on dark and black on light,
/// so everything adapts to the system appearance. Colour only ever comes from cover art.
enum Theme {
    /// One primary for every page except Music: readable on both light and dark surfaces, white text on it passes contrast.
    static let accent = Color(hex: 0x6D5DFB)
    static let onAccent = Color.white
    static var violet: Color { accent }
    static var brand: Color { accent }
    static let cyan = Color(hex: 0x14A39A)
    static let pink = Color(hex: 0xF0568A)
    static let mint = Color(hex: 0x2FB67C)
    static let ink = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.05, alpha: 1) : UIColor(white: 0.96, alpha: 1) })
    /// Toned-down (no blue) gradient pairs for covers without art.
    static let palettes: [[Color]] = [(0x7345C9, 0xB5295F), (0xB5295F, 0xC8601A), (0x0E8077, 0x2F8F5B), (0xC8601A, 0xB5295F), (0x2F8F5B, 0x0E8077), (0x7345C9, 0x9A3F9A)]
        .map { [Color(hex: $0.0), Color(hex: $0.1)] }
    /// Stable colour for a name (playlists, albums, artists).
    static func pick(_ s: String) -> Color {
        let n = s.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return palettes[n % palettes.count][0]
    }
}

/// Colour of the song that's playing (vibrant, slightly darkened). Only the Music page and player use it;
/// it eases from one song's colour to the next.
@MainActor final class TintStore: ObservableObject {
    static let shared = TintStore()
    static let base = Color(hex: 0x6D5DFB)
    @Published var color = TintStore.base

    func update(for t: Track?) async {
        var target = Self.base
        if let t, let u = await ArtColors.shared.vibrant(for: t) {
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            u.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            target = Color(hue: h, saturation: min(max(s, 0.5), 0.85), brightness: min(max(b, 0.5), 0.76))
        }
        withAnimation(.easeInOut(duration: 1.0)) { color = target }
    }
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

/// Flat coloured square with a white symbol: the one icon style used on Shared, PC and Profile.
struct IconBadge: View {
    let symbol: String
    var color: Color = Theme.accent
    var size: CGFloat = 34
    var body: some View {
        Image(systemName: symbol).font(.system(size: size * 0.47, weight: .semibold)).foregroundStyle(.white)
            .frame(width: size, height: size).background(color, in: .rect(cornerRadius: size * 0.3))
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

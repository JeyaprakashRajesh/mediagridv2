import SwiftUI

/// Material-style theme: flat grey surfaces, one accent colour (Settings → Appearance),
/// Liquid Glass for controls. Legacy names (violet, cyan, pink, mint) now map to the accent / standard colours.
enum Theme {
    static let accents: [(id: String, name: String, color: Color)] = [
        ("gold", "Gold", Color(hex: 0xB5791A)), ("emerald", "Emerald", Color(hex: 0x1F9D6B)),
        ("ruby", "Ruby", Color(hex: 0xC2334D)), ("sapphire", "Sapphire", Color(hex: 0x2F6FDE)),
        ("teal", "Teal", Color(hex: 0x138A8A)), ("amber", "Amber", Color(hex: 0xD9791C)),
        ("slate", "Slate", Color(hex: 0x64748B)), ("bronze", "Bronze", Color(hex: 0x8A5A3C)),
    ]
    static var accent: Color {
        let id = UserDefaults.standard.string(forKey: "mg.accent") ?? "gold"
        return (accents.first { $0.id == id } ?? accents[0]).color
    }
    static var violet: Color { accent }
    static var cyan: Color { accent }
    static var pink: Color { Color(hex: 0xE5484D) }   // likes / destructive
    static let mint = Color(hex: 0x2FB67C)            // success / downloaded
    /// Flat surface that follows the system light / dark setting.
    static let ink = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.055, green: 0.059, blue: 0.071, alpha: 1)   // #0E0F12
                                                                   : UIColor(red: 0.965, green: 0.957, blue: 0.937, alpha: 1) })  // #F6F4EF
    static var brand: Color { accent }
    static let palettes: [[Color]] = accents.map { [$0.color] }
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

/// Scroll direction of whichever tab is on screen, so the tab bar can expand again the moment you scroll up.
@MainActor final class TabChrome: ObservableObject {
    static let shared = TabChrome()
    @Published var scrollingUp = false
}

extension View {
    /// No-op: the tab bar uses the system `.onScrollDown` minimise behaviour again.
    func trackScrollDirection() -> some View { self }
}

import SwiftUI

/// Material-style theme: flat grey surfaces, one accent colour (Settings → Appearance),
/// Liquid Glass for controls. Legacy names (violet, cyan, pink, mint) now map to the accent / standard colours.
enum Theme {
    static let accents: [(id: String, name: String, color: Color)] = [
        ("blue", "Blue", Color(hex: 0x1A73E8)), ("green", "Green", Color(hex: 0x1E8E3E)),
        ("red", "Red", Color(hex: 0xD93025)), ("amber", "Amber", Color(hex: 0xE37400)),
        ("teal", "Teal", Color(hex: 0x00897B)), ("sapphire", "Sapphire", Color(hex: 0x3F51B5)),
        ("gold", "Gold", Color(hex: 0xB8860B)), ("graphite", "Graphite", Color(hex: 0x5F6368)),
    ]
    static var accent: Color {
        let id = UserDefaults.standard.string(forKey: "mg.accent") ?? "blue"
        return (accents.first { $0.id == id } ?? accents[0]).color
    }
    static var violet: Color { accent }
    static var cyan: Color { accent }
    static var pink: Color { Color(hex: 0xD93025) }   // likes / destructive
    static let mint = Color(hex: 0x1E8E3E)            // success / downloaded
    /// Flat surface that follows the system light / dark setting.
    static let ink = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.105, green: 0.11, blue: 0.118, alpha: 1)
                                                                   : UIColor(red: 0.945, green: 0.953, blue: 0.957, alpha: 1) })
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
    func trackScrollDirection() -> some View {
        onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y }) { old, new in
            guard abs(new - old) > 3 else { return }
            MainActor.assumeIsolated {
                let up = new < old
                if TabChrome.shared.scrollingUp != up { TabChrome.shared.scrollingUp = up }
            }
        }
    }
}

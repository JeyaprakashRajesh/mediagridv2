import SwiftUI

enum AppTab: Hashable { case music, media, shared, pc, profile }

struct RootView: View {
    @EnvironmentObject var conn: Connection
    @EnvironmentObject var coord: Coordinator
    @EnvironmentObject var music: MusicStore
    @EnvironmentObject var media: MediaStore
    @EnvironmentObject var player: Player
    @ObservedObject private var ui = UIState.shared
    @ObservedObject private var tint = TintStore.shared

    var body: some View {
        ZStack {
            if conn.state == .signedOut {
                OnboardingView()
                    .transition(.asymmetric(insertion: .opacity, removal: .opacity.combined(with: .scale(scale: 1.05))))
            } else {
                tabs.transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.5), value: conn.state == .signedOut)
        .overlay(alignment: .top) {
            if let b = coord.banner {
                Label(b, systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 18).padding(.vertical, 12)
                    .glassEffect(.regular.tint(Theme.violet.opacity(0.3)), in: .capsule)
                    .padding(.top, 6)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.45), value: coord.banner)
        .alert("Your PC is looking for this iPhone", isPresented: $coord.findMe) {
            Button("Found it") { coord.stopRinging() }
        }
    }

    private var tabs: some View {
        // Icons only: every tab is recognisable from its symbol (names stay for VoiceOver).
        TabView(selection: $ui.tab) {
            Tab(value: AppTab.music) { MusicView() } label: { Image("TabMusic").accessibilityLabel("Music") }
            Tab(value: AppTab.media) { MediaView().tint(Theme.accent) } label: { Image("TabMedia").accessibilityLabel("Media") }
            Tab(value: AppTab.shared) { SharedView().tint(Theme.accent) } label: { Image("TabShared").accessibilityLabel("Shared") }
            Tab(value: AppTab.pc) { PCView().tint(Theme.accent) } label: { Image("TabPC").accessibilityLabel("PC") }
            Tab(value: AppTab.profile) { ProfileView().tint(Theme.accent) } label: { Image("TabProfile").accessibilityLabel("Profile") }
        }
        .tint(Color(UIColor { $0.userInterfaceStyle == .dark ? .white : .black }))   // active tab: white (black in light), others grey
        .environment(\.symbolVariants, .none)   // outline icons only, never filled
        .tabBarMinimizeBehavior(.onScrollDown)
        .tabViewBottomAccessory {
            MiniPlayer { ui.openPlayer() }.tint(tint.color)
        }
        // Full-screen page that pushes in like a navigation stack (not a drawer sheet).
        .overlay {
            if ui.showPlayer {
                NowPlayingView { ui.closePlayer() }
                    .tint(tint.color)
                    .transition(.move(edge: .trailing))
                    .zIndex(1)
            }
        }
        .task(id: player.current?.id ?? music.recentlyPlayed.first?.track.id) { await tint.update(for: player.current ?? music.recentlyPlayed.first?.track) }
        .task {
            await music.refresh()
            await media.refresh()
        }
    }
}

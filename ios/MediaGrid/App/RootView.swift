import SwiftUI

enum AppTab: Hashable { case music, media, shared, pc, profile }

struct RootView: View {
    @EnvironmentObject var conn: Connection
    @EnvironmentObject var coord: Coordinator
    @EnvironmentObject var music: MusicStore
    @EnvironmentObject var media: MediaStore
    @ObservedObject private var ui = UIState.shared

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
            Tab(value: AppTab.music) { MusicView() } label: { Image(systemName: "music.note.house").accessibilityLabel("Music") }
            Tab(value: AppTab.media) { MediaView() } label: { Image(systemName: "photo.stack").accessibilityLabel("Media") }
            Tab(value: AppTab.shared) { SharedView() } label: { Image(systemName: "doc.on.clipboard").accessibilityLabel("Shared") }
            Tab(value: AppTab.pc) { PCView() } label: { Image(systemName: "desktopcomputer").accessibilityLabel("PC") }
            Tab(value: AppTab.profile) { ProfileView() } label: { Image(systemName: "person.crop.circle").accessibilityLabel("Profile") }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .tabViewBottomAccessory {
            MiniPlayer { ui.openPlayer() }
        }
        // Full-screen page that pushes in like a navigation stack (not a drawer sheet).
        .overlay {
            if ui.showPlayer {
                NowPlayingView { ui.closePlayer() }
                    .transition(.move(edge: .trailing))
                    .zIndex(1)
            }
        }
        .task {
            await music.refresh()
            await media.refresh()
        }
    }
}

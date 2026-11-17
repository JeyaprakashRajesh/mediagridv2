import SwiftUI

enum AppTab: Hashable { case music, media, shared, pc, profile }

struct RootView: View {
    @EnvironmentObject var conn: Connection
    @EnvironmentObject var coord: Coordinator
    @EnvironmentObject var music: MusicStore
    @EnvironmentObject var media: MediaStore
    @State private var tab: AppTab = .music
    @State private var showPlayer = false

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
        TabView(selection: $tab) {
            Tab("Music", systemImage: "music.note", value: AppTab.music) { MusicView() }
            Tab("Media", systemImage: "photo.on.rectangle.angled", value: AppTab.media) { MediaView() }
            Tab("Shared", systemImage: "doc.on.clipboard", value: AppTab.shared) { SharedView() }
            Tab("PC", systemImage: "desktopcomputer", value: AppTab.pc) { PCView() }
            Tab("Profile", systemImage: "person.crop.circle", value: AppTab.profile) { ProfileView() }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .tabViewBottomAccessory {
            MiniPlayer { showPlayer = true }
        }
        .sheet(isPresented: $showPlayer) {
            NowPlayingView()
                .presentationDragIndicator(.visible)
                .presentationBackground(.clear)
        }
        .task {
            await music.refresh()
            await media.refresh()
        }
    }
}

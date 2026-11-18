import SwiftUI

/// Shared navigation state: lets the song page jump to a playlist and any list open the song page.
@MainActor
final class UIState: ObservableObject {
    static let shared = UIState()
    @Published var tab: AppTab = .music
    @Published var showPlayer = false
    @Published var musicPath: [SongCollection] = []

    func openPlayer() { withAnimation(.smooth(duration: 0.4)) { showPlayer = true } }
    func closePlayer() { withAnimation(.smooth(duration: 0.4)) { showPlayer = false } }
    func goTo(_ c: SongCollection) {
        closePlayer()
        tab = .music
        musicPath = [c]
    }
}

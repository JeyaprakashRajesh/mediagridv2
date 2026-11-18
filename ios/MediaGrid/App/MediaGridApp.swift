import SwiftUI
import AppIntents

@main
struct MediaGridApp: App {
    @Environment(\.scenePhase) private var phase
    @StateObject private var conn = Connection.shared
    @StateObject private var music = MusicStore.shared
    @StateObject private var player = Player.shared
    @StateObject private var media = MediaStore.shared
    @StateObject private var photos = PhotoSync.shared
    @StateObject private var clip = ClipboardSync.shared
    @StateObject private var coord = Coordinator.shared
    @StateObject private var shared = SharedStore.shared
    @AppStorage("mg.appearance") private var appearance = 0   // 0 system, 1 light, 2 dark
    @AppStorage("mg.accent") private var accent = "blue"

    init() {
        PhotoSync.registerBackground()
        Coordinator.shared.start()
        _ = Player.shared
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(conn)
                .environmentObject(music)
                .environmentObject(player)
                .environmentObject(media)
                .environmentObject(photos)
                .environmentObject(clip)
                .environmentObject(coord)
                .environmentObject(shared)
                .preferredColorScheme(appearance == 1 ? .light : appearance == 2 ? .dark : nil)
                .tint(Theme.accent)
        }
        .onChange(of: phase) { _, p in
            switch p {
            case .active:
                conn.startDiscovery()
                conn.resume()
                photos.startObserving()
                Task {
                    try? await Task.sleep(for: .milliseconds(600))
                    clip.checkPhoneClipboard()
                    if photos.auto { await photos.syncNow() }
                }
            case .background:
                PhotoSync.scheduleBackground()
            default: break
            }
        }
    }
}

/// "Hey Siri, shuffle my music in MediaGrid"
struct ShuffleMusicIntent: AppIntent {
    static var title: LocalizedStringResource = "Shuffle my music"
    static var openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult {
        Player.shared.shuffleAll()
        return .result()
    }
}

struct SyncPhotosIntent: AppIntent {
    static var title: LocalizedStringResource = "Back up photos to PC"
    static var openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult {
        await PhotoSync.shared.syncNow()
        return .result()
    }
}

struct MediaGridShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ShuffleMusicIntent(), phrases: ["Shuffle my music in \(.applicationName)", "Play my music in \(.applicationName)"],
                    shortTitle: "Shuffle Music", systemImageName: "shuffle")
        AppShortcut(intent: SyncPhotosIntent(), phrases: ["Back up photos with \(.applicationName)"],
                    shortTitle: "Back Up Photos", systemImageName: "photo.badge.arrow.down")
    }
}

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
    @AppStorage("mg.accent") private var accent = "gold"

    init() {
        PhotoSync.registerBackground()
        Coordinator.shared.start()
        CallMonitor.shared.start()
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
                clip.startWatching()
                conn.resume()
                photos.startObserving()
                Task {
                    try? await Task.sleep(for: .milliseconds(600))
                    clip.checkPhoneClipboard()
                    if photos.auto { await photos.syncNow() }
                }
            case .background:
                clip.stopWatching()
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

struct TogglePlaybackIntent: AppIntent {
    static var title: LocalizedStringResource = "Play or pause"
    static var openAppWhenRun = false
    @MainActor func perform() async throws -> some IntentResult { Player.shared.toggle(); return .result() }
}

struct NextSongIntent: AppIntent {
    static var title: LocalizedStringResource = "Next song"
    static var openAppWhenRun = false
    @MainActor func perform() async throws -> some IntentResult { Player.shared.next(); return .result() }
}

struct PreviousSongIntent: AppIntent {
    static var title: LocalizedStringResource = "Previous song"
    static var openAppWhenRun = false
    @MainActor func perform() async throws -> some IntentResult { Player.shared.previous(); return .result() }
}

struct PlaySongIntent: AppIntent {
    static var title: LocalizedStringResource = "Play a song"
    static var openAppWhenRun = false
    @Parameter(title: "Song", requestValueDialog: "Which song?") var song: String
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let q = song.lowercased()
        let hits = MusicStore.shared.tracks.filter { "\($0.title) \($0.artist) \($0.album)".lowercased().contains(q) }
        guard let first = hits.first else { return .result(dialog: "I couldn't find that song in your library.") }
        Player.shared.play(hits, start: first, shuffle: false, source: "Siri")
        return .result(dialog: "Playing \(first.title).")
    }
}

struct PlayPlaylistIntent: AppIntent {
    static var title: LocalizedStringResource = "Play a playlist"
    static var openAppWhenRun = false
    @Parameter(title: "Playlist", requestValueDialog: "Which playlist?") var name: String
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let q = name.lowercased()
        guard let p = MusicStore.shared.playlists.first(where: { $0.name.lowercased().contains(q) }) else {
            return .result(dialog: "I couldn't find that playlist.")
        }
        let ts = MusicStore.shared.tracks(for: p)
        guard !ts.isEmpty else { return .result(dialog: "That playlist is empty.") }
        Player.shared.play(ts, shuffle: false, source: p.name, collectionID: "pl-\(p.id)")
        return .result(dialog: "Playing \(p.name).")
    }
}

struct LikeSongIntent: AppIntent {
    static var title: LocalizedStringResource = "Like this song"
    static var openAppWhenRun = false
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let t = Player.shared.current else { return .result(dialog: "Nothing is playing.") }
        if !MusicStore.shared.liked.contains(t.id) { MusicStore.shared.toggleLike(t) }
        return .result(dialog: "Liked \(t.title).")
    }
}

struct SyncMusicIntent: AppIntent {
    static var title: LocalizedStringResource = "Download my music"
    static var openAppWhenRun = false
    @MainActor func perform() async throws -> some IntentResult { MusicStore.shared.syncAll(); return .result() }
}

struct LockPCIntent: AppIntent {
    static var title: LocalizedStringResource = "Lock my PC"
    static var openAppWhenRun = false
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        do { try await Connection.shared.post("/api/control", json: ["type": "power", "action": "lock"]); return .result(dialog: "Locking your PC.") }
        catch { return .result(dialog: "I couldn't reach your PC.") }
    }
}

struct MediaGridShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ShuffleMusicIntent(), phrases: ["Shuffle my music in \(.applicationName)", "Play my music in \(.applicationName)"],
                    shortTitle: "Shuffle Music", systemImageName: "shuffle")
        AppShortcut(intent: TogglePlaybackIntent(), phrases: ["Pause \(.applicationName)", "Resume \(.applicationName)", "Play or pause in \(.applicationName)"],
                    shortTitle: "Play / Pause", systemImageName: "playpause.fill")
        AppShortcut(intent: NextSongIntent(), phrases: ["Next song in \(.applicationName)", "Skip song in \(.applicationName)"],
                    shortTitle: "Next Song", systemImageName: "forward.fill")
        AppShortcut(intent: PreviousSongIntent(), phrases: ["Previous song in \(.applicationName)"],
                    shortTitle: "Previous Song", systemImageName: "backward.fill")
        AppShortcut(intent: PlaySongIntent(), phrases: ["Play a song in \(.applicationName)", "Play a song with \(.applicationName)"],
                    shortTitle: "Play a Song", systemImageName: "music.note")
        AppShortcut(intent: PlayPlaylistIntent(), phrases: ["Play a playlist in \(.applicationName)"],
                    shortTitle: "Play a Playlist", systemImageName: "music.note.list")
        AppShortcut(intent: LikeSongIntent(), phrases: ["Like this song in \(.applicationName)"],
                    shortTitle: "Like Song", systemImageName: "heart.fill")
        AppShortcut(intent: SyncMusicIntent(), phrases: ["Download my music in \(.applicationName)"],
                    shortTitle: "Download Music", systemImageName: "arrow.down.circle")
        AppShortcut(intent: SyncPhotosIntent(), phrases: ["Back up photos with \(.applicationName)"],
                    shortTitle: "Back Up Photos", systemImageName: "photo.badge.arrow.down")
        AppShortcut(intent: LockPCIntent(), phrases: ["Lock my PC with \(.applicationName)"],
                    shortTitle: "Lock PC", systemImageName: "lock.fill")
    }
}

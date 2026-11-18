import Foundation
import SwiftUI

/// Auto-generated, Spotify-style playlist.
struct SmartMix: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let symbol: String
    let colors: [Color]
    let tracks: [Track]
    static func == (a: SmartMix, b: SmartMix) -> Bool { a.id == b.id && a.tracks.count == b.tracks.count }
    func hash(into h: inout Hasher) { h.combine(id) }
}

/// Deterministic RNG so "Daily Mix" stays the same all day.
struct SeededRandom: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

struct TrackGroup: Identifiable {
    var id: String { name }
    let name: String
    let artist: String
    let tracks: [Track]
}

@MainActor
final class MusicStore: ObservableObject {
    static let shared = MusicStore()

    @Published var tracks: [Track] = []
    @Published var downloaded: Set<String> = []
    @Published var liked: Set<String> = []
    @Published var playCounts: [String: Int] = [:]
    @Published var lastPlayed: [String: Double] = [:]
    @Published var serverRecent: [RecentEntry] = []
    @Published var playlists: [UserPlaylist] = []
    @Published var loading = false
    @Published var syncing = false
    @Published var syncDone = 0
    @Published var syncTotal = 0
    @Published var lastError: String?

    let musicDir: URL
    private let stateURL: URL
    private let cacheURL: URL
    private var syncTask: Task<Void, Never>?

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        musicDir = docs.appendingPathComponent("Music", isDirectory: true)
        try? FileManager.default.createDirectory(at: musicDir, withIntermediateDirectories: true)
        var noBackup = URLResourceValues(); noBackup.isExcludedFromBackup = true
        var md = musicDir; try? md.setResourceValues(noBackup)
        stateURL = docs.appendingPathComponent("music-state.json")
        cacheURL = docs.appendingPathComponent("tracks.json")
        loadLocal()
    }

    // MARK: persistence

    private struct State: Codable {
        var liked: [String] = []
        var playCounts: [String: Int] = [:]
        var lastPlayed: [String: Double] = [:]
        var playlists: [UserPlaylist] = []
    }

    private func loadLocal() {
        if let d = try? Data(contentsOf: cacheURL), let t = try? JSONDecoder().decode([Track].self, from: d) { tracks = t }
        if let d = try? Data(contentsOf: stateURL), let s = try? JSONDecoder().decode(State.self, from: d) {
            liked = Set(s.liked); playCounts = s.playCounts; lastPlayed = s.lastPlayed; playlists = s.playlists
        }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: musicDir.path)) ?? []
        downloaded = Set(files.filter { !$0.hasSuffix(".part") }.map { ($0 as NSString).deletingPathExtension })
    }

    func saveState() {
        let s = State(liked: Array(liked), playCounts: playCounts, lastPlayed: lastPlayed, playlists: playlists)
        if let d = try? JSONEncoder().encode(s) { try? d.write(to: stateURL, options: .atomic) }
    }

    // MARK: server

    func refresh() async {
        guard Connection.shared.isSignedIn else { return }
        loading = true
        defer { loading = false }
        do {
            let t: [Track] = try await Connection.shared.get("/api/music/tracks")
            tracks = t
            if let d = try? JSONEncoder().encode(t) { try? d.write(to: cacheURL, options: .atomic) }
            lastError = nil
            await refreshPlayback()
            await refreshPlaylists()
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: files

    func localURL(_ t: Track) -> URL { musicDir.appendingPathComponent("\(t.id).\(t.ext)") }
    func isDownloaded(_ t: Track) -> Bool { downloaded.contains(t.id) }

    func playURL(_ t: Track) -> URL {
        isDownloaded(t) ? localURL(t) : Connection.shared.url("/api/music/stream/\(t.id)")
    }

    func artURL(_ t: Track) -> URL? {
        t.has_art ? Connection.shared.url("/api/music/art/\(t.id)") : nil
    }

    var downloadedBytes: Int64 {
        tracks.filter { downloaded.contains($0.id) }.reduce(0) { $0 + $1.size }
    }

    func download(_ t: Track) async throws {
        if isDownloaded(t) { return }
        let (tmp, resp) = try await Connection.shared.session.download(from: Connection.shared.url("/api/music/stream/\(t.id)"))
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw APIError.bad }
        let dest = localURL(t)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        downloaded.insert(t.id)
        if t.has_art, let u = artURL(t) { _ = await ImageCache.shared.image(u) }
    }

    func remove(_ t: Track) {
        try? FileManager.default.removeItem(at: localURL(t))
        downloaded.remove(t.id)
    }

    func removeAllDownloads() {
        for t in tracks { try? FileManager.default.removeItem(at: localURL(t)) }
        downloaded.removeAll()
    }

    /// Download every track that isn't on the phone yet.
    func syncAll(_ list: [Track]? = nil) {
        guard !syncing else { return }
        let todo = (list ?? tracks).filter { !isDownloaded($0) }
        guard !todo.isEmpty else { return }
        syncing = true; syncDone = 0; syncTotal = todo.count
        let bg = UIApplication.shared.beginBackgroundTask(withName: "music-sync")
        LiveActivityManager.shared.sync(done: 0, total: todo.count, label: "Syncing music")
        syncTask = Task {
            await withTaskGroup(of: Void.self) { g in
                var it = todo.makeIterator()
                for _ in 0..<3 { if let t = it.next() { g.addTask { await self.dl(t) } } }
                while await g.next() != nil {
                    if Task.isCancelled { break }
                    if let t = it.next() { g.addTask { await self.dl(t) } }
                }
            }
            syncing = false
            LiveActivityManager.shared.syncFinished()
            UIApplication.shared.endBackgroundTask(bg)
        }
    }

    private func dl(_ t: Track) async {
        try? await download(t)
        syncDone += 1
        LiveActivityManager.shared.sync(done: syncDone, total: syncTotal, label: "Syncing music")
    }

    func cancelSync() { syncTask?.cancel(); syncing = false; LiveActivityManager.shared.syncFinished() }

    // MARK: likes, stats, playlists

    func toggleLike(_ t: Track) {
        if liked.contains(t.id) { liked.remove(t.id) } else { liked.insert(t.id) }
        saveState()
    }

    /// Called when a song starts: feeds "Recently played" without bumping play counts.
    func noteStarted(_ t: Track) {
        lastPlayed[t.id] = Date().timeIntervalSince1970
        saveState()
    }

    /// Recently played on any of your devices (merged with the PC's copy), newest first, with the position to resume from.
    var recentlyPlayed: [(track: Track, at: Date, pos: Double)] {
        let map = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var m: [String: (at: Double, pos: Double)] = lastPlayed.mapValues { ($0, 0) }
        if let rid = UserDefaults.standard.string(forKey: "mg.resumeID"), m[rid] != nil { m[rid]?.pos = UserDefaults.standard.double(forKey: "mg.resumeTime") }
        for e in serverRecent where e.at / 1000 >= (m[e.id]?.at ?? 0) { m[e.id] = (e.at / 1000, e.pos) }
        return m.sorted { $0.value.at > $1.value.at }.prefix(8)
            .compactMap { id, v in map[id].map { ($0, Date(timeIntervalSince1970: v.at), v.pos) } }
    }

    struct RecentEntry { var id: String; var at: Double; var pos: Double; var device: String }

    /// Take the PC's playback state (from GET /api/playback or the `playback` WebSocket event).
    func applyPlayback(_ any: Any?) {
        guard let o = any as? [String: Any], let arr = o["recent"] as? [[String: Any]] else { return }
        serverRecent = arr.compactMap { r in
            guard let id = r["id"] as? String else { return nil }
            return RecentEntry(id: id, at: (r["at"] as? Double) ?? 0, pos: (r["pos"] as? Double) ?? 0, device: (r["device"] as? String) ?? "")
        }
        // Another device started playing: stop here so only one device plays.
        if let n = o["now"] as? [String: Any], (n["playing"] as? Bool) == true, (n["device"] as? String) != UIDevice.current.name,
           Date().timeIntervalSince1970 * 1000 - ((n["at"] as? Double) ?? 0) < 20000, Player.shared.isPlaying {
            Player.shared.pause()
        }
    }

    /// Playlists live on the PC so the phone and the PC always show the same ones.
    func applyPlaylists(_ any: Any?) {
        guard let any, JSONSerialization.isValidJSONObject(any), let d = try? JSONSerialization.data(withJSONObject: any),
              let list = try? JSONDecoder().decode([UserPlaylist].self, from: d) else { return }
        playlists = list
        saveState()
    }

    func pushPlaylists() {
        guard Connection.shared.isSignedIn, let d = try? JSONEncoder().encode(playlists),
              let json = try? JSONSerialization.jsonObject(with: d) else { return }
        Task { try? await Connection.shared.post("/api/playlists", json: json) }
    }

    func refreshPlaylists() async {
        guard let d = try? await Connection.shared.request("/api/playlists"),
              let json = try? JSONSerialization.jsonObject(with: d) as? [Any] else { return }
        let key = "mg.playlistsSynced"
        if !UserDefaults.standard.bool(forKey: key) {
            UserDefaults.standard.set(true, forKey: key)
            if json.isEmpty && !playlists.isEmpty { pushPlaylists(); return }   // first sync: upload what this phone already has
        }
        applyPlaylists(json)
    }

    func refreshPlayback() async {
        guard let d = try? await Connection.shared.request("/api/playback") else { return }
        applyPlayback(try? JSONSerialization.jsonObject(with: d))
    }

    func notePlayed(_ t: Track) {
        playCounts[t.id, default: 0] += 1
        lastPlayed[t.id] = Date().timeIntervalSince1970
        saveState()
    }

    func createPlaylist(_ name: String, tracks ids: [String] = []) {
        playlists.insert(UserPlaylist(name: name, trackIDs: ids), at: 0)
        saveState(); pushPlaylists()
    }

    func add(_ t: Track, to p: UserPlaylist) {
        guard let i = playlists.firstIndex(where: { $0.id == p.id }), !playlists[i].trackIDs.contains(t.id) else { return }
        playlists[i].trackIDs.append(t.id)
        saveState(); pushPlaylists()
    }

    func removeFromPlaylist(_ t: Track, _ p: UserPlaylist) {
        guard let i = playlists.firstIndex(where: { $0.id == p.id }) else { return }
        playlists[i].trackIDs.removeAll { $0 == t.id }
        saveState(); pushPlaylists()
    }

    func deletePlaylist(_ p: UserPlaylist) {
        playlists.removeAll { $0.id == p.id }
        saveState(); pushPlaylists()
    }

    func tracks(for p: UserPlaylist) -> [Track] {
        let map = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return p.trackIDs.compactMap { map[$0] }
    }

    var albums: [TrackGroup] {
        Dictionary(grouping: tracks, by: { $0.album })
            .map { TrackGroup(name: $0.key, artist: $0.value.first?.artist ?? "", tracks: $0.value.sorted { ($0.track, $0.title) < ($1.track, $1.title) }) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var artists: [TrackGroup] {
        Dictionary(grouping: tracks, by: { $0.artist })
            .map { TrackGroup(name: $0.key, artist: $0.key, tracks: $0.value) }
            .sorted { $0.tracks.count > $1.tracks.count }
    }

    // MARK: smart mixes

    var mixes: [SmartMix] {
        guard !tracks.isEmpty else { return [] }
        let day = UInt64(Date().timeIntervalSince1970 / 86400)
        var rng = SeededRandom(seed: day)
        var out: [SmartMix] = []

        let likedT = tracks.filter { liked.contains($0.id) }
        if !likedT.isEmpty {
            out.append(SmartMix(id: "liked", title: "Liked Songs", subtitle: "\(likedT.count) songs", symbol: "heart.fill",
                                colors: [Color(hex: 0xC72E66)], tracks: likedT))
        }
        let recent = tracks.sorted { $0.added > $1.added }.prefix(60)
        out.append(SmartMix(id: "recent", title: "Recently Added", subtitle: "Fresh in your library", symbol: "sparkles",
                            colors: [Color(hex: 0xC8601A)], tracks: Array(recent)))

        let played = tracks.filter { (playCounts[$0.id] ?? 0) > 0 }.sorted { (playCounts[$0.id] ?? 0) > (playCounts[$1.id] ?? 0) }
        if played.count >= 5 {
            out.append(SmartMix(id: "repeat", title: "On Repeat", subtitle: "Songs you can't stop playing", symbol: "repeat",
                                colors: [Color(hex: 0x0E8077)], tracks: Array(played.prefix(50))))
        }

        // Daily mixes: built around your most played (or biggest) artists
        let artistScore = Dictionary(grouping: tracks, by: { $0.artist }).mapValues { ts in
            ts.reduce(0) { $0 + (playCounts[$1.id] ?? 0) * 3 + (liked.contains($1.id) ? 5 : 0) } + ts.count
        }
        let topArtists = artistScore.sorted { $0.value > $1.value }.map(\.key).filter { $0 != "Unknown Artist" }
        let palettes: [[Color]] = [[Color(hex: 0x7345C9)], [Color(hex: 0x2F8F5B)], [Color(hex: 0xB4541E)], [Color(hex: 0x9A3F9A)]]
        var used = Set<String>()
        var mixNo = 1
        for (i, a) in topArtists.enumerated() where mixNo <= 4 && !used.contains(a) {
            let seeds = [a] + topArtists.dropFirst(i + 1).filter { !used.contains($0) }.prefix(2)
            seeds.forEach { used.insert($0) }
            var picks = tracks.filter { seeds.contains($0.artist) }
            let fill = tracks.filter { !seeds.contains($0.artist) }.shuffled(using: &rng).prefix(max(0, 30 - picks.count) / 2)
            picks.append(contentsOf: fill)
            guard picks.count >= 6 else { continue }
            out.append(SmartMix(id: "daily\(mixNo)", title: "Daily Mix \(mixNo)", subtitle: seeds.joined(separator: ", "),
                                symbol: "dial.medium", colors: palettes[(mixNo - 1) % palettes.count], tracks: picks.shuffled(using: &rng)))
            mixNo += 1
        }

        let rediscover = tracks.filter { (playCounts[$0.id] ?? 0) == 0 }.shuffled(using: &rng).prefix(40)
        if rediscover.count >= 5 {
            out.append(SmartMix(id: "discover", title: "Discover Weekly", subtitle: "Songs you haven't played yet", symbol: "safari",
                                colors: [Color(hex: 0x5D7F2E)], tracks: Array(rediscover)))
        }
        let offline = tracks.filter { downloaded.contains($0.id) }
        if !offline.isEmpty {
            out.append(SmartMix(id: "offline", title: "Downloaded", subtitle: "Plays without your PC", symbol: "arrow.down.circle.fill",
                                colors: [Color(hex: 0x2F8F5B)], tracks: offline))
        }
        let long = tracks.filter { $0.duration > 270 }.shuffled(using: &rng).prefix(50)
        if long.count >= 5 {
            out.append(SmartMix(id: "drive", title: "Long Drive", subtitle: "Settle in", symbol: "car.fill",
                                colors: [Color(hex: 0x9A5A17)], tracks: Array(long)))
        }
        let quick = tracks.filter { $0.duration > 0 && $0.duration < 200 }.shuffled(using: &rng).prefix(50)
        if quick.count >= 5 {
            out.append(SmartMix(id: "quick", title: "Quick Hits", subtitle: "Short & sweet", symbol: "bolt.fill",
                                colors: [Color(hex: 0xB02A4E)], tracks: Array(quick)))
        }
        return out
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, opacity: alpha)
    }
}

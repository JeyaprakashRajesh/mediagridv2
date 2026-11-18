import Foundation
import AVFoundation
import MediaPlayer
import UIKit

enum RepeatMode: Int { case off, all, one }

@MainActor
final class Player: ObservableObject {
    static let shared = Player()

    @Published private(set) var current: Track?
    @Published private(set) var isPlaying = false
    @Published private(set) var queue: [Track] = []
    @Published private(set) var order: [Int] = []
    @Published private(set) var pos = 0
    @Published var shuffle: Bool = UserDefaults.standard.object(forKey: "mg.shuffle") as? Bool ?? true {
        didSet { UserDefaults.standard.set(shuffle, forKey: "mg.shuffle"); reshuffleKeepingCurrent() }
    }
    @Published var repeatMode: RepeatMode = .off
    @Published var time: Double = 0
    @Published var duration: Double = 0
    @Published var source: String = ""
    @Published var collectionID: String?
    @Published var buffering = false

    private let player = AVPlayer()
    private var timeObs: Any?
    private var counted = false
    private var artwork: MPMediaItemArtwork?
    private var recentArtists: [String] = []

    var upNext: [Track] {
        guard pos + 1 < order.count else { return [] }
        return order[(pos + 1)...].prefix(50).map { queue[$0] }
    }

    init() {
        player.automaticallyWaitsToMinimizeStalling = true
        timeObs = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] t in
            MainActor.assumeIsolated { self?.tick(t.seconds) }
        }
        NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated {
                guard let self, (n.object as? AVPlayerItem) === self.player.currentItem else { return }
                self.finished()
            }
        }
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated {
                guard let self, let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
                if type == .began { self.isPlaying = false; self.publish() }
                else if let o = n.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt,
                        AVAudioSession.InterruptionOptions(rawValue: o).contains(.shouldResume) { self.resume() }
            }
        }
        setupRemote()
        IntentBridge.handler = { action in
            await MainActor.run {
                switch action {
                case "toggle": Player.shared.toggle()
                case "next": Player.shared.next()
                case "prev": Player.shared.previous()
                default: break
                }
            }
        }
    }

    private func activateSession() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .default, policy: .longFormAudio)
        try? s.setActive(true)
    }

    // MARK: queue

    /// Play a list. `start` nil + shuffle = random first song.
    func play(_ list: [Track], start: Track? = nil, shuffle forceShuffle: Bool? = nil, source: String = "", collectionID: String? = nil) {
        guard !list.isEmpty else { return }
        self.collectionID = collectionID
        if let s = forceShuffle, s != shuffle { shuffle = s }
        queue = list
        self.source = source
        let first = start.flatMap { s in list.firstIndex(of: s) } ?? (shuffle ? weightedRandomIndex() : 0)
        order = buildOrder(first: first)
        pos = 0
        load()
    }

    /// Continue a song from "Recently played" at the position where it was left.
    func playRecent(_ t: Track, in list: [Track], pos: Double = 0) {
        let d = UserDefaults.standard
        let same = d.string(forKey: "mg.resumeID") == t.id
        play(list, start: t, source: same ? (d.string(forKey: "mg.lastSource") ?? "Recently played") : "Recently played",
             collectionID: same ? d.string(forKey: "mg.lastCollection") : nil)
        if pos > 3 { seek(pos) }
    }

    private var lastPost = Date.distantPast
    /// Tell the PC what is playing so any device can pick it up.
    private func postPlayback(force: Bool = true) {
        guard let t = current, Connection.shared.isSignedIn else { return }
        guard force || Date().timeIntervalSince(lastPost) > 10 else { return }
        lastPost = Date()
        let body: [String: Any] = ["id": t.id, "pos": time, "playing": isPlaying, "device": UIDevice.current.name]
        Task { try? await Connection.shared.post("/api/playback", json: body) }
    }

    private func saveResume() {
        guard let t = current else { return }
        UserDefaults.standard.set(t.id, forKey: "mg.resumeID")
        UserDefaults.standard.set(time, forKey: "mg.resumeTime")
        UserDefaults.standard.set(source, forKey: "mg.lastSource")
        UserDefaults.standard.set(collectionID, forKey: "mg.lastCollection")
    }

    func shuffleAll() {
        play(MusicStore.shared.tracks, shuffle: true, source: "All Songs")
    }

    func playNext(_ t: Track) {
        guard current != nil else { play([t]); return }
        queue.append(t)
        order.insert(queue.count - 1, at: pos + 1)
    }

    func addToQueue(_ t: Track) {
        guard current != nil else { play([t]); return }
        queue.append(t)
        order.append(queue.count - 1)
    }

    func jump(to upNextIndex: Int) {
        pos = min(order.count - 1, pos + 1 + upNextIndex)
        load()
    }

    /// Prefer liked / less recently played songs for the very first pick.
    private func weightedRandomIndex() -> Int {
        let store = MusicStore.shared
        let now = Date().timeIntervalSince1970
        let weights: [Double] = queue.map { t in
            var w = 1.0
            if store.liked.contains(t.id) { w += 1.5 }
            if let lp = store.lastPlayed[t.id] { w *= min(1, max(0.15, (now - lp) / 86400 / 3)) }
            return w
        }
        let total = weights.reduce(0, +)
        var r = Double.random(in: 0..<max(total, 0.0001))
        for (i, w) in weights.enumerated() { r -= w; if r <= 0 { return i } }
        return Int.random(in: 0..<queue.count)
    }

    /// Smart shuffle: random order, never repeats until everything has played,
    /// keeps the same artist from playing back-to-back.
    private func buildOrder(first: Int) -> [Int] {
        var rest = Array(queue.indices)
        guard !rest.isEmpty else { return [] }
        rest.remove(at: rest.firstIndex(of: first) ?? 0)
        guard shuffle else {
            return [first] + rest.filter { $0 > first } + rest.filter { $0 < first }
        }
        rest.shuffle()
        var out = [first]
        while !rest.isEmpty {
            let lastArtist = queue[out.last!].artist
            let i = rest.firstIndex { queue[$0].artist != lastArtist } ?? 0
            out.append(rest.remove(at: i))
        }
        return out
    }

    private func reshuffleKeepingCurrent() {
        guard !order.isEmpty, pos < order.count else { return }
        let cur = order[pos]
        let played = Array(order[..<pos])
        var rest = Array(queue.indices).filter { $0 != cur && !played.contains($0) }
        if shuffle { rest.shuffle() } else { rest.sort() }
        order = played + [cur] + rest
    }

    // MARK: playback

    private func load() {
        guard pos < order.count else { return }
        let t = queue[order[pos]]
        activateSession()
        current = t
        counted = false
        time = 0
        duration = t.duration
        artwork = nil
        let item = AVPlayerItem(url: MusicStore.shared.playURL(t))
        item.preferredForwardBufferDuration = 30
        player.replaceCurrentItem(with: item)
        player.play()
        isPlaying = true
        MusicStore.shared.noteStarted(t)
        saveResume()
        publish()
        postPlayback()
        loadArtwork(t)
        prefetchNext()
        Task { await Connection.shared.sendStatus() }
    }

    private func prefetchNext() {
        // warm the art cache for the next song so the lock screen updates instantly
        if let n = upNext.first, let u = MusicStore.shared.artURL(n) { Task { _ = await ImageCache.shared.image(u) } }
    }

    func toggle() {
        if current == nil {
            if !MusicStore.shared.tracks.isEmpty { shuffleAll() }
            return
        }
        isPlaying ? pause() : resume()
    }

    func pause() {
        saveResume()
        player.pause()
        isPlaying = false
        publish()
        postPlayback()
        Task { await Connection.shared.sendStatus() }
    }

    func resume() {
        activateSession()
        player.play()
        isPlaying = true
        publish()
        postPlayback()
        Task { await Connection.shared.sendStatus() }
    }

    func next() {
        guard !order.isEmpty else { return }
        if pos + 1 < order.count {
            pos += 1
        } else {
            // whole queue heard: build a fresh shuffle and keep going
            order = buildOrder(first: shuffle ? weightedRandomIndex() : 0)
            pos = 0
        }
        load()
    }

    func previous() {
        if time > 3 || pos == 0 { seek(0); return }
        pos -= 1
        load()
    }

    func seek(_ s: Double) {
        player.seek(to: CMTime(seconds: s, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        time = s
        publish()
        postPlayback()
    }

    private func finished() {
        if repeatMode == .one { seek(0); player.play(); return }
        if pos + 1 >= order.count && repeatMode == .off && !shuffle {
            isPlaying = false; publish(); return
        }
        next()
    }

    private func tick(_ s: Double) {
        guard s.isFinite else { return }
        time = s
        if Int(s) % 5 == 0 { saveResume() }
        if isPlaying { postPlayback(force: false) }
        if let d = player.currentItem?.duration.seconds, d.isFinite, d > 0 { duration = d }
        buffering = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
        if !counted, let t = current, s > min(30, duration * 0.5) {
            counted = true
            MusicStore.shared.notePlayed(t)
        }
    }

    // MARK: lock screen, Control Center, Dynamic Island

    private func loadArtwork(_ t: Track) {
        guard let u = MusicStore.shared.artURL(t) else { return }
        Task {
            guard let img = await ImageCache.shared.image(u), current?.id == t.id else { return }
            artwork = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
            publish()
        }
    }

    private func publish() {
        guard let t = current else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: t.title,
            MPMediaItemPropertyArtist: t.artist,
            MPMediaItemPropertyAlbumTitle: t.album,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: time,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
    }

    private func setupRemote() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { _ in MainActor.assumeIsolated { Player.shared.resume() }; return .success }
        c.pauseCommand.addTarget { _ in MainActor.assumeIsolated { Player.shared.pause() }; return .success }
        c.togglePlayPauseCommand.addTarget { _ in MainActor.assumeIsolated { Player.shared.toggle() }; return .success }
        c.nextTrackCommand.addTarget { _ in MainActor.assumeIsolated { Player.shared.next() }; return .success }
        c.previousTrackCommand.addTarget { _ in MainActor.assumeIsolated { Player.shared.previous() }; return .success }
        c.changePlaybackPositionCommand.addTarget { e in
            if let e = e as? MPChangePlaybackPositionCommandEvent { let p = e.positionTime; MainActor.assumeIsolated { Player.shared.seek(p) } }
            return .success
        }
        c.likeCommand.isEnabled = true
        c.likeCommand.localizedTitle = "Like"
        c.likeCommand.addTarget { _ in
            MainActor.assumeIsolated { if let t = Player.shared.current { MusicStore.shared.toggleLike(t) } }
            return .success
        }
    }
}

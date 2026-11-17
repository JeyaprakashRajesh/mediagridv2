import Foundation
import Photos
import UIKit
import ActivityKit
import AudioToolbox
import BackgroundTasks
import Combine

// MARK: - Live Activity / Dynamic Island

@MainActor
final class LiveActivityManager {
    static let shared = LiveActivityManager()
    private var activity: Activity<MediaGridActivity>?
    private var state = MediaGridActivity.ContentState()
    private var lastPush = Date.distantPast
    private var lastKey = ""

    private var enabled: Bool {
        UserDefaults.standard.object(forKey: "mg.liveActivity") as? Bool ?? true
            && ActivityAuthorizationInfo().areActivitiesEnabled
    }

    func nowPlaying(_ t: Track, playing: Bool, time: Double, duration: Double) {
        state.mode = state.syncTotal > 0 ? state.mode : "music"
        state.title = t.title
        state.subtitle = t.artist
        state.playing = playing
        state.start = Date().addingTimeInterval(-time)
        state.end = state.start.addingTimeInterval(max(duration, 1))
        state.progress = duration > 0 ? time / duration : 0
        let key = "\(t.id)-\(playing)"
        // only push on meaningful changes (track / play state / seek), max 1 per second
        guard key != lastKey || Date().timeIntervalSince(lastPush) > 15 else { return }
        lastKey = key
        push()
    }

    func sync(done: Int, total: Int, label: String) {
        state.syncDone = done
        state.syncTotal = total
        state.syncLabel = label
        if Player.shared.current == nil { state.mode = "sync"; state.title = label }
        guard Date().timeIntervalSince(lastPush) > 1 || done == total || done == 0 else { return }
        push()
    }

    func syncFinished() {
        state.syncDone = 0
        state.syncTotal = 0
        if Player.shared.current == nil {
            end()
        } else {
            state.mode = "music"
            push()
        }
    }

    private func push() {
        lastPush = Date()
        guard enabled else { return }
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(3600))
        if let a = activity, a.activityState == .active {
            Task { await a.update(content) }
        } else {
            activity = try? Activity.request(attributes: MediaGridActivity(pcName: Connection.shared.pcName), content: content, pushType: nil)
        }
    }

    func end() {
        let a = activity
        activity = nil
        Task { await a?.end(nil, dismissalPolicy: .immediate) }
    }
}

// MARK: - iPhone → PC photo backup

@MainActor
final class PhotoSync: NSObject, ObservableObject, PHPhotoLibraryChangeObserver {
    static let shared = PhotoSync()
    nonisolated static let bgID = "com.jeyaprakash.mediagrid.photosync"

    @Published var running = false
    @Published var done = 0
    @Published var total = 0
    @Published var status = ""
    @Published var lastSync: Date? = UserDefaults.standard.object(forKey: "mg.lastPhotoSync") as? Date
    @Published var auto: Bool = UserDefaults.standard.object(forKey: "mg.autoPhotos") as? Bool ?? true {
        didSet { UserDefaults.standard.set(auto, forKey: "mg.autoPhotos") }
    }
    @Published var includeVideos: Bool = UserDefaults.standard.object(forKey: "mg.photoVideos") as? Bool ?? true {
        didSet { UserDefaults.standard.set(includeVideos, forKey: "mg.photoVideos") }
    }
    @Published var authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    private var uploaded: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "mg.uploaded") ?? [])
    private var observing = false
    private var debounce: Task<Void, Never>?

    var pendingCount: Int {
        guard authorization == .authorized || authorization == .limited else { return 0 }
        return max(0, fetch().count - uploaded.count)
    }

    func requestAccess() async {
        authorization = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        startObserving()
    }

    func startObserving() {
        guard !observing, authorization == .authorized || authorization == .limited else { return }
        observing = true
        PHPhotoLibrary.shared().register(self)
    }

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor in
            guard self.auto else { return }
            self.debounce?.cancel()
            self.debounce = Task {
                try? await Task.sleep(for: .seconds(4))
                if !Task.isCancelled { await self.syncNow() }
            }
        }
    }

    private func fetch() -> PHFetchResult<PHAsset> {
        let o = PHFetchOptions()
        o.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        if !includeVideos { o.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue) }
        return PHAsset.fetchAssets(with: o)
    }

    func syncNow() async {
        guard !running, Connection.shared.isSignedIn else { return }
        if authorization == .notDetermined { await requestAccess() }
        guard authorization == .authorized || authorization == .limited else { status = "Allow photo access in Settings"; return }
        running = true
        status = "Checking…"
        defer {
            running = false
            LiveActivityManager.shared.syncFinished()
        }
        // what the PC already has
        if let ids: [String] = try? await Connection.shared.get("/api/photos/synced") {
            uploaded.formUnion(ids)
        }
        let assets = fetch()
        var pending: [PHAsset] = []
        assets.enumerateObjects { a, _, _ in if !self.uploaded.contains(a.localIdentifier) { pending.append(a) } }
        total = pending.count
        done = 0
        guard total > 0 else {
            status = "Up to date"
            markSynced()
            return
        }
        let bg = UIApplication.shared.beginBackgroundTask(withName: "photo-sync")
        defer { UIApplication.shared.endBackgroundTask(bg) }
        for a in pending {
            if Task.isCancelled { break }
            status = "Uploading \(done + 1) of \(total)"
            LiveActivityManager.shared.sync(done: done, total: total, label: "Backing up photos")
            do {
                try await upload(a)
                uploaded.insert(a.localIdentifier)
                if done % 10 == 0 { UserDefaults.standard.set(Array(uploaded), forKey: "mg.uploaded") }
            } catch {
                status = "Paused: \(error.localizedDescription)"
                UserDefaults.standard.set(Array(uploaded), forKey: "mg.uploaded")
                return
            }
            done += 1
        }
        UserDefaults.standard.set(Array(uploaded), forKey: "mg.uploaded")
        status = "Backed up \(done) item\(done == 1 ? "" : "s")"
        markSynced()
    }

    private func markSynced() {
        lastSync = Date()
        UserDefaults.standard.set(lastSync, forKey: "mg.lastPhotoSync")
    }

    private func upload(_ a: PHAsset) async throws {
        let res = PHAssetResource.assetResources(for: a)
        guard let r = res.first(where: { $0.type == .fullSizePhoto || $0.type == .fullSizeVideo })
                ?? res.first(where: { $0.type == .photo || $0.type == .video }) ?? res.first else { return }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-" + r.originalFilename)
        let opts = PHAssetResourceRequestOptions()
        opts.isNetworkAccessAllowed = true
        try await PHAssetResourceManager.default().writeData(for: r, toFile: tmp, options: opts)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let created = Int((a.creationDate ?? Date()).timeIntervalSince1970)
        try await Connection.shared.upload("/api/photos/upload",
                                           query: ["asset": a.localIdentifier, "name": r.originalFilename, "created": "\(created)"],
                                           file: tmp)
    }

    // Background refresh
    nonisolated static func registerBackground() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: bgID, using: nil) { task in
            let t = Task { @MainActor in
                Connection.shared.connect()
                await PhotoSync.shared.syncNow()
                task.setTaskCompleted(success: true)
            }
            task.expirationHandler = { t.cancel() }
            scheduleBackground()
        }
    }

    nonisolated static func scheduleBackground() {
        let r = BGProcessingTaskRequest(identifier: bgID)
        r.requiresNetworkConnectivity = true
        r.requiresExternalPower = false
        r.earliestBeginDate = Date().addingTimeInterval(30 * 60)
        try? BGTaskScheduler.shared.submit(r)
    }
}

// MARK: - Universal clipboard

@MainActor
final class ClipboardSync: ObservableObject {
    static let shared = ClipboardSync()
    @Published var auto: Bool = UserDefaults.standard.object(forKey: "mg.clipAuto") as? Bool ?? true {
        didSet { UserDefaults.standard.set(auto, forKey: "mg.clipAuto") }
    }
    @Published var lastReceived: String?
    private var lastChange = UserDefaults.standard.integer(forKey: "mg.clipChange")

    func receivedFromPC(_ text: String) {
        guard !text.isEmpty else { return }
        UIPasteboard.general.string = text
        lastChange = UIPasteboard.general.changeCount
        UserDefaults.standard.set(lastChange, forKey: "mg.clipChange")
        lastReceived = text
        Haptics.tap()
    }

    /// Called when the app comes to the foreground: sends anything new you copied on the phone.
    func checkPhoneClipboard() {
        guard auto, Connection.shared.isSignedIn else { return }
        let pb = UIPasteboard.general
        guard pb.changeCount != lastChange else { return }
        lastChange = pb.changeCount
        UserDefaults.standard.set(lastChange, forKey: "mg.clipChange")
        guard pb.hasStrings, let s = pb.string, !s.isEmpty else { return }
        send(s)
    }

    func send(_ s: String) {
        Task { try? await Connection.shared.post("/api/clipboard", json: ["text": s]) }
    }
}

// MARK: - Commands from the PC

@MainActor
final class Coordinator: ObservableObject {
    static let shared = Coordinator()
    @Published var findMe = false
    @Published var banner: String?
    private var bag = Set<AnyCancellable>()
    private var ring: Task<Void, Never>?

    func start() {
        Connection.shared.events.sink { [weak self] e in self?.handle(e) }.store(in: &bag)
    }

    private func handle(_ e: WSEvent) {
        switch e.name {
        case "clipboard":
            if let t = e.body["text"] as? String { ClipboardSync.shared.receivedFromPC(t); show("Copied from PC") }
        case "shared":
            if let d = try? JSONSerialization.data(withJSONObject: e.body["item"] ?? [:]),
               let item = try? JSONDecoder().decode(SharedItem.self, from: d) {
                SharedStore.shared.insert(item)
                if item.from == "pc" && item.kind != "clipboard" { show(item.isFile ? "Received \(item.name ?? "file")" : "New text from PC") }
            }
        case "library":
            Task { await MusicStore.shared.refresh() }
        case "signedout":
            Connection.shared.signOut()
        case "command":
            guard let c = e.body["command"] as? [String: Any], let cmd = c["cmd"] as? String else { return }
            switch cmd {
            case "player":
                switch c["action"] as? String ?? "" {
                case "toggle": Player.shared.toggle()
                case "next": Player.shared.next()
                case "prev": Player.shared.previous()
                case "shuffle": Player.shared.shuffleAll()
                default: break
                }
            case "find": startRinging()
            case "syncPhotos": Task { await PhotoSync.shared.syncNow() }
            case "clipboard":
                if let t = c["text"] as? String { ClipboardSync.shared.receivedFromPC(t); show("Copied from PC") }
            default: break
            }
        default: break
        }
    }

    func show(_ s: String) {
        banner = s
        Task { try? await Task.sleep(for: .seconds(2.5)); if banner == s { banner = nil } }
    }

    func startRinging() {
        findMe = true
        ring?.cancel()
        ring = Task {
            for _ in 0..<30 where !Task.isCancelled && findMe {
                AudioServicesPlayAlertSound(SystemSoundID(1005))
                AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
                try? await Task.sleep(for: .seconds(1.2))
            }
            findMe = false
        }
    }

    func stopRinging() { findMe = false; ring?.cancel() }
}

// MARK: - Shared items

@MainActor
final class SharedStore: ObservableObject {
    static let shared = SharedStore()
    @Published var items: [SharedItem] = []
    @Published var loading = false

    func refresh() async {
        loading = true
        defer { loading = false }
        if let i: [SharedItem] = try? await Connection.shared.get("/api/shared") { items = i }
    }

    func insert(_ i: SharedItem) {
        items.removeAll { $0.id == i.id }
        items.insert(i, at: 0)
    }

    func sendText(_ t: String) async throws {
        try await Connection.shared.post("/api/shared/text", json: ["text": t])
    }

    func sendFile(_ url: URL) async throws {
        try await Connection.shared.upload("/api/shared/file", query: ["name": url.lastPathComponent], file: url)
    }

    func sendData(_ d: Data, name: String) async throws {
        try await Connection.shared.upload("/api/shared/file", query: ["name": name], data: d)
    }

    /// Download a shared file to a temporary URL for preview / share sheet.
    func fetch(_ i: SharedItem) async throws -> URL {
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(i.name ?? i.id)
        if FileManager.default.fileExists(atPath: dest.path) { return dest }
        let (tmp, _) = try await Connection.shared.session.download(from: Connection.shared.url("/api/shared/file/\(i.id)"))
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }
}

enum Haptics {
    @MainActor static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    @MainActor static func soft() { UIImpactFeedbackGenerator(style: .soft).impactOccurred() }
    @MainActor static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
}

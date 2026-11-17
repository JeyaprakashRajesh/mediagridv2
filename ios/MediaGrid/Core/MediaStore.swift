import Foundation
import Photos
import UIKit

/// PC photos & videos: streamed by default, cached on the phone after "Sync".
@MainActor
final class MediaStore: ObservableObject {
    static let shared = MediaStore()

    @Published var items: [MediaItem] = []
    @Published var downloaded: Set<String> = []
    @Published var loading = false
    @Published var syncing = false
    @Published var syncDone = 0
    @Published var syncTotal = 0
    @Published var error: String?

    let dir: URL
    private let cacheURL: URL
    private var task: Task<Void, Never>?

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        dir = docs.appendingPathComponent("Media", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var v = URLResourceValues(); v.isExcludedFromBackup = true
        var d = dir; try? d.setResourceValues(v)
        cacheURL = docs.appendingPathComponent("media.json")
        if let data = try? Data(contentsOf: cacheURL), let i = try? JSONDecoder().decode([MediaItem].self, from: data) { items = i }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        downloaded = Set(files.map { ($0 as NSString).deletingPathExtension })
    }

    func refresh() async {
        guard Connection.shared.isSignedIn else { return }
        loading = true
        defer { loading = false }
        do {
            let i: [MediaItem] = try await Connection.shared.get("/api/media/items")
            items = i
            error = nil
            if let d = try? JSONEncoder().encode(i) { try? d.write(to: cacheURL, options: .atomic) }
        } catch { self.error = error.localizedDescription }
    }

    func localURL(_ m: MediaItem) -> URL {
        dir.appendingPathComponent(m.id + "." + (m.name as NSString).pathExtension.lowercased())
    }

    func isLocal(_ m: MediaItem) -> Bool { downloaded.contains(m.id) }

    func fileURL(_ m: MediaItem) -> URL {
        isLocal(m) ? localURL(m) : Connection.shared.url("/api/media/file/\(m.id)")
    }

    func thumbURL(_ m: MediaItem, size: Int = 420) -> URL {
        if m.isVideo { return fileURL(m) }
        return Connection.shared.url("/api/media/thumb/\(m.id)", ["s": "\(size)"])
    }

    func download(_ m: MediaItem) async throws {
        if isLocal(m) { return }
        let (tmp, r) = try await Connection.shared.session.download(from: Connection.shared.url("/api/media/file/\(m.id)"))
        guard (r as? HTTPURLResponse)?.statusCode == 200 else { throw APIError.bad }
        let dest = localURL(m)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        downloaded.insert(m.id)
    }

    func syncAll(_ list: [MediaItem]) {
        guard !syncing else { return }
        let todo = list.filter { !isLocal($0) }
        guard !todo.isEmpty else { return }
        syncing = true; syncDone = 0; syncTotal = todo.count
        let bg = UIApplication.shared.beginBackgroundTask(withName: "media-sync")
        task = Task {
            await withTaskGroup(of: Void.self) { g in
                var it = todo.makeIterator()
                for _ in 0..<3 { if let m = it.next() { g.addTask { try? await self.download(m) } } }
                while await g.next() != nil {
                    self.syncDone += 1
                    LiveActivityManager.shared.sync(done: self.syncDone, total: self.syncTotal, label: "Syncing media")
                    if Task.isCancelled { break }
                    if let m = it.next() { g.addTask { try? await self.download(m) } }
                }
            }
            syncing = false
            LiveActivityManager.shared.syncFinished()
            UIApplication.shared.endBackgroundTask(bg)
        }
    }

    func cancelSync() { task?.cancel(); syncing = false }

    var localBytes: Int64 { items.filter { downloaded.contains($0.id) }.reduce(0) { $0 + $1.size } }

    func clearLocal() {
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        downloaded.removeAll()
    }

    /// Save a PC photo/video into the iPhone Photos app.
    func saveToPhotos(_ m: MediaItem) async throws {
        try await download(m)
        let url = localURL(m)
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw APIError.server("Allow MediaGrid to add photos in Settings.") }
        try await PHPhotoLibrary.shared().performChanges {
            let req = PHAssetCreationRequest.forAsset()
            req.addResource(with: m.isVideo ? .video : .photo, fileURL: url, options: nil)
        }
    }
}

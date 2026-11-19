import UIKit
import SwiftUI
import AVFoundation
import CryptoKit
import ImageIO

/// Memory + disk cache for artwork, thumbnails and video frames.
actor ImageCache {
    static let shared = ImageCache()

    private let mem = NSCache<NSString, UIImage>()
    private let dir: URL
    private var inflight: [String: Task<UIImage?, Never>] = [:]

    init() {
        dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("img", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        mem.countLimit = 600
    }

    nonisolated static func key(_ url: URL) -> String {
        // strip the auth token so cache survives re-login
        var s = url.absoluteString
        if var c = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            let items = (c.queryItems ?? []).filter { $0.name != "t" }
            c.queryItems = items.isEmpty ? nil : items
            c.host = nil
            c.port = nil
            s = c.string ?? s
        }
        return SHA256.hash(data: Data(s.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    func cached(_ url: URL) -> UIImage? { mem.object(forKey: Self.key(url) as NSString) }

    func image(_ url: URL, video: Bool = false) async -> UIImage? {
        let k = Self.key(url)
        if let i = mem.object(forKey: k as NSString) { return i }
        if let t = inflight[k] { return await t.value }
        let file = dir.appendingPathComponent(k + ".jpg")
        let t = Task<UIImage?, Never> {
            if let d = try? Data(contentsOf: file), let i = UIImage(data: d) { return i }
            let img: UIImage?
            if video {
                img = await Self.videoFrame(url)
            } else {
                guard let (d, r) = try? await URLSession.shared.data(from: url),
                      (r as? HTTPURLResponse)?.statusCode == 200 else { return nil }
                img = await Self.downsample(d, max: 900)
            }
            if let img, let jd = img.jpegData(compressionQuality: 0.82) { try? jd.write(to: file) }
            return img
        }
        inflight[k] = t
        let img = await t.value
        inflight[k] = nil
        if let img { mem.setObject(img, forKey: k as NSString) }
        return img
    }

    nonisolated static func downsample(_ data: Data, max: CGFloat) async -> UIImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return UIImage(data: data) }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceShouldCacheImmediately: true,
                                     kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: max]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return UIImage(data: data) }
        return UIImage(cgImage: cg)
    }

    nonisolated static func videoFrame(_ url: URL) async -> UIImage? {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 600, height: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 2, preferredTimescale: 600)
        guard let (cg, _) = try? await gen.image(at: CMTime(seconds: 1, preferredTimescale: 600)) else { return nil }
        return UIImage(cgImage: cg)
    }

    func forget(_ url: URL) {
        let k = Self.key(url)
        mem.removeObject(forKey: k as NSString)
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(k + ".jpg"))
    }

    func clear() {
        mem.removeAllObjects()
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
}

/// Async image with fade-in, backed by ImageCache.
struct RemoteImage<Placeholder: View>: View {
    let url: URL?
    var video = false
    var contentMode: ContentMode = .fill
    @ViewBuilder var placeholder: () -> Placeholder
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode)
                    .transition(.opacity.animation(.easeOut(duration: 0.15)))
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            guard let url else { image = nil; return }
            if let c = await ImageCache.shared.cached(url) { image = c; return }
            let i = await ImageCache.shared.image(url, video: video)
            withAnimation { image = i }
        }
    }
}

/// Album art with a gradient fallback derived from the track.
struct ArtworkView: View {
    let track: Track?
    var size: CGFloat = 48
    var radius: CGFloat = 10

    var body: some View {
        let seed = (track?.album ?? "mg").unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        let palette = Theme.palettes[seed % Theme.palettes.count]
        RemoteImage(url: track.flatMap { MusicStore.shared.artURL($0) }) {
            ZStack {
                LinearGradient(colors: palette, startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "music.note").font(.system(size: size * 0.36, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

import SwiftUI
import UIKit

/// Average colour of a song's cover, used to tint containers (current song row, cards).
@MainActor
final class ArtColors {
    static let shared = ArtColors()
    private var cache: [String: Color] = [:]

    private var vib: [String: UIColor] = [:]

    /// The most vivid colour in the cover (16x16 sample, saturation-weighted hue buckets); nil for grey covers.
    func vibrant(for t: Track) async -> UIColor? {
        if let c = vib[t.id] { return c }
        guard let u = MusicStore.shared.artURL(t), let img = await ImageCache.shared.image(u), let cg = img.cgImage else { return nil }
        let n = 16
        var px = [UInt8](repeating: 0, count: n * n * 4)
        px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: n, height: n))
        }
        var w = [Double](repeating: 0, count: 12), hs = w, ss = w, bs = w
        for i in 0..<(n * n) {
            let c = UIColor(red: CGFloat(px[i * 4]) / 255, green: CGFloat(px[i * 4 + 1]) / 255, blue: CGFloat(px[i * 4 + 2]) / 255, alpha: 1)
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            let k = min(11, Int(h * 12)), wt = Double(s * s * b)
            w[k] += wt; hs[k] += Double(h) * wt; ss[k] += Double(s) * wt; bs[k] += Double(b) * wt
        }
        guard let k = w.indices.max(by: { w[$0] < w[$1] }), w[k] > 0.5 else { return nil }
        let c = UIColor(hue: hs[k] / w[k], saturation: ss[k] / w[k], brightness: bs[k] / w[k], alpha: 1)
        vib[t.id] = c
        return c
    }

    func color(for t: Track) async -> Color? {
        if let c = cache[t.id] { return c }
        guard let u = MusicStore.shared.artURL(t), let img = await ImageCache.shared.image(u), let cg = img.cgImage else { return nil }
        var px = [UInt8](repeating: 0, count: 4)
        px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        let c = Color(red: Double(px[0]) / 255, green: Double(px[1]) / 255, blue: Double(px[2]) / 255)
        cache[t.id] = c
        return c
    }
}

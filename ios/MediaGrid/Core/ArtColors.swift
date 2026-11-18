import SwiftUI
import UIKit

/// Average colour of a song's cover, used to tint containers (current song row, cards).
@MainActor
final class ArtColors {
    static let shared = ArtColors()
    private var cache: [String: Color] = [:]

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

import SwiftUI

/// Lyrics for the song that's playing (the PC fetches them from LRCLIB). Synced lyrics follow the song and a tap seeks;
/// songs without timing show plain text.
struct LyricsView: View {
    let track: Track?
    @EnvironmentObject var player: Player
    @State private var lines: [Line] = []
    @State private var plain = ""
    @State private var state = "Looking for lyrics…"

    struct Line: Identifiable { let id: Int; let t: Double; let s: String }
    private struct Reply: Decodable { var synced: String?; var plain: String? }

    private var current: Int {
        guard !lines.isEmpty else { return -1 }
        return (lines.lastIndex { $0.t <= player.time + 0.2 }) ?? -1
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    if !lines.isEmpty {
                        ForEach(lines) { l in
                            Text(l.s.isEmpty ? "♪" : l.s)
                                .font(.title2.weight(.bold))
                                .foregroundStyle(.white.opacity(l.id == current ? 1 : 0.4))
                                .scaleEffect(l.id == current ? 1 : 0.96, anchor: .leading)
                                .animation(.smooth(duration: 0.2), value: current)
                                .id(l.id)
                                .onTapGesture { player.seek(l.t); Haptics.tap() }
                        }
                    } else {
                        Text(plain.isEmpty ? state : plain).font(.body).foregroundStyle(.white.opacity(0.85))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 30)
            }
            .onChange(of: current) { _, c in if c >= 0 { withAnimation(.smooth(duration: 0.3)) { proxy.scrollTo(c, anchor: .center) } } }
        }
        .task(id: track?.id) { await load() }
    }

    private func load() async {
        lines = []; plain = ""; state = "Looking for lyrics…"
        guard let t = track else { return }
        guard let r: Reply = try? await Connection.shared.get("/api/music/lyrics/\(t.id)") else { state = "Couldn't load lyrics."; return }
        let parsed = (r.synced ?? "").split(separator: "\n").compactMap { raw -> (Double, String)? in
            // [mm:ss.xx] text
            guard raw.hasPrefix("["), let close = raw.firstIndex(of: "]") else { return nil }
            let stamp = raw[raw.index(after: raw.startIndex)..<close].split(separator: ":")
            guard stamp.count == 2, let m = Double(stamp[0]), let s = Double(stamp[1]) else { return nil }
            return (m * 60 + s, raw[raw.index(after: close)...].trimmingCharacters(in: .whitespaces))
        }
        lines = parsed.enumerated().map { Line(id: $0.offset, t: $0.element.0, s: $0.element.1) }
        plain = r.plain ?? ""
        if lines.isEmpty && plain.isEmpty { state = "No lyrics found for this song." }
    }
}

import SwiftUI
import AVKit

/// Lives in the tab bar's bottom accessory (Liquid Glass).
struct MiniPlayer: View {
    @EnvironmentObject var player: Player
    @EnvironmentObject var music: MusicStore
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    @ObservedObject private var tint = TintStore.shared
    var open: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if let t = player.current {
                ArtworkView(track: t, size: placement == .inline ? 28 : 36, radius: 8)
                    .scaleEffect(player.isPlaying ? 1 : 0.92)
                    .animation(.spring(duration: 0.25), value: player.isPlaying)
                VStack(alignment: .leading, spacing: 1) {
                    Text(t.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    if placement != .inline {
                        Text(t.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .contentTransition(.opacity)
                Spacer(minLength: 4)
                Button { player.toggle() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3).contentTransition(.symbolEffect(.replace))
                        .frame(width: 34, height: 34)
                }
                if placement != .inline {
                    Button { player.next() } label: { Image(systemName: "forward.fill").font(.body).frame(width: 30, height: 34) }
                }
            } else if let r = music.recentlyPlayed.first {
                ArtworkView(track: r.track, size: placement == .inline ? 28 : 36, radius: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(r.track.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    if placement != .inline {
                        Text("Recently played · \(r.at.relative)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                Button { player.playRecent(r.track, in: music.recentlyPlayed.map(\.track), pos: r.pos) } label: {
                    Image(systemName: "play.fill").font(.title3).frame(width: 34, height: 34)
                }
            } else {
                Image(systemName: "music.note").foregroundStyle(tint.color)
                Text(music.tracks.isEmpty ? "Connect your PC to stream music" : "Pick a song to start")
                    .font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer()
            }
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 14)
        .contentShape(Rectangle())
        .onTapGesture { if player.current != nil { open() } }
        .animation(.smooth(duration: 0.2), value: player.current?.id)
    }
}

struct NowPlayingView: View {
    var onClose: () -> Void
    @EnvironmentObject var player: Player
    @EnvironmentObject var music: MusicStore
    @State private var scrubbing = false
    @State private var scrubValue: Double = 0
    @State private var showQueue = false
    @State private var downloading = false
    @ObservedObject private var ui = UIState.shared
    @ObservedObject private var tint = TintStore.shared

    private var goTarget: SongCollection? {
        guard let id = player.collectionID, let c = music.collection(id: id) else { return nil }
        return ui.musicPath.last?.id == c.id ? nil : c
    }

    private var shown: Double { scrubbing ? scrubValue : player.time }

    var body: some View {
        let t = player.current
        VStack(spacing: 18) {
            header

            if showQueue {
                queue.transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                GeometryReader { g in
                    let side = min(g.size.width, g.size.height)
                    ArtworkView(track: t, size: side, radius: 24)
                        .scaleEffect(player.isPlaying ? 1 : 0.88)
                        .shadow(color: .black.opacity(0.5), radius: player.isPlaying ? 36 : 16, y: 18)
                        .frame(width: g.size.width, height: g.size.height)
                        .animation(.spring(duration: 0.35, bounce: 0.2), value: player.isPlaying)
                        .id(t?.id)
                        .transition(.asymmetric(insertion: .scale(scale: 0.9).combined(with: .opacity), removal: .opacity))
                }
                .frame(maxWidth: 400, maxHeight: 400)
                .frame(maxHeight: .infinity)
            }

            if let c = goTarget {
                Button { ui.goTo(c); Haptics.tap() } label: { Label("Go to playlist", systemImage: "music.note.list").font(.subheadline.weight(.semibold)) }
                    .buttonStyle(.glass)
            }

            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(t?.title ?? "Not Playing").font(.title2.weight(.bold)).lineLimit(1).minimumScaleFactor(0.75)
                    Text(t?.artist ?? "").font(.body).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentTransition(.opacity)
                if let t {
                    Button { music.toggleLike(t); Haptics.tap() } label: {
                        Image(systemName: music.liked.contains(t.id) ? "heart.fill" : "heart")
                            .font(.title2).foregroundStyle(music.liked.contains(t.id) ? Theme.pink : .white)
                            .contentTransition(.symbolEffect(.replace))
                            .symbolEffect(.bounce, value: music.liked.contains(t.id))
                    }
                }
            }

            // scrubber
            VStack(spacing: 4) {
                Slider(value: Binding(get: { shown }, set: { scrubValue = $0 }), in: 0...max(player.duration, 1)) { editing in
                    if editing { scrubValue = player.time; scrubbing = true }
                    else { player.seek(scrubValue); scrubbing = false }
                }
                .tint(.white)
                HStack {
                    Text(shown.mmss)
                    Spacer()
                    if player.buffering { ProgressView().controlSize(.mini) }
                    Spacer()
                    Text("-" + max(0, player.duration - shown).mmss)
                }
                .font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.7))
            }

            // transport
            HStack {
                Button { player.shuffle.toggle(); Haptics.tap() } label: {
                    Image(systemName: "shuffle").font(.title3).foregroundStyle(player.shuffle ? tint.color : .white.opacity(0.7))
                }
                Spacer()
                Button { player.previous() } label: { Image(systemName: "backward.fill").font(.system(size: 28)) }
                Spacer()
                Button { player.toggle(); Haptics.soft() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 22)).frame(width: 54, height: 54)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.glassProminent).buttonBorderShape(.circle).tint(tint.color).foregroundStyle(.white)
                Spacer()
                Button { player.next() } label: { Image(systemName: "forward.fill").font(.system(size: 28)) }
                Spacer()
                Button {
                    player.repeatMode = RepeatMode(rawValue: (player.repeatMode.rawValue + 1) % 3) ?? .off
                    Haptics.tap()
                } label: {
                    Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                        .font(.title3).foregroundStyle(player.repeatMode == .off ? .white.opacity(0.7) : tint.color)
                }
            }

            HStack {
                AirPlayButton().frame(width: 34, height: 34)
                Spacer()
                if let t {
                    Label(music.isDownloaded(t) ? "On iPhone" : "Streaming from PC",
                          systemImage: music.isDownloaded(t) ? "arrow.down.circle.fill" : "dot.radiowaves.left.and.right")
                        .font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.7))
                }
                Spacer()
                if let t {
                    Button {
                        downloading = true
                        Task { try? await music.download(t); downloading = false; Haptics.success() }
                    } label: {
                        if downloading { ProgressView() }
                        else { Image(systemName: music.isDownloaded(t) ? "checkmark.circle.fill" : "arrow.down.circle").font(.title3) }
                    }
                    .frame(width: 34, height: 34)
                    .disabled(music.isDownloaded(t) || downloading)
                    .accessibilityLabel(music.isDownloaded(t) ? "Downloaded" : "Download")
                }
                ShareLink(item: t.map { "\($0.title) — \($0.artist)" } ?? "") { Image(systemName: "square.and.arrow.up") }
                    .frame(width: 34, height: 34)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 24)
        .padding(.top, 8).padding(.bottom, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            // Colour of the song, easing between tracks; a static black fade on top keeps text readable.
            tint.color
                .overlay { LinearGradient(colors: [.black.opacity(0.1), .black.opacity(0.92)], startPoint: .top, endPoint: .bottom) }
                .ignoresSafeArea()
        }
        .environment(\.colorScheme, .dark)
        .gesture(DragGesture(minimumDistance: 24).onEnded { v in
            if v.translation.width > 90, abs(v.translation.height) < 80 { onClose() }   // swipe right = back
        })
        .animation(.smooth(duration: 0.28), value: t?.id)
    }

    private var header: some View {
        HStack {
            Button(action: onClose) { Image(systemName: "chevron.left").font(.headline).frame(width: 40, height: 40) }
                .buttonStyle(.glass).buttonBorderShape(.circle)
            Spacer()
            VStack(spacing: 2) {
                Text("PLAYING FROM").font(.caption2.weight(.bold)).foregroundStyle(.white.opacity(0.6))
                Text(player.source.isEmpty ? "Your Library" : player.source).font(.footnote.weight(.semibold)).lineLimit(1)
            }
            Spacer()
            Button { withAnimation(.spring) { showQueue.toggle() } } label: {
                Image(systemName: showQueue ? "music.note" : "list.bullet").font(.headline).frame(width: 40, height: 40)
            }
            .buttonStyle(.glass).buttonBorderShape(.circle)
        }
    }

    private var queue: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Up Next").font(.title3.weight(.bold))
            if player.upNext.isEmpty {
                Text("Nothing queued").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(Array(player.upNext.enumerated()), id: \.offset) { i, tr in
                            Button { player.jump(to: i) } label: {
                                HStack(spacing: 12) {
                                    ArtworkView(track: tr, size: 44, radius: 8)
                                    VStack(alignment: .leading) {
                                        Text(tr.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                                        Text(tr.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer()
                                    Text(tr.duration.mmss).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                }
                                .padding(8).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 26))
        .frame(maxHeight: .infinity)
    }
}

struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.tintColor = .white
        v.activeTintColor = UIColor(Theme.violet)
        v.prioritizesVideoDevices = false
        return v
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

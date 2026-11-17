import SwiftUI
import AVKit

/// Lives in the tab bar's bottom accessory (Liquid Glass).
struct MiniPlayer: View {
    @EnvironmentObject var player: Player
    @EnvironmentObject var music: MusicStore
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    var open: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if let t = player.current {
                ArtworkView(track: t, size: placement == .inline ? 28 : 36, radius: 8)
                    .scaleEffect(player.isPlaying ? 1 : 0.92)
                    .animation(.spring(duration: 0.4), value: player.isPlaying)
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
            } else {
                Image(systemName: "shuffle").foregroundStyle(Theme.violet)
                Text(music.tracks.isEmpty ? "Connect your PC to stream music" : "Shuffle your library")
                    .font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer()
                if !music.tracks.isEmpty {
                    Button { player.shuffleAll() } label: { Image(systemName: "play.fill").frame(width: 34, height: 34) }
                }
            }
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 14)
        .contentShape(Rectangle())
        .onTapGesture { if player.current != nil { open() } }
        .animation(.smooth, value: player.current?.id)
    }
}

struct NowPlayingView: View {
    @EnvironmentObject var player: Player
    @EnvironmentObject var music: MusicStore
    @Environment(\.dismiss) private var dismiss
    @State private var scrubbing = false
    @State private var scrubValue: Double = 0
    @State private var showQueue = false

    var body: some View {
        let t = player.current
        ZStack {
            // blurred artwork backdrop
            ZStack {
                Theme.ink
                ArtworkView(track: t, size: 600, radius: 0)
                    .blur(radius: 80).scaleEffect(1.6).opacity(0.75)
                LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .top, endPoint: .bottom)
            }
            .ignoresSafeArea()

            VStack(spacing: 22) {
                HStack {
                    Button { dismiss() } label: { Image(systemName: "chevron.down").font(.headline).frame(width: 40, height: 40) }
                        .buttonStyle(.glass).buttonBorderShape(.circle)
                    Spacer()
                    VStack(spacing: 2) {
                        Text("PLAYING FROM").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                        Text(player.source.isEmpty ? "Your Library" : player.source).font(.footnote.weight(.semibold)).lineLimit(1)
                    }
                    Spacer()
                    Button { withAnimation(.spring) { showQueue.toggle() } } label: {
                        Image(systemName: showQueue ? "music.note" : "list.bullet").font(.headline).frame(width: 40, height: 40)
                    }
                    .buttonStyle(.glass).buttonBorderShape(.circle)
                }
                .padding(.top, 14)

                if showQueue {
                    queue.transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    Spacer(minLength: 0)
                    GeometryReader { g in
                        let side = min(g.size.width, g.size.height)
                        ArtworkView(track: t, size: side, radius: 24)
                            .scaleEffect(player.isPlaying ? 1 : 0.86)
                            .shadow(color: .black.opacity(0.5), radius: player.isPlaying ? 40 : 18, y: 20)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .animation(.spring(duration: 0.6, bounce: 0.3), value: player.isPlaying)
                            .id(t?.id)
                            .transition(.asymmetric(insertion: .scale(scale: 0.9).combined(with: .opacity), removal: .opacity))
                    }
                    .frame(maxHeight: 360)
                    Spacer(minLength: 0)
                }

                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(t?.title ?? "Not Playing").font(.title2.weight(.bold)).lineLimit(1)
                        Text(t?.artist ?? "").font(.title3).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .contentTransition(.opacity)
                    Spacer()
                    if let t {
                        Button { music.toggleLike(t); Haptics.tap() } label: {
                            Image(systemName: music.liked.contains(t.id) ? "heart.fill" : "heart")
                                .font(.title2).foregroundStyle(music.liked.contains(t.id) ? Theme.pink : .primary)
                                .contentTransition(.symbolEffect(.replace))
                                .symbolEffect(.bounce, value: music.liked.contains(t.id))
                        }
                    }
                }

                // scrubber
                VStack(spacing: 6) {
                    Slider(value: Binding(get: { scrubbing ? scrubValue : player.time },
                                          set: { scrubValue = $0 }),
                           in: 0...max(player.duration, 1), onEditingChanged: { editing in
                        if editing { scrubValue = player.time; scrubbing = true }
                        else { player.seek(scrubValue); scrubbing = false }
                    })
                    .tint(.white)
                    HStack {
                        Text((scrubbing ? scrubValue : player.time).mmss)
                        Spacer()
                        if player.buffering { ProgressView().controlSize(.mini) }
                        Spacer()
                        Text("-" + max(0, player.duration - (scrubbing ? scrubValue : player.time)).mmss)
                    }
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }

                // transport
                HStack {
                    Button { player.shuffle.toggle(); Haptics.tap() } label: {
                        Image(systemName: "shuffle").font(.title3).foregroundStyle(player.shuffle ? Theme.violet : .secondary)
                    }
                    Spacer()
                    Button { player.previous() } label: { Image(systemName: "backward.fill").font(.system(size: 30)) }
                    Spacer()
                    Button { player.toggle(); Haptics.soft() } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 34)).frame(width: 78, height: 78)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.glassProminent).buttonBorderShape(.circle).tint(.white.opacity(0.9)).foregroundStyle(.black)
                    Spacer()
                    Button { player.next() } label: { Image(systemName: "forward.fill").font(.system(size: 30)) }
                    Spacer()
                    Button {
                        player.repeatMode = RepeatMode(rawValue: (player.repeatMode.rawValue + 1) % 3) ?? .off
                        Haptics.tap()
                    } label: {
                        Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                            .font(.title3).foregroundStyle(player.repeatMode == .off ? .secondary : Theme.violet)
                    }
                }
                .foregroundStyle(.white)

                HStack {
                    AirPlayButton().frame(width: 34, height: 34)
                    Spacer()
                    if let t {
                        Label(music.isDownloaded(t) ? "On iPhone" : "Streaming from PC",
                              systemImage: music.isDownloaded(t) ? "arrow.down.circle.fill" : "dot.radiowaves.left.and.right")
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    ShareLink(item: t.map { "\($0.title) — \($0.artist)" } ?? "") { Image(systemName: "square.and.arrow.up") }
                        .frame(width: 34, height: 34)
                }
                .padding(.bottom, 8)
            }
            .padding(.horizontal, 26)
        }
        .animation(.smooth(duration: 0.45), value: t?.id)
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

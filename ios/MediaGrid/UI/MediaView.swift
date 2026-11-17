import SwiftUI
import AVKit

struct MediaView: View {
    @EnvironmentObject var media: MediaStore
    @EnvironmentObject var conn: Connection
    @State private var filter = 0 // 0 all, 1 photos, 2 videos, 3 iPhone
    @State private var selected: MediaItem?
    @State private var columns = 3
    @Namespace private var ns

    private var list: [MediaItem] {
        switch filter {
        case 1: return media.items.filter { !$0.isVideo }
        case 2: return media.items.filter(\.isVideo)
        case 3: return media.items.filter(\.from_iphone)
        default: return media.items
        }
    }

    struct MonthGroup: Identifiable { let id: String; let items: [MediaItem] }

    private var grouped: [MonthGroup] {
        let f = DateFormatter(); f.dateFormat = "MMMM yyyy"
        var order: [String] = []
        var map: [String: [MediaItem]] = [:]
        for m in list {
            let k = f.string(from: m.date)
            if map[k] == nil { order.append(k) }
            map[k, default: []].append(m)
        }
        return order.map { MonthGroup(id: $0, items: map[$0]!) }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()
                ScrollView {
                    VStack(spacing: 16) {
                        Picker("Filter", selection: $filter.animation(.smooth)) {
                            Text("All").tag(0); Text("Photos").tag(1); Text("Videos").tag(2); Text("iPhone").tag(3)
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal, 20)

                        if media.syncing {
                            HStack {
                                ProgressView(value: Double(media.syncDone), total: Double(max(media.syncTotal, 1))).tint(Theme.violet)
                                Text("\(media.syncDone)/\(media.syncTotal)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                Button("Stop") { media.cancelSync() }.font(.caption.weight(.semibold))
                            }
                            .padding(14).glassEffect(.regular, in: .rect(cornerRadius: 18)).padding(.horizontal, 20)
                        }

                        if list.isEmpty {
                            ContentUnavailableView(media.loading ? "Loading…" : "No media", systemImage: "photo.on.rectangle.angled",
                                                   description: Text(media.error ?? "Add photo & video folders in MediaGrid on your PC."))
                                .padding(.top, 60)
                        }

                        LazyVStack(alignment: .leading, spacing: 18, pinnedViews: []) {
                            ForEach(grouped) { g in
                                let items = g.items
                                Text(g.id).font(.headline).padding(.horizontal, 20)
                                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: columns), spacing: 3) {
                                    ForEach(items) { m in
                                        MediaTile(item: m)
                                            .matchedTransitionSource(id: m.id, in: ns)
                                            .onTapGesture { selected = m }
                                            .contextMenu {
                                                Button { Task { try? await media.saveToPhotos(m); Haptics.success() } } label: { Label("Save to Photos", systemImage: "square.and.arrow.down") }
                                                if !media.isLocal(m) {
                                                    Button { Task { try? await media.download(m) } } label: { Label("Keep on iPhone", systemImage: "arrow.down.circle") }
                                                }
                                            }
                                    }
                                }
                                .padding(.horizontal, 3)
                            }
                        }
                    }
                    .padding(.bottom, 60)
                }
                .refreshable { await media.refresh() }
            }
            .navigationTitle("Media")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu {
                        Picker("Grid", selection: $columns.animation(.smooth)) {
                            Label("Large", systemImage: "square.grid.2x2").tag(2)
                            Label("Medium", systemImage: "square.grid.3x3").tag(3)
                            Label("Small", systemImage: "square.grid.4x3.fill").tag(5)
                        }
                    } label: { Image(systemName: "square.grid.2x2") }
                    Button { media.syncAll(list); Haptics.tap() } label: {
                        Image(systemName: "arrow.triangle.2.circlepath").symbolEffect(.rotate, isActive: media.syncing)
                    }
                    .disabled(media.syncing || conn.state != .online)
                }
            }
            .fullScreenCover(item: $selected) { m in
                MediaViewer(items: list, start: m)
                    .navigationTransition(.zoom(sourceID: m.id, in: ns))
            }
        }
    }
}

struct MediaTile: View {
    let item: MediaItem
    @EnvironmentObject var media: MediaStore
    var body: some View {
        Color.white.opacity(0.05)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                RemoteImage(url: media.thumbURL(item), video: item.isVideo) {
                    Image(systemName: item.isVideo ? "film" : "photo").foregroundStyle(.tertiary)
                }
            }
            .clipped()
            .overlay(alignment: .bottomLeading) {
                if item.isVideo {
                    Image(systemName: "play.fill").font(.caption2).padding(6)
                        .glassEffect(.regular, in: .circle).padding(5)
                }
            }
            .overlay(alignment: .topTrailing) {
                if item.from_iphone {
                    Image(systemName: "iphone").font(.caption2).padding(5).glassEffect(.regular, in: .circle).padding(5)
                }
            }
            .contentShape(Rectangle())
    }
}

struct MediaViewer: View {
    let items: [MediaItem]
    let start: MediaItem
    @EnvironmentObject var media: MediaStore
    @Environment(\.dismiss) private var dismiss
    @State private var current: String = ""
    @State private var chrome = true
    @State private var saved = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            TabView(selection: $current) {
                ForEach(window, id: \.id) { m in
                    Group {
                        if m.isVideo { StreamVideo(url: media.fileURL(m), active: current == m.id) }
                        else { ZoomablePhoto(item: m) }
                    }
                    .tag(m.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()
            .onTapGesture { withAnimation { chrome.toggle() } }

            if chrome, let m = items.first(where: { $0.id == current }) {
                VStack {
                    HStack {
                        Button { dismiss() } label: { Image(systemName: "xmark").font(.headline).frame(width: 42, height: 42) }
                            .buttonStyle(.glass).buttonBorderShape(.circle)
                        Spacer()
                        VStack(spacing: 2) {
                            Text(m.name).font(.footnote.weight(.semibold)).lineLimit(1)
                            Text("\(m.date.formatted(date: .abbreviated, time: .shortened)) · \(m.size.byteString)").font(.caption2).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .glassEffect(.regular, in: .capsule)
                        Spacer()
                        Button {
                            Task { try? await media.saveToPhotos(m); Haptics.success(); saved = true }
                        } label: {
                            Image(systemName: saved ? "checkmark" : "square.and.arrow.down").font(.headline).frame(width: 42, height: 42)
                                .contentTransition(.symbolEffect(.replace))
                        }
                        .buttonStyle(.glass).buttonBorderShape(.circle)
                    }
                    .padding(.horizontal)
                    Spacer()
                }
                .transition(.opacity)
            }
        }
        .onAppear { current = start.id }
        .onChange(of: current) { _, _ in saved = false }
        .statusBarHidden(!chrome)
    }

    /// Only build pages near the current one so huge libraries stay fast.
    private var window: [MediaItem] {
        guard let i = items.firstIndex(where: { $0.id == (current.isEmpty ? start.id : current) }) else { return [start] }
        return Array(items[max(0, i - 15)..<min(items.count, i + 16)])
    }
}

struct ZoomablePhoto: View {
    let item: MediaItem
    @EnvironmentObject var media: MediaStore
    @State private var scale: CGFloat = 1
    @State private var last: CGFloat = 1
    @State private var offset: CGSize = .zero

    var body: some View {
        RemoteImage(url: media.isLocal(item) ? nil : media.thumbURL(item, size: 2000), contentMode: .fit) {
            if media.isLocal(item), let img = UIImage(contentsOfFile: media.localURL(item).path) {
                Image(uiImage: img).resizable().aspectRatio(contentMode: .fit)
            } else {
                RemoteImage(url: media.thumbURL(item), contentMode: .fit) { ProgressView() }
            }
        }
        .scaleEffect(scale)
        .offset(offset)
        .gesture(
            MagnifyGesture()
                .onChanged { scale = max(1, last * $0.magnification) }
                .onEnded { _ in last = scale; if scale <= 1 { withAnimation(.spring) { offset = .zero } } }
                .simultaneously(with: DragGesture().onChanged { v in if scale > 1 { offset = v.translation } })
        )
        .onTapGesture(count: 2) {
            withAnimation(.spring) { scale = scale > 1 ? 1 : 2.5; last = scale; offset = .zero }
        }
    }
}

/// Streams a video straight from the PC with HTTP range requests — like YouTube.
struct StreamVideo: View {
    let url: URL
    var active: Bool
    @State private var player: AVPlayer?

    var body: some View {
        VideoPlayer(player: player)
            .onAppear { if player == nil { player = AVPlayer(url: url) } ; if active { player?.play() } }
            .onChange(of: active) { _, a in a ? player?.play() : player?.pause() }
            .onDisappear { player?.pause() }
    }
}

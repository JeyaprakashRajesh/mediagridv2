import SwiftUI
import AVKit
import Photos

struct MediaView: View {
    @EnvironmentObject var media: MediaStore
    @EnvironmentObject var conn: Connection
    @State private var filter = 0 // 0 all, 1 photos, 2 videos (PC media only), 3 this iPhone's own library
    @State private var selected: MediaItem?
    @State private var columns = 3
    @Namespace private var ns

    /// All / Photos / Videos only ever show what is on the PC (not what this iPhone backed up).
    private var list: [MediaItem] {
        let pc = media.items.filter { !$0.from_iphone }
        switch filter {
        case 1: return pc.filter { !$0.isVideo }
        case 2: return pc.filter(\.isVideo)
        default: return pc
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

                        if filter == 3 {
                            PhoneLibraryGrid(columns: columns)
                        } else {
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
                    }
                    .padding(.bottom, 60)
                }
                .refreshable { await media.refresh() }
                .trackScrollDirection()
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Text("Media").font(.title2.weight(.bold)) }
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
                    .disabled(media.syncing || conn.state != .online || filter == 3)
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
    @State private var current: String?
    @State private var chrome = true
    @State private var saved = false

    init(items: [MediaItem], start: MediaItem) {
        self.items = items; self.start = start
        _current = State(initialValue: start.id)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            // Paging scroll view: swipe left / right between every photo and video, like the Photos app.
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(items) { m in
                        Group {
                            if m.isVideo { StreamVideo(url: media.fileURL(m), active: current == m.id) }
                            else { ZoomablePhoto(item: m) }
                        }
                        .containerRelativeFrame([.horizontal, .vertical])
                        .id(m.id)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $current)
            .scrollIndicators(.hidden)
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
        .environment(\.colorScheme, .dark)
        .onChange(of: current) { _, _ in saved = false }
        .statusBarHidden(!chrome)
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
        )
        .gesture(DragGesture().onChanged { offset = $0.translation }, including: scale > 1 ? .all : .none)
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


// MARK: - This iPhone's own photos: long-press → Send to PC

struct PhoneLibraryGrid: View {
    let columns: Int
    @EnvironmentObject var photos: PhotoSync
    @EnvironmentObject var coord: Coordinator
    @EnvironmentObject var conn: Connection
    @State private var assets: PHFetchResult<PHAsset>?
    @State private var sending: Set<String> = []
    @State private var tick = 0

    private var allowed: Bool { photos.authorization == .authorized || photos.authorization == .limited }

    var body: some View {
        let _ = tick
        Group {
            if allowed, let assets {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: columns), spacing: 3) {
                    ForEach(0..<min(assets.count, 600), id: \.self) { i in
                        let a = assets[i]
                        PhoneTile(asset: a, sending: sending.contains(a.localIdentifier), sent: photos.isSent(a))
                            .contextMenu {
                                Button { send(a) } label: { Label(photos.isSent(a) ? "Send to PC again" : "Send to PC", systemImage: "paperplane") }
                                    .disabled(conn.state != .online)
                            }
                    }
                }
                .padding(.horizontal, 3)
            } else {
                ContentUnavailableView {
                    Label("Your iPhone photos", systemImage: "iphone")
                } description: {
                    Text("Allow access to pick photos and videos to send to your PC.")
                } actions: {
                    Button("Allow Photos Access") { Task { await photos.requestAccess(); load() } }.buttonStyle(.glassProminent)
                }
                .padding(.top, 60)
            }
        }
        .onAppear(perform: load)
    }

    private func load() {
        guard allowed else { return }
        let o = PHFetchOptions()
        o.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        assets = PHAsset.fetchAssets(with: o)
    }

    private func send(_ a: PHAsset) {
        let id = a.localIdentifier
        sending.insert(id)
        Task {
            do { try await photos.send(a); Haptics.success(); coord.show("Sent to PC") }
            catch { coord.show("Couldn't send: \(error.localizedDescription)") }
            sending.remove(id); tick += 1
        }
    }
}

struct PhoneTile: View {
    let asset: PHAsset
    let sending: Bool
    let sent: Bool
    @State private var image: UIImage?

    var body: some View {
        Color.gray.opacity(0.15)
            .aspectRatio(1, contentMode: .fit)
            .overlay { if let image { Image(uiImage: image).resizable().scaledToFill() } }
            .clipped()
            .overlay(alignment: .bottomLeading) {
                if asset.mediaType == .video {
                    Image(systemName: "play.fill").font(.caption2).padding(6).glassEffect(.regular, in: .circle).padding(5)
                }
            }
            .overlay(alignment: .topTrailing) {
                if sending { ProgressView().controlSize(.small).padding(6).glassEffect(.regular, in: .circle).padding(5) }
                else if sent { Image(systemName: "checkmark").font(.caption2.weight(.bold)).padding(6).glassEffect(.regular, in: .circle).padding(5) }
            }
            .contentShape(Rectangle())
            .task(id: asset.localIdentifier) { image = await thumbnail() }
    }

    private func thumbnail() async -> UIImage? {
        await withCheckedContinuation { c in
            let o = PHImageRequestOptions()
            o.deliveryMode = .highQualityFormat   // single callback
            o.resizeMode = .fast
            o.isNetworkAccessAllowed = true
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 300, height: 300), contentMode: .aspectFill, options: o) { img, _ in
                c.resume(returning: img)
            }
        }
    }
}

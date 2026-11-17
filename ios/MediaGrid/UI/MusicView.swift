import SwiftUI

/// Something you can open as a list of songs.
struct SongCollection: Hashable, Identifiable {
    var id: String
    var title: String
    var subtitle: String
    var symbol: String
    var colors: [Color]
    var tracks: [Track]
    var artTrack: Track?
    var playlist: UserPlaylist?

    static func == (a: SongCollection, b: SongCollection) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }

    init(mix: SmartMix) {
        id = mix.id; title = mix.title; subtitle = mix.subtitle; symbol = mix.symbol; colors = mix.colors; tracks = mix.tracks
    }
    init(id: String, title: String, subtitle: String, symbol: String = "music.note.list", colors: [Color], tracks: [Track], artTrack: Track? = nil, playlist: UserPlaylist? = nil) {
        self.id = id; self.title = title; self.subtitle = subtitle; self.symbol = symbol; self.colors = colors; self.tracks = tracks
        self.artTrack = artTrack; self.playlist = playlist
    }
}

struct MusicView: View {
    @EnvironmentObject var music: MusicStore
    @EnvironmentObject var player: Player
    @EnvironmentObject var conn: Connection
    @State private var search = ""
    @State private var newPlaylist = false
    @State private var playlistName = ""

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: .now)
        return h < 5 ? "Good night" : h < 12 ? "Good morning" : h < 17 ? "Good afternoon" : "Good evening"
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()
                if !search.isEmpty {
                    SongList(tracks: searchResults, source: "Search")
                } else {
                    home
                }
            }
            .navigationTitle(greeting)
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Songs, artists, albums")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { player.shuffleAll(); Haptics.soft() } label: { Image(systemName: "shuffle") }
                        .disabled(music.tracks.isEmpty)
                }
            }
            .navigationDestination(for: SongCollection.self) { CollectionView(collection: $0) }
            .refreshable { await music.refresh() }
            .alert("New Playlist", isPresented: $newPlaylist) {
                TextField("Playlist name", text: $playlistName)
                Button("Create") { if !playlistName.isEmpty { music.createPlaylist(playlistName) }; playlistName = "" }
                Button("Cancel", role: .cancel) { playlistName = "" }
            }
        }
    }

    private var searchResults: [Track] {
        let q = search.lowercased()
        return music.tracks.filter { "\($0.title) \($0.artist) \($0.album)".lowercased().contains(q) }
    }

    private var home: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                if music.tracks.isEmpty {
                    emptyState
                } else {
                    let mixes = music.mixes
                    syncCard
                    quickGrid(Array(mixes.prefix(6)))
                    if mixes.count > 1 {
                        VStack(alignment: .leading, spacing: 12) {
                            SectionHeader(title: "Made for you")
                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHStack(spacing: 14) {
                                    ForEach(mixes) { m in
                                        NavigationLink(value: SongCollection(mix: m)) { MixCard(mix: m) }.buttonStyle(.plain)
                                    }
                                }
                                .padding(.horizontal, 20)
                                .scrollTargetLayout()
                            }
                            .scrollTargetBehavior(.viewAligned)
                        }
                    }
                    playlistsSection
                    albumsSection
                    artistsSection
                    NavigationLink(value: SongCollection(id: "all", title: "All Songs", subtitle: "\(music.tracks.count) songs",
                                                         colors: [Theme.violet, Theme.cyan], tracks: music.tracks)) {
                        HStack {
                            Image(systemName: "music.note.list").font(.title2).frame(width: 52, height: 52)
                                .background(Theme.brand, in: .rect(cornerRadius: 14))
                            VStack(alignment: .leading) {
                                Text("All Songs").font(.headline)
                                Text("\(music.tracks.count) songs · \(music.downloaded.count) on iPhone").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }
                        .padding(14)
                        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 20)
                }
            }
            .padding(.vertical, 12)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: music.loading ? "arrow.triangle.2.circlepath" : "music.note.house.fill")
                .font(.system(size: 54)).foregroundStyle(Theme.brand)
                .symbolEffect(.rotate, isActive: music.loading)
            Text(music.loading ? "Loading your library…" : "No music yet").font(.title3.weight(.bold))
            Text(music.lastError ?? "Add your music folders in MediaGrid on your PC (Settings), and they'll show up here.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Refresh") { Task { await music.refresh() } }.buttonStyle(.glass)
        }
        .frame(maxWidth: .infinity).padding(40)
    }

    private var syncCard: some View {
        let pending = music.tracks.count - music.downloaded.count
        return HStack(spacing: 14) {
            ZStack {
                Circle().stroke(.white.opacity(0.12), lineWidth: 5)
                Circle().trim(from: 0, to: music.syncing ? Double(music.syncDone) / Double(max(music.syncTotal, 1))
                              : Double(music.downloaded.count) / Double(max(music.tracks.count, 1)))
                    .stroke(Theme.brand, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.smooth, value: music.syncDone)
                Image(systemName: music.syncing ? "arrow.down" : pending == 0 ? "checkmark" : "icloud.and.arrow.down")
                    .font(.headline)
                    .symbolEffect(.pulse, isActive: music.syncing)
            }
            .frame(width: 50, height: 50)
            VStack(alignment: .leading, spacing: 3) {
                Text(music.syncing ? "Syncing \(music.syncDone) of \(music.syncTotal)" : pending == 0 ? "All music on iPhone" : "\(pending) songs stream from PC")
                    .font(.headline)
                Text(music.syncing ? "Downloading for offline play" : pending == 0 ? "Plays even when your PC is off" : "Tap Sync to keep them for offline play")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if music.syncing {
                Button("Stop") { music.cancelSync() }.buttonStyle(.glass)
            } else if pending > 0 {
                Button("Sync") { music.syncAll(); Haptics.tap() }.buttonStyle(.glassProminent).tint(Theme.violet)
                    .disabled(conn.state != .online)
            }
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .padding(.horizontal, 20)
    }

    private func quickGrid(_ mixes: [SmartMix]) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            ForEach(mixes) { m in
                NavigationLink(value: SongCollection(mix: m)) {
                    HStack(spacing: 10) {
                        ZStack {
                            LinearGradient(colors: m.colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                            Image(systemName: m.symbol).font(.headline).foregroundStyle(.white)
                        }
                        .frame(width: 50, height: 50)
                        .clipShape(.rect(cornerRadius: 12))
                        Text(m.title).font(.footnote.weight(.bold)).lineLimit(2).multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .padding(6)
                    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 16))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
    }

    private var playlistsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Your playlists", action: "New") { newPlaylist = true }
            if music.playlists.isEmpty {
                Button { newPlaylist = true } label: {
                    Label("Create your first playlist", systemImage: "plus").font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 18)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 20))
                .padding(.horizontal, 20)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 14) {
                        ForEach(music.playlists) { p in
                            let ts = music.tracks(for: p)
                            NavigationLink(value: SongCollection(id: "pl-\(p.id)", title: p.name, subtitle: "\(ts.count) songs",
                                                                 colors: Theme.palettes[abs(p.name.count) % Theme.palettes.count], tracks: ts, artTrack: ts.first, playlist: p)) {
                                VStack(alignment: .leading, spacing: 6) {
                                    CoverGrid(tracks: Array(ts.prefix(4)), size: 140)
                                    Text(p.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                                    Text("\(ts.count) songs").font(.caption).foregroundStyle(.secondary)
                                }
                                .frame(width: 140)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 20)
                }
            }
        }
    }

    private var albumsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Albums")
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(music.albums.prefix(30)) { a in
                        NavigationLink(value: SongCollection(id: "al-\(a.name)", title: a.name, subtitle: a.artist,
                                                             colors: [Theme.violet, Theme.pink], tracks: a.tracks, artTrack: a.tracks.first)) {
                            VStack(alignment: .leading, spacing: 6) {
                                ArtworkView(track: a.tracks.first, size: 140, radius: 16).cardShadow()
                                Text(a.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                                Text(a.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .frame(width: 140)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    private var artistsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Artists")
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 16) {
                    ForEach(music.artists.prefix(30)) { a in
                        NavigationLink(value: SongCollection(id: "ar-\(a.name)", title: a.name, subtitle: "\(a.tracks.count) songs",
                                                             colors: [Theme.cyan, Theme.violet], tracks: a.tracks, artTrack: a.tracks.first(where: { $0.has_art }))) {
                            VStack(spacing: 8) {
                                ArtworkView(track: a.tracks.first(where: { $0.has_art }) ?? a.tracks.first, size: 104, radius: 52).cardShadow()
                                Text(a.name).font(.footnote.weight(.semibold)).lineLimit(1)
                            }
                            .frame(width: 104)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }
}

struct MixCard: View {
    let mix: SmartMix
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomLeading) {
                LinearGradient(colors: mix.colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                CoverGrid(tracks: Array(mix.tracks.filter(\.has_art).prefix(4)), size: 170).opacity(0.35).blendMode(.overlay)
                Image(systemName: mix.symbol).font(.system(size: 64, weight: .bold)).foregroundStyle(.white.opacity(0.18))
                    .offset(x: 90, y: -60)
                Text(mix.title).font(.title3.weight(.heavy)).foregroundStyle(.white).padding(14)
            }
            .frame(width: 170, height: 170)
            .clipShape(.rect(cornerRadius: 22))
            .cardShadow()
            Text(mix.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2).frame(width: 170, alignment: .leading)
        }
    }
}

struct CoverGrid: View {
    let tracks: [Track]
    let size: CGFloat
    var body: some View {
        Group {
            if tracks.count >= 4 {
                VStack(spacing: 0) {
                    HStack(spacing: 0) { ArtworkView(track: tracks[0], size: size / 2, radius: 0); ArtworkView(track: tracks[1], size: size / 2, radius: 0) }
                    HStack(spacing: 0) { ArtworkView(track: tracks[2], size: size / 2, radius: 0); ArtworkView(track: tracks[3], size: size / 2, radius: 0) }
                }
            } else {
                ArtworkView(track: tracks.first, size: size, radius: 0)
            }
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: 16))
    }
}

// MARK: - Collection (playlist / mix / album / artist)

struct CollectionView: View {
    let collection: SongCollection
    @EnvironmentObject var music: MusicStore
    @EnvironmentObject var player: Player
    @Environment(\.dismiss) private var dismiss
    @State private var sort = 0

    private var tracks: [Track] {
        if let p = collection.playlist { return music.tracks(for: p) }
        switch sort {
        case 1: return collection.tracks.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case 2: return collection.tracks.sorted { $0.added > $1.added }
        default: return collection.tracks
        }
    }

    var body: some View {
        let ts = tracks
        ScrollView {
            VStack(spacing: 18) {
                // header art
                ZStack {
                    if collection.artTrack != nil {
                        ArtworkView(track: collection.artTrack, size: 230, radius: 26)
                    } else {
                        ZStack {
                            LinearGradient(colors: collection.colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                            Image(systemName: collection.symbol).font(.system(size: 80, weight: .bold)).foregroundStyle(.white.opacity(0.9))
                        }
                        .frame(width: 230, height: 230).clipShape(.rect(cornerRadius: 26))
                    }
                }
                .shadow(color: (collection.colors.first ?? .black).opacity(0.5), radius: 40, y: 20)
                .padding(.top, 10)

                VStack(spacing: 4) {
                    Text(collection.title).font(.title.weight(.heavy)).multilineTextAlignment(.center)
                    Text("\(collection.subtitle) · \(ts.count) songs · \(Int(ts.reduce(0) { $0 + $1.duration } / 60)) min")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding(.horizontal)

                GlassEffectContainer(spacing: 12) {
                    HStack(spacing: 12) {
                        Button { player.play(ts, shuffle: false, source: collection.title) } label: {
                            Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity).padding(.vertical, 4)
                        }
                        .buttonStyle(.glassProminent).tint(Theme.violet)
                        Button { player.play(ts, shuffle: true, source: collection.title) } label: {
                            Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity).padding(.vertical, 4)
                        }
                        .buttonStyle(.glass)
                        let pending = ts.filter { !music.isDownloaded($0) }
                        Button { music.syncAll(ts); Haptics.tap() } label: {
                            Image(systemName: pending.isEmpty ? "checkmark.circle.fill" : "arrow.down.circle").font(.title3).padding(.vertical, 2)
                        }
                        .buttonStyle(.glass).disabled(pending.isEmpty || music.syncing)
                    }
                    .controlSize(.large)
                }
                .padding(.horizontal, 20)

                LazyVStack(spacing: 2) {
                    ForEach(ts) { t in
                        TrackRow(track: t, playlist: collection.playlist) { player.play(ts, start: t, shuffle: false, source: collection.title) }
                    }
                }
                .padding(.horizontal, 12)
            }
            .padding(.bottom, 60)
        }
        .scrollIndicators(.hidden)
        .background(
            ZStack {
                Theme.ink
                LinearGradient(colors: [(collection.colors.first ?? Theme.violet).opacity(0.55), .clear], startPoint: .top, endPoint: .center)
            }
            .ignoresSafeArea()
        )
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if collection.playlist == nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Sort", selection: $sort) {
                            Text("Default").tag(0); Text("Title").tag(1); Text("Recently added").tag(2)
                        }
                    } label: { Image(systemName: "arrow.up.arrow.down") }
                }
            } else if let p = collection.playlist {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) { music.deletePlaylist(p); dismiss() } label: { Image(systemName: "trash") }
                }
            }
        }
    }
}

struct SongList: View {
    let tracks: [Track]
    let source: String
    @EnvironmentObject var player: Player
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                if tracks.isEmpty {
                    ContentUnavailableView.search
                }
                ForEach(tracks) { t in
                    TrackRow(track: t) { player.play(tracks, start: t, shuffle: false, source: source) }
                }
            }
            .padding(.horizontal, 12).padding(.bottom, 60)
        }
    }
}

struct TrackRow: View {
    let track: Track
    var playlist: UserPlaylist? = nil
    let onTap: () -> Void
    @EnvironmentObject var music: MusicStore
    @EnvironmentObject var player: Player

    var body: some View {
        let isCurrent = player.current?.id == track.id
        Button(action: onTap) {
            HStack(spacing: 12) {
                ArtworkView(track: track, size: 48, radius: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title).font(.body.weight(.semibold)).lineLimit(1)
                        .foregroundStyle(isCurrent ? Theme.violet : .primary)
                    HStack(spacing: 5) {
                        if music.isDownloaded(track) {
                            Image(systemName: "arrow.down.circle.fill").font(.caption2).foregroundStyle(Theme.mint)
                        }
                        Text(track.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                if isCurrent { EqualizerBars(playing: player.isPlaying) }
                if music.liked.contains(track.id) { Image(systemName: "heart.fill").font(.caption).foregroundStyle(Theme.pink) }
                Menu {
                    menuItems
                } label: {
                    Image(systemName: "ellipsis").frame(width: 34, height: 40).contentShape(Rectangle())
                }
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(isCurrent ? Theme.violet.opacity(0.12) : .clear, in: .rect(cornerRadius: 14))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { menuItems }
    }

    @ViewBuilder private var menuItems: some View {
        Button { player.playNext(track) } label: { Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") }
        Button { player.addToQueue(track) } label: { Label("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward") }
        Button { music.toggleLike(track) } label: {
            Label(music.liked.contains(track.id) ? "Remove from Liked" : "Like", systemImage: music.liked.contains(track.id) ? "heart.slash" : "heart")
        }
        Menu {
            ForEach(music.playlists) { p in Button(p.name) { music.add(track, to: p) } }
            Button { music.createPlaylist(track.title, tracks: [track.id]) } label: { Label("New Playlist", systemImage: "plus") }
        } label: { Label("Add to Playlist", systemImage: "music.note.list") }
        if let playlist {
            Button(role: .destructive) { music.removeFromPlaylist(track, playlist) } label: { Label("Remove from Playlist", systemImage: "minus.circle") }
        }
        Divider()
        if music.isDownloaded(track) {
            Button(role: .destructive) { music.remove(track) } label: { Label("Remove Download", systemImage: "trash") }
        } else {
            Button { Task { try? await music.download(track) } } label: { Label("Download", systemImage: "arrow.down.circle") }
        }
    }
}

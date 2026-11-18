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
    @ObservedObject private var ui = UIState.shared
    @FocusState private var searchFocused: Bool
    @ObservedObject private var tint = TintStore.shared
    @State private var search = ""
    @State private var newPlaylist = false
    @State private var playlistName = ""

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: .now)
        return h < 5 ? "Good night" : h < 12 ? "Good morning" : h < 17 ? "Good afternoon" : "Good evening"
    }

    var body: some View {
        NavigationStack(path: $ui.musicPath) {
            ZStack {
                AppBackground()
                recentGlow
                VStack(spacing: 12) {
                    header
                    searchField
                    if !search.isEmpty {
                        SongList(tracks: searchResults, source: "Search")
                    } else {
                        home
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button { searchFocused = false } label: { Image(systemName: "keyboard.chevron.compact.down") }
                }
            }
            .navigationDestination(for: SongCollection.self) { CollectionView(collection: $0) }
            .refreshable { await music.refresh() }
            .tint(tint.color)
            .alert("New Playlist", isPresented: $newPlaylist) {
                TextField("Playlist name", text: $playlistName)
                Button("Create") { if !playlistName.isEmpty { music.createPlaylist(playlistName) }; playlistName = "" }
                Button("Cancel", role: .cancel) { playlistName = "" }
            }
        }
    }

    /// Soft wash at the top of the Music screen in the colour of the song playing (eases between songs).
    private var recentGlow: some View {
        VStack(spacing: 0) {
            Rectangle().fill(tint.color.opacity(0.5)).frame(height: 360)
                .mask(LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom))
            Spacer()
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    /// Greeting on the left; sync + shuffle on the right of the same row.
    private var header: some View {
        HStack(spacing: 10) {
            Text(greeting).font(.largeTitle.weight(.bold)).lineLimit(1).minimumScaleFactor(0.6)
            Spacer(minLength: 8)
            syncButton.frame(width: 46, height: 46).glassEffect(.regular.interactive(), in: .circle)
            Button { player.shuffleAll(); Haptics.soft() } label: { Image(systemName: "shuffle").frame(width: 46, height: 46) }
                .glassEffect(.regular.interactive(), in: .circle)
                .disabled(music.tracks.isEmpty)
        }
        .padding(.horizontal, 20).padding(.top, 6)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Songs, artists, albums", text: $search).submitLabel(.search).focused($searchFocused)
            if !search.isEmpty {
                Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal, 20)
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
                    let cards = madeForYou(music.mixes)
                    recentSection
                    if !cards.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            SectionHeader(title: "Made for you")
                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHStack(spacing: 14) {
                                    ForEach(cards) { c in
                                        NavigationLink(value: c) {
                                            VStack(alignment: .leading, spacing: 8) {
                                                MixArt(colors: c.colors, tracks: c.tracks, symbol: c.symbol, title: c.title, size: 170).cardShadow()
                                                Text(c.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2).frame(width: 170, alignment: .leading)
                                            }
                                        }
                                        .buttonStyle(.plain)
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
                }
            }
            .padding(.vertical, 12)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
    }

    /// Mixes + "All Songs" right after Recently Added. (Downloaded lives under My playlists.)
    private func madeForYou(_ mixes: [SmartMix]) -> [SongCollection] {
        var out = mixes.filter { $0.id != "offline" }.map { SongCollection(mix: $0) }
        if let all = music.collection(id: "all") {
            out.insert(all, at: out.firstIndex { $0.id == "recent" }.map { $0 + 1 } ?? 0)
        }
        return out
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: music.loading ? "arrow.triangle.2.circlepath" : "music.note.house.fill")
                .font(.system(size: 54)).foregroundStyle(tint.color)
                .symbolEffect(.rotate, isActive: music.loading)
            Text(music.loading ? "Loading your library…" : "No music yet").font(.title3.weight(.bold))
            Text(music.lastError ?? "Add your music folders in MediaGrid on your PC (Settings), and they'll show up here.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Refresh") { Task { await music.refresh() } }.buttonStyle(.glass)
        }
        .frame(maxWidth: .infinity).padding(40)
    }

    /// Sync lives next to shuffle in the top bar; the ring shows progress while downloading.
    private var syncButton: some View {
        let pending = music.tracks.count - music.downloaded.count
        return Button {
            if music.syncing { music.cancelSync() } else { music.syncAll(); Haptics.tap() }
        } label: {
            ZStack {
                if music.syncing {
                    Circle().stroke(.secondary.opacity(0.3), lineWidth: 2.5)
                    Circle().trim(from: 0, to: Double(music.syncDone) / Double(max(music.syncTotal, 1)))
                        .stroke(tint.color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round)).rotationEffect(.degrees(-90))
                        .animation(.smooth, value: music.syncDone)
                    Image(systemName: "xmark").font(.caption2.weight(.bold))
                } else {
                    Image(systemName: pending == 0 ? "checkmark.icloud" : "icloud.and.arrow.down")
                }
            }
            .frame(width: 22, height: 22)
        }
        .disabled(!music.syncing && (pending == 0 || conn.state != .online))
        .accessibilityLabel(music.syncing ? "Stop sync" : "Sync \(pending) songs for offline")
    }

    /// Currently playing (when something is on) or the last song you played. Tap the card for the song page;
    /// the round button plays / pauses without restarting.
    @ViewBuilder private var recentSection: some View {
        let recent = music.recentlyPlayed
        let playing = player.current
        if let item = playing.map({ (track: $0, at: Date(), pos: player.time) }) ?? recent.first {
            let list = recent.map(\.track)
            let isCurrent = player.current?.id == item.track.id
            let src = isCurrent ? player.source : (UserDefaults.standard.string(forKey: "mg.lastSource") ?? "")
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: playing != nil ? "Currently playing" : "Recently played")
                HStack(spacing: 16) {
                    ArtworkView(track: item.track, size: 116, radius: 22).cardShadow()
                    VStack(alignment: .leading, spacing: 5) {
                        Text(item.track.title).font(.title3.weight(.bold)).lineLimit(2)
                        Text(item.track.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        if !src.isEmpty {
                            Label(src, systemImage: "music.note.list").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        if !isCurrent {
                            Label(item.pos > 3 ? "\(item.at.relative) · resume \(item.pos.mmss)" : item.at.relative, systemImage: "clock")
                                .font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        if isCurrent { player.toggle() } else { player.playRecent(item.track, in: list, pos: item.pos) }
                        Haptics.tap()
                    } label: {
                        Image(systemName: isCurrent && player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title3).foregroundStyle(.white)
                            .contentTransition(.symbolEffect(.replace))
                            .frame(width: 48, height: 48)
                            .background(tint.color, in: .circle)
                    }
                    .buttonStyle(.plain)
                }
                .padding(14)
                .glassEffect(Glass.regular.tint(tint.color.opacity(0.4)).interactive(), in: .rect(cornerRadius: 30))
                .contentShape(.rect(cornerRadius: 30))
                .onTapGesture {
                    if !isCurrent { player.playRecent(item.track, in: list, pos: item.pos) }
                    ui.openPlayer()
                }
                .padding(.horizontal, 20)
            }
        }
    }

    private var playlistsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "My playlists", action: music.playlists.isEmpty ? nil : "New") { newPlaylist = true }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    if let d = music.collection(id: "offline"), !d.tracks.isEmpty {
                        NavigationLink(value: d) {
                            VStack(alignment: .leading, spacing: 8) {
                                MixArt(colors: d.colors, tracks: d.tracks, symbol: d.symbol, title: d.title, size: 170).cardShadow()
                                Text("\(d.tracks.count) songs").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    if music.playlists.isEmpty {
                        addPlaylistTile
                    }
                    ForEach(music.playlists) { p in
                        let ts = music.tracks(for: p)
                        NavigationLink(value: SongCollection(id: "pl-\(p.id)", title: p.name, subtitle: "\(ts.count) songs",
                                                             colors: [Theme.pick(p.name)], tracks: ts, artTrack: ts.first, playlist: p)) {
                            VStack(alignment: .leading, spacing: 8) {
                                ZStack {
                                    if ts.isEmpty {
                                        Theme.pick(p.name).opacity(0.25)
                                        Image(systemName: "music.note.list").font(.system(size: 44)).foregroundStyle(Theme.pick(p.name))
                                    } else {
                                        CoverGrid(tracks: Array(ts.prefix(4)), size: 170)
                                    }
                                }
                                .frame(width: 170, height: 170).clipShape(.rect(cornerRadius: 22)).cardShadow()
                                Text(p.name).font(.subheadline.weight(.semibold)).lineLimit(1).frame(width: 170, alignment: .leading)
                                Text("\(ts.count) songs").font(.caption).foregroundStyle(.secondary).offset(y: -4)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    private var addPlaylistTile: some View {
        Button { newPlaylist = true } label: {
            VStack(spacing: 8) {
                Image(systemName: "plus").font(.title.weight(.semibold))
                Text("New playlist").font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(.secondary)
            .frame(width: 170, height: 170)
            .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.secondary.opacity(0.45), style: StrokeStyle(lineWidth: 1.5, dash: [7, 6])))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var albumsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Albums")
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(music.albums.prefix(30)) { a in
                        NavigationLink(value: SongCollection(id: "al-\(a.name)", title: a.name, subtitle: a.artist,
                                                             colors: [Theme.pick(a.name)], tracks: a.tracks, artTrack: a.tracks.first)) {
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
                                                             colors: [Theme.pick(a.name)], tracks: a.tracks, artTrack: a.tracks.first(where: { $0.has_art }))) {
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

/// The poster you see on the home screen (colour + artwork collage + title), at any size.
struct MixArt: View {
    let colors: [Color]
    let tracks: [Track]
    let symbol: String
    let title: String
    let size: CGFloat

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            colors.first ?? Theme.accent
            CoverGrid(tracks: Array(tracks.filter(\.has_art).prefix(4)), size: size).opacity(0.35).blendMode(.overlay)
            Image(systemName: symbol).font(.system(size: size * 0.38, weight: .bold)).foregroundStyle(.white.opacity(0.18))
                .offset(x: size * 0.53, y: -size * 0.35)
            Text(title).font(size > 200 ? .largeTitle.weight(.heavy) : .title3.weight(.heavy)).foregroundStyle(.white)
                .lineLimit(2).minimumScaleFactor(0.7).padding(size * 0.08)
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: size * 0.13))
    }
}

struct MixCard: View {
    let mix: SmartMix
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MixArt(colors: mix.colors, tracks: mix.tracks, symbol: mix.symbol, title: mix.title, size: 170).cardShadow()
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
    @ObservedObject private var tint = TintStore.shared
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
                // header art: the same poster as on the home screen
                Group {
                    if collection.playlist != nil {
                        if ts.isEmpty {
                            ZStack {
                                collection.colors.first?.opacity(0.25) ?? Theme.accent.opacity(0.25)
                                Image(systemName: "music.note.list").font(.system(size: 70)).foregroundStyle(collection.colors.first ?? Theme.accent)
                            }
                            .frame(width: 250, height: 250).clipShape(.rect(cornerRadius: 32))
                        } else {
                            CoverGrid(tracks: Array(ts.prefix(4)), size: 250).clipShape(.rect(cornerRadius: 32))
                        }
                    } else if collection.artTrack != nil {
                        ArtworkView(track: collection.artTrack, size: 250, radius: 32)
                    } else {
                        MixArt(colors: collection.colors, tracks: ts, symbol: collection.symbol, title: collection.title, size: 250)
                    }
                }
                .shadow(color: (collection.colors.first ?? Theme.accent).opacity(0.45), radius: 34, y: 18)
                .padding(.top, 10)

                VStack(spacing: 4) {
                    Text(collection.title).font(.title.weight(.heavy)).multilineTextAlignment(.center)
                    Text(collection.subtitle).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center).lineLimit(2)
                    Text("\(ts.count) songs · \(Int(ts.reduce(0) { $0 + $1.duration } / 60)) min")
                        .font(.footnote.weight(.medium)).foregroundStyle(.tertiary)
                }
                .padding(.horizontal)

                GlassEffectContainer(spacing: 12) {
                    HStack(spacing: 12) {
                        let here = player.collectionID == collection.id && player.current != nil
                        Button {
                            if here { player.toggle() } else { player.play(ts, shuffle: false, source: collection.title, collectionID: collection.id) }
                            Haptics.soft()
                        } label: {
                            Label(here && player.isPlaying ? "Pause" : "Play", systemImage: here && player.isPlaying ? "pause.fill" : "play.fill")
                                .contentTransition(.symbolEffect(.replace))
                                .frame(maxWidth: .infinity).padding(.vertical, 4)
                        }
                        .buttonStyle(.glassProminent).tint(tint.color).foregroundStyle(.white)
                        Button { player.play(ts, shuffle: true, source: collection.title, collectionID: collection.id); Haptics.soft() } label: {
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
                        TrackRow(track: t, playlist: collection.playlist) { player.play(ts, start: t, shuffle: false, source: collection.title, collectionID: collection.id) }
                    }
                }
                .padding(8)
                .background(.thinMaterial, in: .rect(cornerRadius: 26))
                .padding(.horizontal, 14)
            }
            .padding(.bottom, 60)
        }
        .scrollIndicators(.hidden)
        .background(Theme.ink.ignoresSafeArea())
        .tint(tint.color)
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
        .scrollDismissesKeyboard(.interactively)
    }
}

struct TrackRow: View {
    let track: Track
    var playlist: UserPlaylist? = nil
    let onTap: () -> Void
    @EnvironmentObject var music: MusicStore
    @EnvironmentObject var player: Player
    @ObservedObject private var tint = TintStore.shared

    var body: some View {
        let isCurrent = player.current?.id == track.id
        Button { if isCurrent { UIState.shared.openPlayer() } else { onTap() } } label: {
            HStack(spacing: 12) {
                ArtworkView(track: track, size: 48, radius: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title).font(.body.weight(.semibold)).lineLimit(1)
                        .foregroundStyle(isCurrent ? tint.color : .primary)
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
            .background(isCurrent ? tint.color.opacity(0.28) : .clear, in: .rect(cornerRadius: 14))
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

extension MusicStore {
    /// Rebuild a playlist / mix / album page from its id (used by "Go to playlist").
    func collection(id: String) -> SongCollection? {
        let grey = [Color(hex: 0x7345C9)]
        if id == "all" {
            return SongCollection(id: "all", title: "All Songs", subtitle: "\(tracks.count) songs", symbol: "music.note.list", colors: grey, tracks: tracks)
        }
        if id == "offline" {
            let ts = tracks.filter { downloaded.contains($0.id) }
            return SongCollection(id: "offline", title: "Downloaded", subtitle: "Plays without your PC", symbol: "arrow.down.circle.fill", colors: [Color(hex: 0x2F8F5B)], tracks: ts)
        }
        if id.hasPrefix("pl-"), let p = playlists.first(where: { "pl-\($0.id)" == id }) {
            let ts = tracks(for: p)
            return SongCollection(id: id, title: p.name, subtitle: "\(ts.count) songs", colors: [Theme.pick(p.name)], tracks: ts, artTrack: ts.first, playlist: p)
        }
        if id.hasPrefix("al-"), let a = albums.first(where: { "al-\($0.name)" == id }) {
            return SongCollection(id: id, title: a.name, subtitle: a.artist, colors: [Theme.pick(a.name)], tracks: a.tracks, artTrack: a.tracks.first)
        }
        if id.hasPrefix("ar-"), let a = artists.first(where: { "ar-\($0.name)" == id }) {
            return SongCollection(id: id, title: a.name, subtitle: "\(a.tracks.count) songs", colors: [Theme.pick(a.name)], tracks: a.tracks, artTrack: a.tracks.first(where: { $0.has_art }))
        }
        return mixes.first(where: { $0.id == id }).map { SongCollection(mix: $0) }
    }
}

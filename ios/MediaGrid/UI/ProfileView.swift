import SwiftUI
import UniformTypeIdentifiers

struct ProfileView: View {
    @EnvironmentObject var conn: Connection
    @EnvironmentObject var music: MusicStore
    @EnvironmentObject var media: MediaStore
    @EnvironmentObject var photos: PhotoSync
    @EnvironmentObject var clip: ClipboardSync
    @EnvironmentObject var player: Player
    @AppStorage("mg.liveActivity") private var liveActivity = true
    @AppStorage("mg.appearance") private var appearance = 0
    @AppStorage("mg.autoplayGenre") private var autoplayGenre = true
    @AppStorage("mg.rankMethod") private var rankMethod = 0
    @AppStorage("mg.bridgePC") private var bridgePC = false
    @AppStorage("mg.autoDownload") private var autoDownload = false
    @ObservedObject private var streamer = PhoneStreamer.shared
    @ObservedObject private var bridge = AudioBridge.shared
    @State private var editingHost = false
    @State private var newHost = ""
    @State private var confirmSignOut = false
    @State private var pickingMusic = false
    @State private var uploadStatus: String?

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()
                ScrollView {
                    VStack(spacing: 22) {
                        header
                        connectionSection
                        backupSection
                        musicSection
                        audioSection
                        preferencesSection
                        storageSection
                        Button(role: .destructive) { confirmSignOut = true } label: {
                            Text("Sign out").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
                        }
                        .buttonStyle(.glass)
                        Text("MediaGrid \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 60)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .fileImporter(isPresented: $pickingMusic, allowedContentTypes: [.audio], allowsMultipleSelection: true) { r in
                if case .success(let urls) = r, !urls.isEmpty { uploadSongs(urls) }
            }
            .confirmationDialog("Sign out of MediaGrid?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("Sign out", role: .destructive) { conn.signOut() }
            } message: { Text("Downloaded music stays on your iPhone.") }
            .alert("PC address", isPresented: $editingHost) {
                TextField("100.x.x.x:47800", text: $newHost).textInputAutocapitalization(.never)
                Button("Use") {
                    let h = Connection.normalize(newHost)
                    Task {
                        if await conn.ping(h) != nil {
                            conn.host = h; conn.remember(h)
                            UserDefaults.standard.set(h, forKey: "mg.host")
                            conn.connect()
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: { Text("Your PC's Wi-Fi or Tailscale address, shown in MediaGrid → Profile on the PC.") }
        }
    }

    // MARK: header

    private var header: some View {
        let online = conn.state == .online
        return VStack(spacing: 14) {
            Text(String(conn.email.prefix(2)).uppercased())
                .font(.system(size: 30, weight: .bold, design: .rounded)).foregroundStyle(.white)
                .frame(width: 84, height: 84)
                .background(LinearGradient(colors: [Theme.accent, Theme.pink], startPoint: .topLeading, endPoint: .bottomTrailing), in: .circle)
            VStack(spacing: 6) {
                Text(conn.email).font(.headline)
                HStack(spacing: 7) {
                    Circle().fill(online ? Color.green : Color.red).frame(width: 8, height: 8)
                    Text(online ? "Connected to \(conn.pcName)" : conn.state == .connecting ? "Connecting to \(conn.pcName)…" : "\(conn.pcName) is offline")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 10) {
                stat("\(music.tracks.count)", "Songs", "music.note", Theme.pink)
                stat("\(media.items.count)", "PC media", "photo", Theme.cyan)
                stat("\(music.downloaded.count)", "Offline", "arrow.down.circle", Theme.mint)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    private func stat(_ v: String, _ l: String, _ icon: String, _ c: Color) -> some View {
        VStack(spacing: 6) {
            IconBadge(symbol: icon, color: c, size: 28)
            Text(v).font(.title3.weight(.bold)).contentTransition(.numericText())
            Text(l).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 14)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }

    // MARK: sections

    private var connectionSection: some View {
        section("Connection") {
            row("desktopcomputer", Theme.cyan, "PC") { value(conn.pcName) }
            row(conn.host.hasPrefix("100.") ? "lock.shield.fill" : "wifi", Theme.mint, conn.host.hasPrefix("100.") ? "Tailscale" : "Wi-Fi") { value(conn.host) }
            ForEach(conn.discovered) { pc in
                Button {
                    conn.host = "\(pc.host):\(pc.port)"; conn.remember(conn.host)
                    UserDefaults.standard.set(conn.host, forKey: "mg.host")
                    conn.connect()
                } label: {
                    row("dot.radiowaves.left.and.right", Theme.accent, pc.name) {
                        if conn.host == "\(pc.host):\(pc.port)" { Image(systemName: "checkmark").foregroundStyle(Theme.mint) } else { value(pc.host) }
                    }
                }
                .buttonStyle(.plain)
            }
            HStack {
                Button("Change address") { newHost = conn.host; editingHost = true }.buttonStyle(.glass)
                Spacer()
                Button("Reconnect") { conn.connect() }.buttonStyle(.glass)
            }
            .font(.subheadline.weight(.semibold)).padding(12)
        }
    }

    private var backupSection: some View {
        section("Photo backup") {
            row("photo.stack", Theme.pink, "Back up to PC") {
                Button {
                    Task { await photos.syncNow() }
                    Haptics.tap()
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath").symbolEffect(.rotate, isActive: photos.running)
                }
                .buttonStyle(.glassProminent).tint(Theme.accent).foregroundStyle(.white)
                .disabled(photos.running || conn.state != .online)
            }
            Text(photos.running ? photos.status : photos.lastSync.map { "Last backup \($0.relative)" } ?? "Not backed up yet")
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.bottom, 6)
            if photos.running && photos.total > 0 {
                ProgressView(value: Double(photos.done), total: Double(photos.total)).tint(Theme.accent).padding(.horizontal, 14).padding(.bottom, 10)
            }
            toggleRow("arrow.clockwise.icloud", Theme.accent, "Back up automatically", $photos.auto)
            toggleRow("video", Theme.cyan, "Include videos", $photos.includeVideos)
        }
    }

    /// Pick one song or many; they are copied to the PC's music folder as the original files.
    private var musicSection: some View {
        section("Music") {
            Button { pickingMusic = true } label: {
                row("square.and.arrow.up", Theme.accent, "Upload songs to PC") {
                    if uploadStatus != nil { ProgressView() } else { Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary) }
                }
            }
            .buttonStyle(.plain).disabled(conn.state != .online || uploadStatus != nil)
            Text(uploadStatus ?? "Choose one or several audio files. They are saved in your PC's music folder.")
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.bottom, 10)
        }
    }

    private func uploadSongs(_ urls: [URL]) {
        Task {
            var done = 0
            for (i, u) in urls.enumerated() {
                uploadStatus = "Uploading \(i + 1) of \(urls.count)…"
                let ok = u.startAccessingSecurityScopedResource()
                defer { if ok { u.stopAccessingSecurityScopedResource() } }
                do { try await conn.upload("/api/music/upload", query: ["name": u.lastPathComponent, "rescan": "0"], file: u); done += 1 } catch {}
            }
            try? await conn.post("/api/rescan", json: [String: String]())
            uploadStatus = nil
            Coordinator.shared.show(done == urls.count ? "Uploaded \(done) song\(done == 1 ? "" : "s")" : "Uploaded \(done) of \(urls.count)")
            Haptics.success()
            try? await Task.sleep(for: .seconds(2))
            await music.refresh()
        }
    }

    /// PC sound on the iPhone, and the iPhone mic on the PC. Both ride on Wi-Fi / Tailscale through the app.
    private var audioSection: some View {
        section("Audio bridge") {
            toggleRow("speaker.wave.2.fill", Theme.cyan, "Hear PC sound on iPhone", $bridgePC)
                .onChange(of: bridgePC) { _, _ in AudioBridge.shared.apply() }
            if let n = bridge.note, bridgePC {
                Text(n).font(.caption).foregroundStyle(Theme.pink).padding(.horizontal, 14).padding(.bottom, 6)
            }
            row("mic.fill", Theme.pink, "Share iPhone mic with PC") {
                Toggle("", isOn: Binding(get: { streamer.running }, set: { on in
                    Task { if on { await streamer.start(camera: false, mic: true, back: false) } else { await streamer.stop() } }
                })).labelsHidden().tint(Theme.accent)
            }
            Text("PC sound keeps playing when you leave the app, but stops if you swipe MediaGrid away: iOS never lets an app run after that. Bluetooth can't send PC sound to an iPhone, and iOS doesn't let apps capture other apps' sound. To send everything the iPhone plays to the PC with no app open, connect the iPhone to a Bluetooth audio receiver or an AirPlay receiver app on the PC.")
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.bottom, 10)
        }
    }

    private var preferencesSection: some View {
        section("Preferences") {
            row("circle.lefthalf.filled", Theme.accent, "Appearance") {
                Picker("Theme", selection: $appearance) {
                    Text("Auto").tag(0); Text("Light").tag(1); Text("Dark").tag(2)
                }
                .pickerStyle(.segmented).frame(width: 190)
            }
            toggleRow("doc.on.clipboard", Theme.cyan, "Universal clipboard", $clip.auto)
            toggleRow("platter.filled.top.iphone", Theme.pink, "Dynamic Island & Lock Screen", $liveActivity)
            toggleRow("shuffle", Theme.mint, "Shuffle by default", $player.shuffle)
            toggleRow("arrow.down.circle", Theme.cyan, "Auto-download favourites (Wi-Fi + charging)", $autoDownload)
            Button { Task { await music.fetchCovers(force: true) } } label: {
                HStack { Label("Fetch movie posters", systemImage: "photo.on.rectangle.angled"); Spacer(); Text(music.coverStatus).font(.caption).foregroundStyle(.secondary) }
            }
            toggleRow("dot.radiowaves.left.and.right", Theme.accent, "Autoplay similar songs", $autoplayGenre)
            row("chart.bar.fill", Theme.cyan, "Song ranking") {
                Picker("Song ranking", selection: $rankMethod) {
                    Text("Both").tag(0); Text("My plays").tag(1); Text("Popularity").tag(2)
                }
                .pickerStyle(.menu).tint(.secondary)
                .onChange(of: rankMethod) { _, _ in Task { await music.refresh() } }
            }
        }
    }

    private var storageSection: some View {
        section("Storage on iPhone") {
            row("music.note", Theme.pink, "Offline music") { value(music.downloadedBytes.byteString) }
            row("photo", Theme.cyan, "Offline PC media") { value(media.localBytes.byteString) }
            HStack {
                Button("Clear music", role: .destructive) { music.removeAllDownloads() }.buttonStyle(.glass)
                Spacer()
                Button("Clear media", role: .destructive) { media.clearLocal(); Task { await ImageCache.shared.clear() } }.buttonStyle(.glass)
            }
            .font(.subheadline.weight(.semibold)).padding(12)
        }
    }

    // MARK: building blocks

    /// Small caption heading above one rounded container of rows.
    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.leading, 12)
            VStack(spacing: 0) { content() }
                .glassEffect(.regular, in: .rect(cornerRadius: 24))
        }
    }

    private func row<T: View>(_ icon: String, _ color: Color, _ title: String, @ViewBuilder trailing: () -> T) -> some View {
        HStack(spacing: 12) {
            IconBadge(symbol: icon, color: color, size: 30)
            Text(title).font(.subheadline)
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private func toggleRow(_ icon: String, _ color: Color, _ title: String, _ on: Binding<Bool>) -> some View {
        row(icon, color, title) { Toggle("", isOn: on).labelsHidden().tint(Theme.accent) }
    }

    private func value(_ s: String) -> some View {
        Text(s).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1).textSelection(.enabled)
    }
}

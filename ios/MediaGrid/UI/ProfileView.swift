import SwiftUI

struct ProfileView: View {
    @EnvironmentObject var conn: Connection
    @EnvironmentObject var music: MusicStore
    @EnvironmentObject var media: MediaStore
    @EnvironmentObject var photos: PhotoSync
    @EnvironmentObject var clip: ClipboardSync
    @EnvironmentObject var player: Player
    @AppStorage("mg.liveActivity") private var liveActivity = true
    @AppStorage("mg.appearance") private var appearance = 0
    @State private var editingHost = false
    @State private var newHost = ""
    @State private var confirmSignOut = false

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()
                ScrollView {
                    VStack(spacing: 22) {
                        header
                        connectionSection
                        backupSection
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

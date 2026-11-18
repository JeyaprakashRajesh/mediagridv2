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
    @AppStorage("mg.accent") private var accent = "blue"
    @State private var editingHost = false
    @State private var newHost = ""
    @State private var confirmSignOut = false

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()
                ScrollView {
                    VStack(spacing: 18) {
                        header
                        appearanceCard
                        photoCard
                        connectionCard
                        togglesCard
                        storageCard
                        Button(role: .destructive) { confirmSignOut = true } label: {
                            Text("Sign out").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
                        }
                        .buttonStyle(.glass).tint(.red)
                        Text("MediaGrid \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") · Made for Jeyaprakash's PC")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 60)
                }
                .trackScrollDirection()
            }
            .navigationTitle("Profile")
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

    private var header: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle().fill(Theme.brand).frame(width: 92, height: 92).shadow(color: Theme.violet.opacity(0.6), radius: 24, y: 10)
                Text(String(conn.email.prefix(2)).uppercased()).font(.system(size: 34, weight: .heavy, design: .rounded)).foregroundStyle(.white)
            }
            Text(conn.email).font(.headline)
            HStack(spacing: 8) {
                StatusDot(state: conn.state)
                Text(conn.state == .online ? "Connected to \(conn.pcName)" : conn.state == .connecting ? "Connecting to \(conn.pcName)…" : "\(conn.pcName) is offline")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                stat("\(music.tracks.count)", "Songs")
                stat("\(media.items.count)", "PC media")
                stat("\(music.downloaded.count)", "Offline")
            }
            .padding(.top, 4)
        }
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: 30))
    }

    private func stat(_ v: String, _ l: String) -> some View {
        VStack(spacing: 2) {
            Text(v).font(.title3.weight(.bold)).contentTransition(.numericText())
            Text(l).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var appearanceCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("Appearance").font(.headline)
                Picker("Theme", selection: $appearance) {
                    Text("System").tag(0); Text("Light").tag(1); Text("Dark").tag(2)
                }
                .pickerStyle(.segmented)
                Text("Accent colour").font(.subheadline).foregroundStyle(.secondary)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 14) {
                    ForEach(Theme.accents, id: \.id) { a in
                        Button { accent = a.id; Haptics.tap() } label: {
                            VStack(spacing: 6) {
                                Circle().fill(a.color).frame(width: 40, height: 40)
                                    .overlay { if accent == a.id { Image(systemName: "checkmark").font(.subheadline.weight(.bold)).foregroundStyle(.white) } }
                                Text(a.name).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var photoCard: some View {
        GlassCard(tint: Theme.accent) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Image(systemName: "photo.stack.fill").font(.title2).foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Photo backup to PC").font(.headline)
                        Text(photos.running ? photos.status : photos.lastSync.map { "Last backup \($0.relative)" } ?? "Not backed up yet")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        Task { await photos.syncNow() }
                        Haptics.tap()
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath").symbolEffect(.rotate, isActive: photos.running)
                    }
                    .buttonStyle(.glassProminent).tint(Theme.accent).disabled(photos.running || conn.state != .online)
                }
                if photos.running && photos.total > 0 {
                    ProgressView(value: Double(photos.done), total: Double(photos.total)).tint(Theme.accent)
                }
                Toggle("Back up new photos automatically", isOn: $photos.auto).tint(Theme.violet)
                Toggle("Include videos", isOn: $photos.includeVideos).tint(Theme.violet)
            }
            .font(.subheadline)
        }
    }

    private var connectionCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Connection").font(.headline)
                row("desktopcomputer", "PC", conn.pcName)
                row(conn.host.hasPrefix("100.") ? "lock.shield.fill" : "wifi", conn.host.hasPrefix("100.") ? "Tailscale" : "Wi-Fi", conn.host)
                if !conn.discovered.isEmpty {
                    Divider().opacity(0.3)
                    Text("Found nearby").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(conn.discovered) { pc in
                        Button {
                            conn.host = "\(pc.host):\(pc.port)"; conn.remember(conn.host)
                            UserDefaults.standard.set(conn.host, forKey: "mg.host")
                            conn.connect()
                        } label: {
                            HStack { Image(systemName: "dot.radiowaves.left.and.right"); Text("\(pc.name) — \(pc.host)"); Spacer()
                                if conn.host == "\(pc.host):\(pc.port)" { Image(systemName: "checkmark").foregroundStyle(Theme.mint) } }
                                .font(.subheadline)
                        }
                        .buttonStyle(.plain)
                    }
                }
                HStack {
                    Button("Change address") { newHost = conn.host; editingHost = true }.buttonStyle(.glass)
                    Spacer()
                    Button("Reconnect") { conn.connect() }.buttonStyle(.glass)
                }
                .font(.subheadline.weight(.semibold))
            }
        }
    }

    private func row(_ icon: String, _ k: String, _ v: String) -> some View {
        HStack {
            Image(systemName: icon).foregroundStyle(Theme.violet).frame(width: 24)
            Text(k).foregroundStyle(.secondary)
            Spacer()
            Text(v).fontWeight(.semibold).lineLimit(1).textSelection(.enabled)
        }
        .font(.subheadline)
    }

    private var togglesCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Preferences").font(.headline)
                Toggle(isOn: $clip.auto) { Label("Universal clipboard", systemImage: "doc.on.clipboard") }
                Toggle(isOn: $liveActivity) { Label("Dynamic Island & Lock Screen", systemImage: "platter.filled.top.iphone") }
                Toggle(isOn: $player.shuffle) {
                    Label("Shuffle by default", systemImage: "shuffle")
                }
            }
            .tint(Theme.violet)
            .font(.subheadline)
        }
    }

    private var storageCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Storage on iPhone").font(.headline)
                row("music.note", "Offline music", music.downloadedBytes.byteString)
                row("photo", "Offline PC media", media.localBytes.byteString)
                HStack {
                    Button("Clear music", role: .destructive) { music.removeAllDownloads() }.buttonStyle(.glass)
                    Spacer()
                    Button("Clear media", role: .destructive) { media.clearLocal(); Task { await ImageCache.shared.clear() } }.buttonStyle(.glass)
                }
                .font(.subheadline.weight(.semibold))
            }
        }
    }
}

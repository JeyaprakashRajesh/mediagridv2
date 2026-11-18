import SwiftUI
import UIKit
import AVKit
import UniformTypeIdentifiers
import QuickLook

struct PCView: View {
    @EnvironmentObject var conn: Connection
    @State private var section = 0   // 0 Files (default), 1 Access PC

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()
                VStack(spacing: 12) {
                    header
                    Picker("", selection: $section.animation(.smooth(duration: 0.2))) {
                        Text("Files").tag(0)
                        Text("Access PC").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 20)

                    if section == 0 { FilesRoot() } else { AccessPCView() }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    /// PC name on the left, connection state (green / red dot) on the right.
    private var header: some View {
        let online = conn.state == .online
        return HStack(spacing: 10) {
            Text(conn.pcName.isEmpty ? "PC" : conn.pcName).font(.largeTitle.weight(.bold)).lineLimit(1).minimumScaleFactor(0.6)
            Spacer(minLength: 8)
            HStack(spacing: 7) {
                Circle().fill(online ? Color.green : Color.red).frame(width: 9, height: 9)
                Text(online ? "Connected" : conn.state == .connecting ? "Connecting" : "Offline").font(.caption.weight(.semibold))
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .glassEffect(.regular, in: .capsule)
        }
        .padding(.horizontal, 20).padding(.top, 6)
    }
}

// MARK: - Access PC

struct AccessPCView: View {
    @EnvironmentObject var conn: Connection
    @State private var confirm: String?
    @State private var showConfirm = false
    @State private var brightness = 70.0
    @State private var wifi = true
    @State private var bluetooth = true

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                NavigationLink { RemoteDesktopView() } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "arrow.right").font(.headline).foregroundStyle(.white)
                            .frame(width: 46, height: 46).background(Theme.accent, in: .circle)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Remote desktop").font(.headline)
                            Text("See and control your PC screen").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 26))
                }
                .buttonStyle(.plain)

                GlassCard {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Essential controls").font(.headline)

                        HStack {
                            media("speaker.minus.fill", "voldown"); Spacer()
                            media("speaker.slash.fill", "mute"); Spacer()
                            media("speaker.plus.fill", "volup"); Spacer()
                            media("backward.fill", "prev"); Spacer()
                            media("playpause.fill", "playpause"); Spacer()
                            media("forward.fill", "next")
                        }

                        HStack(spacing: 12) {
                            IconBadge(symbol: "sun.max.fill", color: .orange, size: 30)
                            Slider(value: $brightness, in: 5...100) { editing in
                                if !editing { sys("brightness", brightness) }
                            }
                        }

                        Toggle(isOn: $wifi) { Label("Wi-Fi", systemImage: "wifi") }
                            .onChange(of: wifi) { _, v in sys("wifi", v ? 1 : 0) }
                        Toggle(isOn: $bluetooth) { Label("Bluetooth", systemImage: "wave.3.right") }
                            .onChange(of: bluetooth) { _, v in sys("bluetooth", v ? 1 : 0) }
                        Text("Brightness works on laptop screens. Wi-Fi needs MediaGrid on the PC to run as administrator.")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    .tint(Theme.accent)
                    .font(.subheadline)
                }

                GlassCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Power").font(.headline)
                        HStack(spacing: 10) {
                            powerBtn("Lock", "lock.fill", "lock", safe: true)
                            powerBtn("Screen off", "moon.fill", "screenoff", safe: true)
                            powerBtn("Sleep", "powersleep", "sleep")
                            powerBtn("Restart", "arrow.clockwise", "restart")
                            powerBtn("Shut down", "power", "shutdown")
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 60)
        }
        .confirmationDialog("Are you sure?", isPresented: $showConfirm, titleVisibility: .visible) {
            Button(confirm?.capitalized ?? "", role: .destructive) { if let c = confirm { conn.send(["type": "power", "action": c]) }; confirm = nil }
        } message: { Text("This will \(confirm ?? "") your PC.") }
    }

    private func sys(_ action: String, _ value: Double) { conn.send(["type": "sys", "action": action, "value": value]); Haptics.tap() }

    private func media(_ icon: String, _ action: String) -> some View {
        Button { conn.send(["type": "media", "action": action]); Haptics.tap() } label: {
            Image(systemName: icon).font(.body).frame(width: 36, height: 36)
        }
        .buttonStyle(.glass).buttonBorderShape(.circle)
    }

    private func powerBtn(_ t: String, _ icon: String, _ action: String, safe: Bool = false) -> some View {
        Button {
            if safe { conn.send(["type": "power", "action": action]); Haptics.tap() } else { confirm = action; showConfirm = true }
        } label: {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.title3)
                Text(t).font(.caption2.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .foregroundStyle(action == "shutdown" ? Theme.pink : action == "restart" ? Color.orange : action == "lock" ? Theme.cyan : Theme.mint)
    }
}

// MARK: - Remote desktop

/// Live screen with three ways to drive the pointer: touch (tap/drag where you want it), trackpad (relative) and scroll.
struct RemoteDesktopView: View {
    @EnvironmentObject var conn: Connection
    @State private var connected = false
    @State private var image: UIImage?
    @State private var fps = 0.0
    @State private var error: String?
    @State private var mode = 0           // 0 touch, 1 trackpad, 2 scroll
    @State private var quality = 1
    @State private var session = 0
    @State private var seq = 0
    @State private var shown = 0
    @State private var frames = 0
    @State private var since = Date()
    @State private var last: CGPoint?
    @State private var lastSent = Date.distantPast
    @State private var text = " "
    @FocusState private var typing: Bool
    @AppStorage("mg.sensitivity") private var sensitivity = 1.6

    private static let presets: [(name: String, w: Int, q: Int)] = [("Fast", 960, 40), ("Balanced", 1280, 55), ("Sharp", 1920, 75)]
    private static let keys: [[String]] = [["esc", "esc"], ["tab", "tab"], ["↵", "enter"], ["⊞", "win"], ["Alt+Tab", "alt+tab"],
                                           ["Copy", "ctrl+c"], ["Paste", "ctrl+v"], ["Desktop", "win+d"], ["Close", "alt+f4"]]

    var body: some View {
        ZStack {
            AppBackground()
            ScrollView {
                VStack(spacing: 14) {
                    screen
                    if connected { controls } else { connectCard }
                }
                .padding(.horizontal, 16).padding(.bottom, 40)
            }
        }
        .navigationTitle("Remote desktop")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: "\(connected)-\(session)-\(quality)") {
            guard connected else { return }
            async let a: Void = pump(delay: 0)
            async let b: Void = pump(delay: 45)   // two requests in flight keeps the stream moving while one decodes
            _ = await (a, b)
        }
        .onDisappear { connected = false }
    }

    private var connectCard: some View {
        VStack(spacing: 12) {
            Text(error ?? "Connect to see and control \(conn.pcName.isEmpty ? "your PC" : conn.pcName).").font(.subheadline)
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button { error = nil; image = nil; session += 1; connected = true; Haptics.soft() } label: {
                Label("Connect", systemImage: "play.display").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.glassProminent).tint(Theme.accent).foregroundStyle(.white).disabled(conn.state != .online)
        }
        .padding(16).glassEffect(.regular, in: .rect(cornerRadius: 26))
    }

    private var controls: some View {
        VStack(spacing: 12) {
            Picker("Mode", selection: $mode) {
                Image(systemName: "hand.tap").tag(0)
                Image(systemName: "rectangle.and.hand.point.up.left").tag(1)
                Image(systemName: "arrow.up.and.down.text.horizontal").tag(2)
            }
            .pickerStyle(.segmented)
            Text(["Touch: tap or drag where you want the pointer", "Trackpad: drag to move, tap to click", "Scroll: drag to scroll"][mode])
                .font(.caption).foregroundStyle(.secondary)

            HStack(spacing: 10) {
                small("Left click", "cursorarrow.click") { conn.send(["type": "click", "button": "left"]) }
                small("Right click", "cursorarrow.click.2") { conn.send(["type": "click", "button": "right"]) }
                small("Double", "cursorarrow.rays") { conn.send(["type": "click", "button": "left", "double": true]) }
            }

            HStack {
                Image(systemName: "keyboard").foregroundStyle(.secondary)
                TextField("Type on your PC", text: $text).focused($typing)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .onChange(of: text) { old, new in typed(old: old, new: new) }
                    .onSubmit { conn.send(["type": "key", "key": "enter"]); text = " "; typing = true }
                if typing { Button("Done") { typing = false }.font(.footnote.weight(.semibold)) }
            }
            .padding(14).glassEffect(.regular.interactive(), in: .rect(cornerRadius: 18))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Self.keys, id: \.self) { k in
                        Button(k[0]) { conn.send(["type": "key", "key": k[1]]); Haptics.tap() }
                            .font(.footnote.weight(.semibold)).padding(.horizontal, 14).padding(.vertical, 10)
                            .glassEffect(.regular.interactive(), in: .capsule)
                    }
                }
            }
            .buttonStyle(.plain)

            HStack {
                Picker("Quality", selection: $quality) { ForEach(0..<3) { Text(Self.presets[$0].name).tag($0) } }.pickerStyle(.segmented)
            }
            HStack {
                Image(systemName: "speedometer").foregroundStyle(.secondary)
                Slider(value: $sensitivity, in: 0.6...4)
                Text(String(format: "%.0f fps", fps)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Button(role: .destructive) { connected = false; Haptics.tap() } label: {
                Label("Disconnect", systemImage: "xmark.circle").frame(maxWidth: .infinity).padding(.vertical, 4)
            }
            .buttonStyle(.glass)
        }
        .tint(Theme.accent)
    }

    private func small(_ t: String, _ icon: String, _ a: @escaping () -> Void) -> some View {
        Button { a(); Haptics.tap() } label: { Label(t, systemImage: icon).font(.caption.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 12) }
            .buttonStyle(.plain).glassEffect(.regular.interactive(), in: .rect(cornerRadius: 16))
    }

    // MARK: screen + gestures

    private var screen: some View {
        ZStack {
            if let image {
                GeometryReader { g in
                    let fit = fitted(image.size, in: g.size)
                    Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
                        .frame(width: g.size.width, height: g.size.height)
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0)
                            .onChanged { v in drag(v, fit: fit, imageWidth: image.size.width) }
                            .onEnded { v in end(v, fit: fit) })
                }
            } else {
                VStack(spacing: 10) {
                    if connected { ProgressView() } else { Image(systemName: "display").font(.largeTitle).foregroundStyle(.secondary) }
                    Text(connected ? (error ?? "Connecting to your screen…") : "Not connected").font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(16 / 10, contentMode: .fit)
        .clipShape(.rect(cornerRadius: 22))
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }

    private func drag(_ v: DragGesture.Value, fit: CGRect, imageWidth: CGFloat) {
        guard connected, Date().timeIntervalSince(lastSent) > 0.02 else { return }
        lastSent = Date()
        switch mode {
        case 0:
            let x = (v.location.x - fit.minX) / fit.width, y = (v.location.y - fit.minY) / fit.height
            guard (0...1).contains(x), (0...1).contains(y) else { return }
            conn.send(["type": "moveabs", "x": x, "y": y])
        case 1:
            if let l = last {
                let k = Double(imageWidth / max(fit.width, 1)) * sensitivity / 1.6
                conn.send(["type": "move", "dx": Double(v.location.x - l.x) * k, "dy": Double(v.location.y - l.y) * k])
            }
            last = v.location
        default:
            if let l = last { conn.send(["type": "scroll", "dx": Double(l.x - v.location.x) / 30, "dy": Double(l.y - v.location.y) / 18]) }
            last = v.location
        }
    }

    private func end(_ v: DragGesture.Value, fit: CGRect) {
        last = nil
        guard connected, hypot(v.translation.width, v.translation.height) < 8, mode != 2 else { return }
        if mode == 0 {
            let x = (v.location.x - fit.minX) / fit.width, y = (v.location.y - fit.minY) / fit.height
            guard (0...1).contains(x), (0...1).contains(y) else { return }
            conn.send(["type": "moveabs", "x": x, "y": y])
        }
        conn.send(["type": "click", "button": "left"])
        Haptics.tap()
    }

    private func typed(old: String, new: String) {
        if new.count < old.count {
            for _ in 0..<(old.count - new.count) { conn.send(["type": "key", "key": "backspace"]) }
        } else if new.count > old.count, new.hasPrefix(old) {
            conn.send(["type": "text", "text": String(new.dropFirst(old.count))])
        } else if new != old {
            conn.send(["type": "text", "text": new.trimmingCharacters(in: .whitespaces)])
        }
        if new.isEmpty || new.count > 60 { text = " " }
    }

    /// Frame loop. Two of these run at once; a frame is shown only if it is newer than the one on screen.
    @MainActor private func pump(delay: Int) async {
        let p = Self.presets[quality]
        try? await Task.sleep(for: .milliseconds(delay))
        while !Task.isCancelled && connected {
            seq += 1
            let mine = seq
            do {
                let d = try await conn.request("/api/screen", query: ["w": "\(p.w)", "q": "\(p.q)"])
                if mine > shown, let img = UIImage(data: d), let ready = await img.byPreparingForDisplay() {
                    shown = mine; image = ready; error = nil; frames += 1
                    let dt = Date().timeIntervalSince(since)
                    if dt > 1 { fps = Double(frames) / dt; frames = 0; since = Date() }
                }
            } catch {
                self.error = error.localizedDescription
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func fitted(_ img: CGSize, in box: CGSize) -> CGRect {
        let s = min(box.width / img.width, box.height / img.height)
        let w = img.width * s, h = img.height * s
        return CGRect(x: (box.width - w) / 2, y: (box.height - h) / 2, width: w, height: h)
    }
}

// MARK: - File explorer

struct FilesRoot: View {
    var body: some View { FolderView(path: "", title: "This PC") }
}

struct FolderView: View {
    let path: String
    let title: String
    @EnvironmentObject var conn: Connection
    @State private var listing: FileListing?
    @State private var error: String?
    @State private var preview: URL?
    @State private var player: FileEntry?
    @State private var photo: FileEntry?
    @State private var importing = false
    @State private var busy: String?
    @State private var showHidden = false
    @State private var query = ""

    private var entries: [FileEntry] {
        let e = listing?.entries ?? []
        return query.isEmpty ? e : e.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        List {
            if path.isEmpty {
                // the nav bar is hidden on this page, so the root gets its own filter field
                HStack { Image(systemName: "magnifyingglass").foregroundStyle(.secondary); TextField("Filter", text: $query) }
                    .listRowBackground(Color.white.opacity(0.04))
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary).listRowBackground(Color.clear)
            }
            ForEach(entries) { e in
                if e.dir {
                    NavigationLink { FolderView(path: e.path, title: e.name) } label: { FileRow(entry: e) }
                        .listRowBackground(Color.white.opacity(0.04))
                } else {
                    Button { open(e) } label: { FileRow(entry: e, busy: busy == e.path) }
                        .listRowBackground(Color.white.opacity(0.04))
                        .swipeActions {
                            Button { download(e) } label: { Label("Save", systemImage: "square.and.arrow.down") }.tint(Theme.accent)
                        }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .listStyle(.insetGrouped)
        .searchable(text: $query, prompt: "Filter")
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(path.isEmpty ? .automatic : .inline)
        .overlay { if listing == nil && error == nil { ProgressView() } }
        .toolbar {
            if !path.isEmpty {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { importing = true } label: { Image(systemName: "square.and.arrow.up") }
                    Button { showHidden.toggle(); Task { await load() } } label: { Image(systemName: showHidden ? "eye.slash" : "eye") }
                }
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .quickLookPreview($preview)
        .sheet(item: $player) { e in
            StreamVideo(url: conn.url("/api/files/raw", ["path": e.path]), active: true).ignoresSafeArea()
        }
        .sheet(item: $photo) { e in
            ZStack {
                Color.black.ignoresSafeArea()
                RemoteImage(url: conn.url("/api/files/thumb", ["path": e.path, "s": "2000"]), contentMode: .fit) {
                    RemoteImage(url: conn.url("/api/files/raw", ["path": e.path]), contentMode: .fit) { ProgressView() }
                }
            }
            .presentationDragIndicator(.visible)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { r in
            guard case .success(let urls) = r else { return }
            Task {
                for u in urls {
                    let ok = u.startAccessingSecurityScopedResource()
                    defer { if ok { u.stopAccessingSecurityScopedResource() } }
                    try? await conn.upload("/api/files/upload", query: ["dir": path, "name": u.lastPathComponent], file: u)
                }
                Haptics.success()
                await load()
            }
        }
    }

    private func load() async {
        do {
            listing = try await conn.get("/api/files/list", query: ["path": path, "hidden": showHidden ? "1" : "0"])
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func open(_ e: FileEntry) {
        if e.isVideo || e.isAudio { player = e; return }
        if e.isImage { photo = e; return }
        download(e)
    }

    private func download(_ e: FileEntry) {
        busy = e.path
        Task {
            defer { busy = nil }
            do {
                let (tmp, _) = try await conn.session.download(from: conn.url("/api/files/raw", ["path": e.path]))
                let dest = FileManager.default.temporaryDirectory.appendingPathComponent(e.name)
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: tmp, to: dest)
                preview = dest
            } catch { self.error = error.localizedDescription }
        }
    }
}

struct FileRow: View {
    let entry: FileEntry
    var busy = false

    private var icon: (String, Color) {
        if entry.drive == true { return ("internaldrive.fill", Theme.cyan) }
        if entry.place == true {
            switch entry.name {
            case "Desktop": return ("menubar.dock.rectangle", Theme.violet)
            case "Documents": return ("doc.text.fill", Theme.cyan)
            case "Downloads": return ("arrow.down.circle.fill", Theme.mint)
            case "Music": return ("music.note", Theme.pink)
            case "Pictures": return ("photo.fill", Theme.accent)
            case "Videos": return ("film.fill", Theme.accent)
            default: return ("folder.fill", Theme.violet)
            }
        }
        if entry.dir { return ("folder.fill", Theme.violet) }
        if entry.isImage { return ("photo", Theme.accent) }
        if entry.isVideo { return ("play.rectangle.fill", Theme.accent) }
        if entry.isAudio { return ("music.note", Theme.pink) }
        switch entry.lowerExt {
        case "pdf": return ("doc.richtext.fill", Theme.accent)
        case "zip", "rar", "7z": return ("doc.zipper", .gray)
        case "exe", "msi": return ("app.badge", Theme.cyan)
        case "txt", "md", "log": return ("doc.plaintext", .secondary)
        default: return ("doc", .secondary)
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon.0).font(.title3).foregroundStyle(icon.1).frame(width: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).font(.body).lineLimit(1)
                if !entry.dir, let s = entry.size {
                    Text("\(s.byteString)\(entry.modified.map { " · " + Date(timeIntervalSince1970: Double($0) / 1000).formatted(date: .abbreviated, time: .omitted) } ?? "")")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if busy { ProgressView() }
        }
        .foregroundStyle(.primary)
    }
}

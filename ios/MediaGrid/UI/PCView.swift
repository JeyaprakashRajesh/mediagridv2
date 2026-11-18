import SwiftUI
import UIKit
import AVKit
import UniformTypeIdentifiers
import QuickLook

struct PCView: View {
    @EnvironmentObject var conn: Connection
    @State private var section = 0

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()
                VStack(spacing: 12) {
                    Picker("", selection: $section.animation(.smooth)) {
                        Label("Remote", systemImage: "hand.point.up.left").tag(0)
                        Label("Screen", systemImage: "display").tag(1)
                        Label("Files", systemImage: "folder").tag(2)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 20)

                    switch section {
                    case 0: RemoteControlView()
                    case 1: ScreenView()
                    default: FilesRoot()
                    }
                }
            }
            .navigationTitle(conn.pcName.isEmpty ? "PC" : conn.pcName)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    HStack(spacing: 6) { StatusDot(state: conn.state); Text(conn.state == .online ? "Online" : "Offline").font(.caption.weight(.semibold)) }
                        .padding(.horizontal, 10).padding(.vertical, 5)
                }
            }
        }
    }
}

// MARK: - Remote control

struct RemoteControlView: View {
    @EnvironmentObject var conn: Connection
    @State private var keyboard = " "
    @State private var confirm: String?
    @State private var showConfirm = false
    @FocusState private var typing: Bool
    @AppStorage("mg.sensitivity") private var sensitivity = 1.6

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Trackpad(sensitivity: sensitivity)
                    .frame(height: 300)
                    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 30))
                    .overlay(alignment: .bottom) {
                        Text("1 finger move · tap click · 2 fingers scroll · 2-finger tap right-click · hold to drag")
                            .font(.caption2).foregroundStyle(.tertiary).padding(10).allowsHitTesting(false)
                    }

                GlassEffectContainer(spacing: 10) {
                    HStack(spacing: 10) {
                        pill("Left click") { send(["type": "click", "button": "left"]) }
                        pill("Right click") { send(["type": "click", "button": "right"]) }
                    }
                }

                // keyboard
                HStack {
                    Image(systemName: "keyboard").foregroundStyle(.secondary)
                    TextField("Tap to type on your PC", text: $keyboard)
                        .focused($typing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: keyboard) { old, new in typed(old: old, new: new) }
                        .onSubmit { send(["type": "key", "key": "enter"]); keyboard = " "; typing = true }
                    if typing { Button("Done") { typing = false }.font(.footnote.weight(.semibold)) }
                }
                .padding(14)
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 18))

                ScrollView(.horizontal, showsIndicators: false) {
                    GlassEffectContainer(spacing: 8) {
                        HStack(spacing: 8) {
                            ForEach(Self.keys, id: \.self) { pair in
                                Button(pair[0]) { send(["type": "key", "key": pair[1]]) }
                                    .font(.footnote.weight(.semibold))
                                    .padding(.horizontal, 14).padding(.vertical, 10)
                                    .glassEffect(.regular.interactive(), in: .capsule)
                            }
                        }
                        .padding(.horizontal, 2)
                    }
                }
                .buttonStyle(.plain)

                // media
                GlassCard {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("PC media").font(.headline)
                        HStack {
                            mediaBtn("backward.fill", "prev"); Spacer()
                            mediaBtn("playpause.fill", "playpause"); Spacer()
                            mediaBtn("forward.fill", "next"); Spacer()
                            mediaBtn("speaker.minus.fill", "voldown"); Spacer()
                            mediaBtn("speaker.slash.fill", "mute"); Spacer()
                            mediaBtn("speaker.plus.fill", "volup")
                        }
                    }
                }

                // power
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

                VStack(alignment: .leading) {
                    Text("Pointer speed").font(.caption).foregroundStyle(.secondary)
                    Slider(value: $sensitivity, in: 0.6...4).tint(Theme.violet)
                }
                .padding(.horizontal, 6)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 60)
        }
        .scrollDisabled(false)
        .confirmationDialog("Are you sure?", isPresented: $showConfirm, titleVisibility: .visible) {
            Button(confirm?.capitalized ?? "", role: .destructive) { if let c = confirm { send(["type": "power", "action": c]) }; confirm = nil }
        } message: { Text("This will \(confirm ?? "") your PC.") }
    }

    static let keys: [[String]] = [["esc", "esc"], ["tab", "tab"], ["⌫", "backspace"], ["↵", "enter"], ["←", "left"], ["↑", "up"],
                                   ["↓", "down"], ["→", "right"], ["⊞", "win"], ["Alt+Tab", "alt+tab"], ["Copy", "ctrl+c"],
                                   ["Paste", "ctrl+v"], ["Undo", "ctrl+z"], ["Desktop", "win+d"], ["Task Mgr", "ctrl+shift+esc"],
                                   ["F5", "f5"], ["Close", "alt+f4"]]

    private func send(_ o: [String: Any]) { conn.send(o); Haptics.tap() }

    private func typed(old: String, new: String) {
        if new.count < old.count {
            for _ in 0..<(old.count - new.count) { conn.send(["type": "key", "key": "backspace"]) }
        } else if new.count > old.count, new.hasPrefix(old) {
            conn.send(["type": "text", "text": String(new.dropFirst(old.count))])
        } else if new != old {
            conn.send(["type": "text", "text": new.trimmingCharacters(in: .whitespaces)])
        }
        if new.isEmpty || new.count > 60 { keyboard = " " }
    }

    private func pill(_ t: String, _ a: @escaping () -> Void) -> some View {
        Button(action: a) { Text(t).font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 14) }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 18))
    }

    private func mediaBtn(_ icon: String, _ action: String) -> some View {
        Button { send(["type": "media", "action": action]) } label: { Image(systemName: icon).font(.title3).frame(width: 40, height: 40) }
            .buttonStyle(.glass).buttonBorderShape(.circle).tint(Theme.accent)
    }

    private func powerBtn(_ t: String, _ icon: String, _ action: String, safe: Bool = false) -> some View {
        Button {
            if safe { send(["type": "power", "action": action]) } else { confirm = action; showConfirm = true }
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

/// Multi-touch trackpad backed by UIKit gesture recognizers.
struct Trackpad: UIViewRepresentable {
    var sensitivity: Double

    func makeCoordinator() -> Coord { Coord() }

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .clear
        v.isMultipleTouchEnabled = true
        let c = context.coordinator
        let pan1 = UIPanGestureRecognizer(target: c, action: #selector(Coord.move(_:)))
        pan1.maximumNumberOfTouches = 1
        let pan2 = UIPanGestureRecognizer(target: c, action: #selector(Coord.scroll(_:)))
        pan2.minimumNumberOfTouches = 2
        let tap1 = UITapGestureRecognizer(target: c, action: #selector(Coord.click(_:)))
        let tap2 = UITapGestureRecognizer(target: c, action: #selector(Coord.rightClick(_:)))
        tap2.numberOfTouchesRequired = 2
        let hold = UILongPressGestureRecognizer(target: c, action: #selector(Coord.drag(_:)))
        hold.minimumPressDuration = 0.35
        hold.allowableMovement = 2000
        [pan1, pan2, tap1, tap2, hold].forEach(v.addGestureRecognizer)
        tap1.require(toFail: tap2)
        return v
    }

    func updateUIView(_ v: UIView, context: Context) { context.coordinator.sensitivity = sensitivity }

    final class Coord: NSObject {
        var sensitivity = 1.6
        private var lastHold: CGPoint = .zero
        private let haptic = UIImpactFeedbackGenerator(style: .light)

        private func send(_ o: [String: Any]) { MainActor.assumeIsolated { Connection.shared.send(o) } }

        @objc func move(_ g: UIPanGestureRecognizer) {
            let t = g.translation(in: g.view)
            g.setTranslation(.zero, in: g.view)
            let v = g.velocity(in: g.view)
            let speed = hypot(v.x, v.y)
            let accel = 1 + min(2.2, speed / 900)           // pointer acceleration
            let k = sensitivity * accel
            send(["type": "move", "dx": Double(t.x) * k, "dy": Double(t.y) * k])
        }

        @objc func scroll(_ g: UIPanGestureRecognizer) {
            let t = g.translation(in: g.view)
            g.setTranslation(.zero, in: g.view)
            send(["type": "scroll", "dx": Double(-t.x) / 30, "dy": Double(-t.y) / 18])
        }

        @objc func click(_ g: UITapGestureRecognizer) { haptic.impactOccurred(); send(["type": "click", "button": "left"]) }
        @objc func rightClick(_ g: UITapGestureRecognizer) { haptic.impactOccurred(); send(["type": "click", "button": "right"]) }

        @objc func drag(_ g: UILongPressGestureRecognizer) {
            let p = g.location(in: g.view)
            switch g.state {
            case .began:
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                lastHold = p
                send(["type": "down", "button": "left"])
            case .changed:
                let dx = (p.x - lastHold.x) * sensitivity, dy = (p.y - lastHold.y) * sensitivity
                lastHold = p
                send(["type": "move", "dx": Double(dx), "dy": Double(dy)])
            default:
                send(["type": "up", "button": "left"])
            }
        }
    }
}

// MARK: - Live screen

struct ScreenView: View {
    @EnvironmentObject var conn: Connection
    @State private var image: UIImage?
    @State private var control = true
    @State private var fps = 0.0
    @State private var error: String?
    @State private var hq = false

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                if let image {
                    GeometryReader { g in
                        let fit = fitted(image.size, in: g.size)
                        Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
                            .frame(width: g.size.width, height: g.size.height)
                            .gesture(SpatialTapGesture().onEnded { v in
                                guard control else { return }
                                let x = (v.location.x - fit.minX) / fit.width, y = (v.location.y - fit.minY) / fit.height
                                guard (0...1).contains(x), (0...1).contains(y) else { return }
                                conn.send(["type": "moveabs", "x": x, "y": y])
                                conn.send(["type": "click", "button": "left"])
                                Haptics.tap()
                            })
                    }
                } else {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text(error ?? "Connecting to your screen…").font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(16 / 10, contentMode: .fit)
            .clipShape(.rect(cornerRadius: 22))
            .glassEffect(.regular, in: .rect(cornerRadius: 22))
            .padding(.horizontal, 12)

            HStack {
                Toggle(isOn: $control) { Label("Tap to click", systemImage: "cursorarrow.click.2") }.tint(Theme.violet)
                Spacer()
                Toggle(isOn: $hq) { Text("HD") }.tint(Theme.violet).fixedSize()
            }
            .font(.subheadline.weight(.semibold))
            .padding(16)
            .glassEffect(.regular, in: .rect(cornerRadius: 20))
            .padding(.horizontal, 20)

            Text(String(format: "%.0f fps", fps)).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
            Spacer()
        }
        .task {
            var frames = 0
            var since = Date()
            while !Task.isCancelled {
                do {
                    let d = try await conn.request("/api/screen", query: ["w": hq ? "1920" : "1280", "q": hq ? "70" : "50"])
                    if let i = UIImage(data: d) { image = i; error = nil }
                    frames += 1
                    if Date().timeIntervalSince(since) > 1 { fps = Double(frames) / Date().timeIntervalSince(since); frames = 0; since = Date() }
                } catch {
                    self.error = error.localizedDescription
                    try? await Task.sleep(for: .seconds(1))
                }
                try? await Task.sleep(for: .milliseconds(60))
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
                            Button { download(e) } label: { Label("Save", systemImage: "square.and.arrow.down") }.tint(Theme.violet)
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

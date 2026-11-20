import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import QuickLook

struct SharedView: View {
    @EnvironmentObject var store: SharedStore
    @EnvironmentObject var clip: ClipboardSync
    @EnvironmentObject var conn: Connection
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var importing = false
    @State private var sending = false
    @State private var sendingText = false
    @State private var customText = ""
    @State private var preview: URL?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()
                ScrollView {
                    VStack(spacing: 16) {
                        HStack {
                            Text("Shared").font(.largeTitle.weight(.bold))
                            Spacer()
                            if store.loading { ProgressView().controlSize(.small) }
                        }
                        .padding(.top, 6)
                        clipboardRow
                        sendButtons
                        shareSheetTip
                        historyBox
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 60)
                }
                .refreshable { await store.refresh() }
            }
            .toolbar(.hidden, for: .navigationBar)
            .task { await store.refresh() }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { r in
                guard case .success(let urls) = r else { return }
                send(urls: urls)
            }
            .onChange(of: photoItems) { _, items in
                guard !items.isEmpty else { return }
                Task { await sendPhotos(items); photoItems = [] }
            }
            .alert("Send to PC", isPresented: $sendingText) {
                TextField("Enter text or paste a link…", text: $customText)
                Button("Send to PC") { sendCustomText() }
                Button("Cancel", role: .cancel) { customText = "" }
            } message: {
                Text("Text or web links are copied directly to your PC clipboard and saved in Shared history.")
            }
            .quickLookPreview($preview)
        }
    }

    /// Universal clipboard switch: no fill, just an outline.
    private var clipboardRow: some View {
        let online = conn.state == .online
        return HStack(spacing: 12) {
            Image(systemName: "doc.on.clipboard").font(.title3).foregroundStyle(Theme.accent).frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text("Universal clipboard").font(.subheadline.weight(.semibold))
                Text(!clip.auto ? "Paused" : online ? "In sync with \(conn.pcName)" : "Waiting for your PC…")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: $clip.auto).labelsHidden().tint(Theme.accent)
        }
        .padding(14)
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.secondary.opacity(0.3), lineWidth: 1))
    }

    private var sendButtons: some View {
        GlassEffectContainer(spacing: 12) {
            VStack(spacing: 10) {
                HStack(spacing: 12) {
                    PhotosPicker(selection: $photoItems, maxSelectionCount: 30, matching: .any(of: [.images, .videos])) {
                        sendLabel("Send photos") {
                            Image(systemName: "photo.on.rectangle.angled").font(.system(size: 26))
                                .foregroundStyle(LinearGradient(colors: [.orange, .pink, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                        }
                    }
                    Button { importing = true } label: {
                        sendLabel("Send files") {
                            Image(systemName: "folder.fill").font(.system(size: 26)).foregroundStyle(Color(hex: 0x3B8EF0))
                        }
                    }
                }
                HStack(spacing: 12) {
                    Button { pasteAndSend() } label: {
                        sendLabel("Paste to PC") {
                            Image(systemName: "doc.on.clipboard.fill").font(.system(size: 26)).foregroundStyle(Theme.mint)
                        }
                    }
                    Button { sendingText = true } label: {
                        sendLabel("Send text / link") {
                            Image(systemName: "paperplane.fill").font(.system(size: 26)).foregroundStyle(Theme.accent)
                        }
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .overlay { if sending { ProgressView().padding().glassEffect(.regular, in: .circle) } }
    }

    private var shareSheetTip: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.and.arrow.up")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.accent)
            Text("Tip: In Safari, Photos, or Files, tap **Share** and choose **MediaGrid** to copy directly to your PC.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    private func sendLabel<I: View>(_ t: String, @ViewBuilder icon: () -> I) -> some View {
        VStack(spacing: 8) {
            icon()
            Text(t).font(.footnote.weight(.semibold))
        }
        .frame(maxWidth: .infinity).padding(.vertical, 18)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 24))
    }

    /// One big container; each of the latest 20 items sits in its own container inside it.
    private var historyBox: some View {
        let items = Array(store.items.prefix(20))
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("History").font(.headline)
                Spacer()
                Text("\(items.count)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)
            if let error { Text(error).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 6) }
            if items.isEmpty {
                Text("Things you copy or send between your PC and iPhone show up here.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: 300)
            }
            ForEach(items) { item in
                SharedRow(item: item) { open(item) }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 440, alignment: .top)
        .glassEffect(.regular, in: .rect(cornerRadius: 30))
        .animation(.spring(duration: 0.25), value: items.map(\.id))
    }

    private func open(_ i: SharedItem) {
        if i.isFile {
            Task {
                do { preview = try await store.fetch(i) } catch { self.error = error.localizedDescription }
            }
        } else if let t = i.text {
            ClipboardSync.shared.copyFromHistory(t)
            Haptics.success()
            Coordinator.shared.show("Copied")
        }
    }

    private func send(urls: [URL]) {
        sending = true
        Task {
            for u in urls {
                let ok = u.startAccessingSecurityScopedResource()
                defer { if ok { u.stopAccessingSecurityScopedResource() } }
                do { try await store.sendFile(u) } catch { self.error = error.localizedDescription }
            }
            sending = false
            Haptics.success()
        }
    }

    private func sendPhotos(_ items: [PhotosPickerItem]) async {
        sending = true
        for (i, it) in items.enumerated() {
            if let d = try? await it.loadTransferable(type: Data.self) {
                let ext = it.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
                let name = "IMG_\(Int(Date().timeIntervalSince1970))_\(i).\(ext)"
                do { try await store.sendData(d, name: name) } catch { self.error = error.localizedDescription }
            }
        }
        sending = false
        Haptics.success()
    }

    private func pasteAndSend() {
        guard let s = UIPasteboard.general.string, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            Coordinator.shared.show("Clipboard is empty")
            return
        }
        Task {
            do {
                try await store.sendText(s)
                Coordinator.shared.show("Copied clipboard to PC")
                Haptics.success()
                await store.refresh()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func sendCustomText() {
        let t = customText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        customText = ""
        Task {
            do {
                try await store.sendText(t)
                Coordinator.shared.show("Copied to PC clipboard")
                Haptics.success()
                await store.refresh()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

struct SharedRow: View {
    let item: SharedItem
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 12) {
                IconBadge(symbol: item.isFile ? "doc.fill" : "doc.on.clipboard", color: item.isFile ? Theme.cyan : Theme.accent, size: 36)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.isFile ? (item.name ?? "File") : (item.text ?? ""))
                        .font(.subheadline).lineLimit(2).multilineTextAlignment(.leading)
                    HStack(spacing: 5) {
                        Image(systemName: item.from == "pc" ? "desktopcomputer" : "iphone")
                        Text(item.from == "pc" ? "PC" : "iPhone")
                        Text("· \(item.date.relative)")
                        if let s = item.size { Text("· \(s.byteString)") }
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Image(systemName: item.isFile ? "eye" : "doc.on.doc").font(.footnote).foregroundStyle(.secondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.secondary.opacity(0.12), in: .rect(cornerRadius: 18))
            .contentShape(.rect(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let t = item.text {
                Button { ClipboardSync.shared.copyFromHistory(t) } label: { Label("Copy", systemImage: "doc.on.doc") }
                ShareLink(item: t)
                if t.lowercased().hasPrefix("http") {
                    Button { Task { try? await Connection.shared.post("/api/pc/open", json: ["url": t.trimmingCharacters(in: .whitespacesAndNewlines)]) } } label: { Label("Open on PC", systemImage: "desktopcomputer") }
                }
            }
        }
    }
}

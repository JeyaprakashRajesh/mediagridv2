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
    @State private var preview: URL?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()
                ScrollView {
                    VStack(spacing: 18) {
                        HStack {
                            Text("Shared").font(.largeTitle.weight(.bold))
                            Spacer()
                            if store.loading { ProgressView().controlSize(.small) }
                        }
                        .padding(.top, 6)
                        clipboardCard
                        actions
                        history
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
            .quickLookPreview($preview)
        }
    }

    /// Live status of the automatic clipboard, with the latest copied text.
    private var clipboardCard: some View {
        let latest = store.items.first { !$0.isFile }
        let online = conn.state == .online
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Image(systemName: "doc.on.clipboard.fill").font(.title2).foregroundStyle(.white)
                    .frame(width: 52, height: 52).background(Theme.accent, in: .rect(cornerRadius: 16))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Universal Clipboard").font(.headline)
                    HStack(spacing: 6) {
                        Circle().fill(clip.auto && online ? Theme.mint : .orange).frame(width: 8, height: 8)
                        Text(!clip.auto ? "Paused" : online ? "In sync with \(conn.pcName)" : "Waiting for your PC…")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Toggle("", isOn: $clip.auto).labelsHidden().tint(Theme.accent)
            }
            if let latest, let t = latest.text {
                VStack(alignment: .leading, spacing: 6) {
                    Text("LATEST").font(.caption2.weight(.bold)).foregroundStyle(.tertiary)
                    Text(t).font(.subheadline).lineLimit(3)
                    Label("\(latest.from == "pc" ? "From PC" : "From iPhone") · \(latest.date.relative)",
                          systemImage: latest.from == "pc" ? "desktopcomputer" : "iphone")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(.secondary.opacity(0.12), in: .rect(cornerRadius: 16))
            }
            Text("Copy on either device and it's ready to paste on the other. On iPhone this works while MediaGrid is open.")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
    }

    private var actions: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                PhotosPicker(selection: $photoItems, maxSelectionCount: 30, matching: .any(of: [.images, .videos])) {
                    actionLabel("Photos", "photo.on.rectangle", Theme.accent)
                }
                Button { importing = true } label: { actionLabel("Files", "folder.fill", Theme.accent) }
            }
        }
        .buttonStyle(.plain)
        .overlay {
            if sending { ProgressView().padding().glassEffect(.regular, in: .circle) }
        }
    }

    private func actionLabel(_ t: String, _ icon: String, _ c: Color) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.title2).foregroundStyle(c)
            Text("Send \(t)").font(.footnote.weight(.semibold))
        }
        .frame(maxWidth: .infinity).padding(.vertical, 18)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22))
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("History").font(.title3.weight(.bold))
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            if store.items.isEmpty {
                Text("Things you copy or send between your PC and iPhone show up here.")
                    .font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 30).frame(maxWidth: .infinity)
            }
            ForEach(store.items) { item in
                SharedRow(item: item) { open(item) }
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.4), value: store.items.map(\.id))
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
}

struct SharedRow: View {
    let item: SharedItem
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: item.isFile ? "doc.fill" : item.kind == "clipboard" ? "doc.on.clipboard" : "text.quote")
                    .font(.headline)
                    .foregroundStyle(item.isFile ? Theme.cyan : Theme.violet)
                    .frame(width: 38, height: 38)
                    .background((item.isFile ? Theme.cyan : Theme.violet).opacity(0.16), in: .rect(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.isFile ? (item.name ?? "File") : (item.text ?? ""))
                        .font(.subheadline).lineLimit(4).multilineTextAlignment(.leading)
                    HStack(spacing: 6) {
                        Image(systemName: item.from == "pc" ? "desktopcomputer" : "iphone")
                        Text(item.from == "pc" ? "PC" : item.from)
                        Text("·")
                        Text(item.date.relative)
                        if let s = item.size { Text("· \(s.byteString)") }
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: item.isFile ? "eye" : "doc.on.doc").font(.footnote).foregroundStyle(.secondary)
            }
            .padding(12)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22))
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let t = item.text {
                Button { ClipboardSync.shared.copyFromHistory(t) } label: { Label("Copy", systemImage: "doc.on.doc") }
                ShareLink(item: t)
            }
        }
    }
}

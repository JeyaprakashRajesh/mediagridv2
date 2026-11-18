import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import QuickLook

struct SharedView: View {
    @EnvironmentObject var store: SharedStore
    @EnvironmentObject var clip: ClipboardSync
    @EnvironmentObject var conn: Connection
    @State private var text = ""
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var importing = false
    @State private var sending = false
    @State private var preview: URL?
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()
                ScrollView {
                    VStack(spacing: 18) {
                        clipboardCard
                        composer
                        actions
                        history
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 60)
                }
                .scrollDismissesKeyboard(.interactively)
                .trackScrollDirection()
                .refreshable { await store.refresh() }
            }
            .navigationTitle("Shared")
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

    private var clipboardCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "doc.on.clipboard.fill").font(.title2).foregroundStyle(.white)
                .frame(width: 50, height: 50).background(Theme.brand, in: .rect(cornerRadius: 15))
            VStack(alignment: .leading, spacing: 3) {
                Text("Universal Clipboard").font(.headline)
                Text(clip.auto ? "Copy on PC → paste here. Copy here → it's on your PC when you open MediaGrid." : "Off — turn on to sync copies automatically")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: $clip.auto).labelsHidden().tint(Theme.violet)
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
    }

    private var composer: some View {
        VStack(spacing: 12) {
            TextField("Send text, a link or a code to your PC…", text: $text, axis: .vertical)
                .lineLimit(3...8)
                .focused($focused)
                .padding(14)
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 18))
            HStack(spacing: 10) {
                PasteButton(payloadType: String.self) { strings in
                    guard let s = strings.first else { return }
                    Task { @MainActor in ClipboardSync.shared.send(s); Coordinator.shared.show("Clipboard sent to PC") }
                }
                .buttonBorderShape(.capsule)
                .tint(Theme.violet)
                .labelStyle(.titleAndIcon)
                Spacer()
                Button {
                    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !t.isEmpty else { return }
                    Task {
                        do { try await store.sendText(t); text = ""; focused = false; Haptics.success() }
                        catch { self.error = error.localizedDescription }
                    }
                } label: { Label("Send", systemImage: "paperplane.fill") }
                .buttonStyle(.glassProminent).tint(Theme.violet)
                .disabled(text.isEmpty)
            }
        }
    }

    private var actions: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                PhotosPicker(selection: $photoItems, maxSelectionCount: 30, matching: .any(of: [.images, .videos])) {
                    actionLabel("Photos", "photo.on.rectangle", Theme.pink)
                }
                Button { importing = true } label: { actionLabel("Files", "folder.fill", Theme.cyan) }
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
            HStack {
                Text("History").font(.title3.weight(.bold))
                Spacer()
                if store.loading { ProgressView().controlSize(.small) }
            }
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
            UIPasteboard.general.string = t
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
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let t = item.text {
                Button { UIPasteboard.general.string = t } label: { Label("Copy", systemImage: "doc.on.doc") }
                ShareLink(item: t)
            }
        }
    }
}

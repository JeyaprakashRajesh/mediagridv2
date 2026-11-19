import SwiftUI

/// PC tab > Tools: health, eco mode, macros, app control, find my PC, open a link on the PC.
struct ToolsView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                HealthCard()
                EcoCard()
                MacrosCard()
                AppsCard()
                ExtrasCard()
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 60)
        }
    }
}

private func head(_ symbol: String, _ color: Color, _ title: String) -> some View {
    HStack(spacing: 10) { IconBadge(symbol: symbol, color: color, size: 30); Text(title).font(.headline); Spacer() }
}

// MARK: - Health

struct HealthCard: View {
    @EnvironmentObject var conn: Connection
    @State private var h: Health?

    struct Health: Decodable {
        var cpu: Double; var ramTotal: Double; var ramUsed: Double; var watts: Double; var eco: Bool
        var gpu: GPU?
        struct GPU: Decodable { var name: String?; var load: Double?; var temp: Double?; var watts: Double?; var vramUsed: Double?; var vramTotal: Double?; var fan: Double? }
    }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                head("waveform.path.ecg", Theme.pink, "PC health")
                if let h {
                    gauge("cpu", "Processor", h.cpu / 100, "\(Int(h.cpu))%", Theme.accent)
                    gauge("memorychip", "Memory", h.ramTotal > 0 ? h.ramUsed / h.ramTotal : 0, String(format: "%.1f / %.0f GB", h.ramUsed, h.ramTotal), Theme.cyan)
                    if let g = h.gpu {
                        gauge("display", g.name ?? "Graphics card", (g.load ?? 0) / 100, "\(Int(g.load ?? 0))%", Theme.mint)
                        if let u = g.vramUsed, let t = g.vramTotal, t > 0 { gauge("square.stack.3d.up", "Video memory", u / t, String(format: "%.1f / %.0f GB", u / 1024, t / 1024), Theme.mint) }
                        if let t = g.temp { gauge("thermometer.medium", "GPU temperature", min(t / 90, 1), "\(Int(t)) °C" + (g.fan.map { " · fan \(Int($0))%" } ?? ""), t > 80 ? Theme.pink : Theme.mint) }
                    }
                    HStack {
                        Image(systemName: "bolt.fill").foregroundStyle(Color.orange)
                        Text("About \(Int(h.watts)) W from the wall (estimate)").font(.subheadline.weight(.semibold))
                        Spacer()
                        if h.eco { Text("ECO").font(.caption2.weight(.heavy)).padding(.horizontal, 8).padding(.vertical, 3).background(Theme.mint, in: .capsule).foregroundStyle(.white) }
                    }
                } else {
                    Text(conn.state == .online ? "Reading…" : "PC offline").font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
        .task {
            while !Task.isCancelled {
                if conn.state == .online, let r: Health = try? await conn.get("/api/health") { h = r }
                try? await Task.sleep(for: .seconds(2.5))
            }
        }
    }

    private func gauge(_ icon: String, _ label: String, _ v: Double, _ text: String, _ c: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack { Image(systemName: icon).foregroundStyle(c).frame(width: 20); Text(label).font(.subheadline); Spacer(); Text(text).font(.subheadline.monospacedDigit().weight(.semibold)) }
            ProgressView(value: min(max(v, 0), 1)).tint(c)
        }
    }
}

// MARK: - Macros

struct MacroStep: Codable, Hashable { var kind: String; var value: String }
struct Macro: Codable, Identifiable, Hashable { var id: String; var name: String; var icon: String; var steps: [MacroStep] }

struct MacrosCard: View {
    @EnvironmentObject var conn: Connection
    @State private var macros: [Macro] = []
    @State private var editing: Macro?

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    IconBadge(symbol: "square.grid.2x2.fill", color: Theme.accent, size: 30)
                    Text("Macros").font(.headline)
                    Spacer()
                    Button { editing = Macro(id: UUID().uuidString, name: "", icon: "bolt.fill", steps: [MacroStep(kind: "keys", value: "")]) } label: { Image(systemName: "plus") }
                        .buttonStyle(.glass).buttonBorderShape(.circle)
                }
                if macros.isEmpty {
                    Text("One-tap buttons that run steps on the PC: key combos, open a site or program, lock, eco mode.").font(.caption).foregroundStyle(.secondary)
                }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(macros) { m in
                        Button { run(m) } label: {
                            VStack(spacing: 6) {
                                Image(systemName: m.icon).font(.title3)
                                Text(m.name).font(.footnote.weight(.semibold)).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity).padding(.vertical, 14)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 16))
                        .contextMenu {
                            Button { editing = m } label: { Label("Edit", systemImage: "pencil") }
                            Button(role: .destructive) { macros.removeAll { $0.id == m.id }; save() } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
                }
            }
        }
        .task { if let m: [Macro] = try? await conn.get("/api/macros") { macros = m } }
        .sheet(item: $editing) { m in
            MacroEditor(macro: m) { saved in
                if let i = macros.firstIndex(where: { $0.id == saved.id }) { macros[i] = saved } else { macros.append(saved) }
                save()
            }
        }
    }

    private func run(_ m: Macro) {
        Haptics.soft()
        Task { try? await conn.post("/api/macros/run", json: ["id": m.id]) }
    }

    private func save() {
        guard let d = try? JSONEncoder().encode(macros), let o = try? JSONSerialization.jsonObject(with: d) else { return }
        Task { try? await conn.post("/api/macros", json: o) }
    }
}

struct MacroEditor: View {
    @State var macro: Macro
    let onSave: (Macro) -> Void
    @Environment(\.dismiss) private var dismiss

    private static let kinds: [(String, String, String)] = [
        ("keys", "Press keys", "ctrl+shift+m"), ("text", "Type text", "Hello"), ("open", "Open link / file / program", "https://…"),
        ("wait", "Wait (milliseconds)", "1000"), ("eco", "Eco mode", "on or off"), ("lock", "Lock PC", ""), ("sleep", "Sleep PC", "")]
    private static let icons = ["bolt.fill", "star.fill", "moon.fill", "lock.fill", "play.fill", "globe", "terminal.fill", "gamecontroller.fill", "film.fill", "music.note", "mic.fill", "leaf.fill"]

    var body: some View {
        NavigationStack {
            Form {
                Section("Button") {
                    TextField("Name", text: $macro.name)
                    Picker("Icon", selection: $macro.icon) { ForEach(Self.icons, id: \.self) { Label($0, systemImage: $0).labelStyle(.iconOnly).tag($0) } }
                }
                Section("Steps (run in order)") {
                    ForEach(macro.steps.indices, id: \.self) { i in
                        VStack(alignment: .leading) {
                            Picker("Step \(i + 1)", selection: $macro.steps[i].kind) { ForEach(Self.kinds, id: \.0) { Text($0.1).tag($0.0) } }
                            if !["lock", "sleep"].contains(macro.steps[i].kind) {
                                TextField(Self.kinds.first { $0.0 == macro.steps[i].kind }?.2 ?? "", text: $macro.steps[i].value)
                                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                            }
                        }
                    }
                    .onDelete { macro.steps.remove(atOffsets: $0) }
                    Button { macro.steps.append(MacroStep(kind: "keys", value: "")) } label: { Label("Add step", systemImage: "plus") }
                }
            }
            .navigationTitle("Macro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(macro); dismiss() }.disabled(macro.name.trimmingCharacters(in: .whitespaces).isEmpty || macro.steps.isEmpty)
                }
            }
        }
    }
}

// MARK: - Apps

struct AppsCard: View {
    @EnvironmentObject var conn: Connection
    @State private var apps: [AppRow] = []
    @State private var closing: AppRow?
    @State private var loading = false

    struct AppRow: Decodable, Identifiable { var name: String; var count: Int; var mb: Double; var title: String?; var id: String { name } }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    IconBadge(symbol: "macwindow", color: Theme.cyan, size: 30)
                    Text("Running apps").font(.headline)
                    Spacer()
                    if loading { ProgressView() }
                    Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.glass).buttonBorderShape(.circle)
                }
                if apps.isEmpty && !loading { Text("Nothing to show.").font(.caption).foregroundStyle(.secondary) }
                ForEach(apps) { a in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(a.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Text("\(a.title ?? "") · \(Int(a.mb)) MB").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Menu {
                            Button { act(a, "suspend") } label: { Label("Pause (freeze)", systemImage: "pause.fill") }
                            Button { act(a, "resume") } label: { Label("Resume", systemImage: "play.fill") }
                            Button(role: .destructive) { closing = a } label: { Label("Close…", systemImage: "xmark") }
                        } label: { Image(systemName: "ellipsis.circle").font(.title3) }
                    }
                }
            }
        }
        .task { await load() }
        .confirmationDialog("Close \(closing?.name ?? "")?", isPresented: Binding(get: { closing != nil }, set: { if !$0 { closing = nil } }), titleVisibility: .visible) {
            Button("Close it", role: .destructive) { if let a = closing { act(a, "close") }; closing = nil }
        } message: { Text("The app is asked to close. It may ask the PC to save first.") }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        if let r: [AppRow] = try? await conn.get("/api/apps") { apps = r }
    }

    private func act(_ a: AppRow, _ action: String) {
        Haptics.soft()
        Task { try? await conn.post("/api/apps", json: ["name": a.name, "action": action]); try? await Task.sleep(for: .seconds(1)); await load() }
    }
}

// MARK: - Find my PC + open a link

struct ExtrasCard: View {
    @EnvironmentObject var conn: Connection
    @State private var link = ""
    @State private var note: String?

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                head("magnifyingglass", Theme.pink, "Find & open")
                Button {
                    Haptics.soft()
                    Task { try? await conn.post("/api/pc/find", json: [String: String]()); note = "Your PC is beeping." }
                } label: { Label("Find my PC", systemImage: "speaker.wave.3.fill").frame(maxWidth: .infinity).padding(.vertical, 4) }
                    .buttonStyle(.glass)
                HStack {
                    TextField("Link to open on the PC", text: $link).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    Button {
                        let l = link.trimmingCharacters(in: .whitespaces)
                        Task { try? await conn.post("/api/pc/open", json: ["url": l]); note = "Opened on your PC."; link = "" }
                    } label: { Image(systemName: "arrow.up.forward.app") }
                        .buttonStyle(.glass).disabled(!link.lowercased().hasPrefix("http"))
                }
                .padding(12).glassEffect(.regular, in: .rect(cornerRadius: 16))
                if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
}

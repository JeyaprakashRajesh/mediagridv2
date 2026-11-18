import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject var conn: Connection
    @State private var host = ""
    @State private var email = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?
    @State private var appear = false
    @State private var spin = false
    @FocusState private var focus: Field?
    enum Field { case host, email, password }

    var body: some View {
        ZStack {
            AppBackground()
            ScrollView {
                VStack(spacing: 26) {
                    logo
                        .padding(.top, 50)
                    VStack(spacing: 8) {
                        Text("MediaGrid").font(.system(size: 40, weight: .heavy, design: .rounded))
                            .foregroundStyle(.white)
                        Text("Your PC's music, photos and files —\nright here on your iPhone.")
                            .multilineTextAlignment(.center).font(.callout).foregroundStyle(.secondary)
                    }
                    .opacity(appear ? 1 : 0).offset(y: appear ? 0 : 12)

                    if !conn.discovered.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Found on your Wi-Fi", systemImage: "wifi").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                            GlassEffectContainer(spacing: 10) {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 10) {
                                        ForEach(conn.discovered) { pc in
                                            Button {
                                                withAnimation(.snappy) { host = "\(pc.host):\(pc.port)" }
                                                focus = .email
                                                Haptics.tap()
                                            } label: {
                                                Label(pc.name, systemImage: "desktopcomputer")
                                                    .font(.subheadline.weight(.semibold))
                                                    .padding(.horizontal, 16).padding(.vertical, 11)
                                            }
                                            .glassEffect(host == "\(pc.host):\(pc.port)" ? .regular.tint(Theme.violet.opacity(0.5)).interactive() : .regular.interactive(), in: .capsule)
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 24)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    }

                    VStack(spacing: 12) {
                        field("PC address (Wi-Fi or Tailscale IP)", text: $host, icon: "network", f: .host)
                            .keyboardType(.URL)
                        field("Email", text: $email, icon: "envelope.fill", f: .email)
                            .keyboardType(.emailAddress).textContentType(.username)
                        field("Password", text: $password, icon: "lock.fill", f: .password, secure: true)
                            .textContentType(.password)
                    }
                    .padding(.horizontal, 24)

                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote).foregroundStyle(.secondary)
                            .padding(.horizontal, 28).transition(.opacity)
                    }

                    Button(action: signIn) {
                        HStack {
                            if busy { ProgressView().tint(.white) }
                            Text(busy ? "Connecting…" : "Connect to PC").font(.headline)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 6)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(Theme.violet)
                    .controlSize(.large)
                    .disabled(busy || host.isEmpty || email.isEmpty || password.isEmpty)
                    .padding(.horizontal, 24)

                    Text("Use the email and password you set in MediaGrid on your PC (Profile tab). Over Tailscale, enter the 100.x address shown there.")
                        .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center).padding(.horizontal, 36)
                }
                .padding(.bottom, 40)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .onAppear {
            conn.startDiscovery()
            if host.isEmpty { host = conn.host }
            if email.isEmpty { email = conn.email }
            withAnimation(.spring(duration: 0.9).delay(0.1)) { appear = true }
        }
        .onChange(of: conn.discovered) { _, d in
            if host.isEmpty, let first = d.first { host = "\(first.host):\(first.port)" }
        }
    }

    private var logo: some View {
        ZStack {
            Circle().fill(Theme.brand).frame(width: 190).blur(radius: 60).opacity(0.55)
                .scaleEffect(spin ? 1.1 : 0.9)
            Image("Logo").resizable().frame(width: 132, height: 132)
                .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
                .shadow(color: Theme.violet.opacity(0.6), radius: 30, y: 12)
                .rotation3DEffect(.degrees(appear ? 0 : -25), axis: (x: 1, y: 1, z: 0))
                .scaleEffect(appear ? 1 : 0.7)
        }
        .onAppear { withAnimation(.easeInOut(duration: 3).repeatForever()) { spin = true } }
    }

    private func field(_ title: String, text: Binding<String>, icon: String, f: Field, secure: Bool = false) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 22)
            Group {
                if secure { SecureField(title, text: text) } else { TextField(title, text: text) }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .focused($focus, equals: f)
            .submitLabel(f == .password ? .go : .next)
            .onSubmit {
                switch f {
                case .host: focus = .email
                case .email: focus = .password
                case .password: signIn()
                }
            }
        }
        .padding(.horizontal, 18).frame(height: 56)
        .glassEffect(focus == f ? .regular.tint(Theme.violet.opacity(0.25)).interactive() : .regular.interactive(), in: .rect(cornerRadius: 18))
        .animation(.snappy, value: focus)
    }

    private func signIn() {
        guard !busy else { return }
        busy = true
        error = nil
        focus = nil
        Task {
            do {
                try await conn.signIn(host: host, email: email, password: password)
                Haptics.success()
            } catch {
                withAnimation { self.error = error.localizedDescription }
            }
            busy = false
        }
    }
}

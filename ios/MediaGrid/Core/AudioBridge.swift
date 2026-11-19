import Foundation

/// "Hear PC sound on iPhone" as a setting: the PC's audio stream stays connected (and reconnects) whenever the PC is
/// online, not only during Remote desktop. It keeps playing after you leave the app (audio background mode) but, like any
/// iOS app, it cannot run after the app is swiped away.
/// What the PC app allows (its Settings).
struct StreamOptions: Decodable { var acceptPhoneStream: Bool; var sharePcAudio: Bool }

@MainActor
final class AudioBridge: ObservableObject {
    static let shared = AudioBridge()
    @Published private(set) var listening = false
    @Published private(set) var note: String?   // why it isn't playing
    private let audio = PCAudio()
    private var retry: Task<Void, Never>?

    var enabled: Bool { UserDefaults.standard.bool(forKey: "mg.bridgePC") }

    /// Call when the setting or the connection changes.
    func apply() {
        retry?.cancel()
        if enabled && Connection.shared.state == .online { start() } else { stop() }
    }

    private func start() {
        guard !listening else { return }
        listening = true
        note = nil
        Task {
            let o: StreamOptions? = try? await Connection.shared.get("/api/stream/options")
            guard listening else { return }   // switched off meanwhile
            if o?.sharePcAudio == false {
                listening = false
                note = "Turn on “Share this PC's sound with the iPhone” in the PC app, under Settings."
                return
            }
            let c = Connection.shared
            audio.onEnd = { [weak self] in Task { @MainActor in self?.dropped() } }
            audio.start(url: c.url("/api/audio/stream"), session: c.session, record: PhoneStreamer.shared.running)
        }
    }

    private func dropped() {
        listening = false
        retry?.cancel()
        retry = Task {
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { apply() }
        }
    }

    func stop() {
        retry?.cancel()
        audio.onEnd = nil
        audio.stop()
        listening = false
    }
}

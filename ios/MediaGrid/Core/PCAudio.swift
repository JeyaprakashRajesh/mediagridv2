import AVFoundation
import Foundation

/// Plays the PC's sound on the phone during remote desktop. The PC sends 16-bit stereo PCM over a WebSocket:
/// first byte 0 = JSON header {"rate":N}, first byte 1 = samples. A short buffer smooths Wi-Fi jitter;
/// if the phone falls far behind it drops audio so the sound stays in step with the picture.
final class PCAudio: @unchecked Sendable {
    private var task: URLSessionWebSocketTask?
    private var engine: AVAudioEngine?
    private var node: AVAudioPlayerNode?
    private var format: AVAudioFormat?
    private let lock = NSLock()
    private var queued = 0
    private var playing = false

    func start(url: URL, session: URLSession) {
        stop()
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        let t = session.webSocketTask(with: url)
        task = t
        t.resume()
        receive(t)
    }

    func stop() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        node?.stop()
        engine?.stop()
        node = nil; engine = nil; format = nil
        lock.lock(); queued = 0; playing = false; lock.unlock()
    }

    private func receive(_ t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            guard let self, self.task === t, case .success(let msg) = result else { return }
            if case .data(let d) = msg, let kind = d.first {
                if kind == 0 { self.setup(Data(d.dropFirst())) } else if kind == 1 { self.play(Data(d.dropFirst())) }
            }
            self.receive(t)
        }
    }

    private func setup(_ json: Data) {
        guard let o = try? JSONSerialization.jsonObject(with: json) as? [String: Any], let rate = o["rate"] as? Double,
              let f = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: false) else { return }
        let e = AVAudioEngine(), n = AVAudioPlayerNode()
        e.attach(n)
        e.connect(n, to: e.mainMixerNode, format: f)
        guard (try? e.start()) != nil else { return }
        engine = e; node = n; format = f
    }

    private func play(_ pcm: Data) {
        guard let n = node, let f = format else { return }
        let frames = pcm.count / 4
        guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: AVAudioFrameCount(frames)),
              let l = buf.floatChannelData?[0], let r = buf.floatChannelData?[1] else { return }
        buf.frameLength = AVAudioFrameCount(frames)
        pcm.withUnsafeBytes { raw in
            let s = raw.bindMemory(to: Int16.self)
            for i in 0..<frames { l[i] = Float(Int16(littleEndian: s[i * 2])) / 32768; r[i] = Float(Int16(littleEndian: s[i * 2 + 1])) / 32768 }
        }
        lock.lock()
        if queued > 40 { lock.unlock(); return }            // far behind: drop to stay in sync
        queued += 1
        let start = !playing && queued >= 6                  // ~60 ms of audio queued before starting
        if start { playing = true }
        lock.unlock()
        n.scheduleBuffer(buf) { [weak self] in self?.lock.lock(); self?.queued -= 1; self?.lock.unlock() }
        if start { n.play() }
    }
}

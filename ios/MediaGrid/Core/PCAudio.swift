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
    var onEnd: (() -> Void)?   // the connection dropped (not called by stop())

    func start(url: URL, session: URLSession, record: Bool = false) {
        stop()
        // keep the microphone path alive when the iPhone mic is being shared at the same time
        let s = AVAudioSession.sharedInstance()
        if record { try? s.setCategory(.playAndRecord, mode: .videoChat, options: [.defaultToSpeaker, .mixWithOthers]) }
        else { try? s.setCategory(.playback, mode: .default, options: [.mixWithOthers]) }
        try? s.setActive(true)
        let t = session.webSocketTask(with: url)
        task = t
        t.resume()
        receive(t)
    }

    func stop() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        lock.lock()
        let n = node
        let e = engine
        node = nil
        engine = nil
        format = nil
        queued = 0
        playing = false
        lock.unlock()
        n?.stop()
        e?.stop()
    }

    private func receive(_ t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            guard let self, self.task === t else { return }
            guard case .success(let msg) = result else { self.task = nil; self.onEnd?(); return }
            if case .data(let d) = msg, let kind = d.first {
                if kind == 0 { self.setup(Data(d.dropFirst())) } else if kind == 1 { self.play(Data(d.dropFirst())) }
            }
            self.receive(t)
        }
    }

    private func setup(_ json: Data) {
        guard let o = try? JSONSerialization.jsonObject(with: json) as? [String: Any], let rate = o["rate"] as? Double,
              rate > 0, let f = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: false) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let oldNode = self.node
            let oldEngine = self.engine
            self.node = nil
            self.engine = nil
            self.lock.unlock()

            oldNode?.stop()
            oldEngine?.stop()

            let e = AVAudioEngine()
            let n = AVAudioPlayerNode()
            e.attach(n)
            e.connect(n, to: e.mainMixerNode, format: f)
            do {
                try e.start()
                self.lock.lock()
                self.engine = e
                self.node = n
                self.format = f
                self.lock.unlock()
            } catch {}
        }
    }

    private func play(_ pcm: Data) {
        lock.lock()
        guard let n = node, let f = format, engine?.isRunning == true else {
            lock.unlock()
            return
        }
        lock.unlock()

        let frames = pcm.count / 4
        guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: AVAudioFrameCount(frames)),
              let l = buf.floatChannelData?[0], let r = buf.floatChannelData?[1] else { return }
        buf.frameLength = AVAudioFrameCount(frames)

        pcm.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            for i in 0..<frames {
                let leftOffset = i * 4
                let rightOffset = leftOffset + 2
                if rightOffset + 1 < raw.count {
                    let s0 = Int16(littleEndian: base.load(fromByteOffset: leftOffset, as: Int16.self))
                    let s1 = Int16(littleEndian: base.load(fromByteOffset: rightOffset, as: Int16.self))
                    l[i] = Float(s0) / 32768.0
                    r[i] = Float(s1) / 32768.0
                }
            }
        }

        lock.lock()
        guard node === n, engine?.isRunning == true else {
            lock.unlock()
            return
        }
        if queued > 40 { lock.unlock(); return }            // far behind: drop to stay in sync
        queued += 1
        let shouldStart = !playing && queued >= 6           // ~60 ms of audio queued before starting
        if shouldStart { playing = true }
        lock.unlock()

        n.scheduleBuffer(buf) { [weak self] in
            self?.lock.lock()
            self?.queued -= 1
            self?.lock.unlock()
        }
        if shouldStart { n.play() }
    }
}

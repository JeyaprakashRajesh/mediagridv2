import AVFoundation
import CoreImage
import UIKit

/// Sends this iPhone's camera (30 fps JPEG frames) and/or microphone (16 kHz mono PCM) to the PC over ONE persistent
/// WebSocket (no per-frame HTTP requests). The PC re-serves them as a webcam stream and a mic feed.
/// Camera needs the app in the foreground; audio keeps going with the "audio" background mode.
@MainActor
final class PhoneStreamer: ObservableObject {
    static let shared = PhoneStreamer()
    @Published private(set) var running = false
    @Published var error: String?

    private let capture = AVCaptureSession()
    private var link: CamLink?
    private var sink: FrameSink?
    private var engine: AVAudioEngine?
    private var hasTap = false

    func start(camera: Bool, mic: Bool, back: Bool) async {
        guard !running, camera || mic else { return }
        error = nil
        if camera {
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            if !granted { error = "Allow camera access for MediaGrid in Settings."; return }
        }
        if mic {
            let granted: Bool
            if #available(iOS 17.0, *) {
                granted = await AVAudioApplication.requestRecordPermission()
            } else {
                granted = await withCheckedContinuation { cont in
                    AVAudioSession.sharedInstance().requestRecordPermission { cont.resume(returning: $0) }
                }
            }
            if !granted { error = "Allow microphone access for MediaGrid in Settings."; return }
        }
        let c = Connection.shared
        if let o: StreamOptions = try? await c.get("/api/stream/options"), !o.acceptPhoneStream {
            error = "Turn on “Accept iPhone camera & microphone” in the PC app, under Settings."
            return
        }
        let link = CamLink(url: c.url("/api/cam/stream"), session: c.session)
        self.link = link
        if camera { guard startCamera(back: back, link: link) else { link.close(); self.link = nil; return } }
        if mic { guard startMic(link: link) else { stopCamera(); link.close(); self.link = nil; return } }
        running = true
        UIApplication.shared.isIdleTimerDisabled = true
        try? await c.post("/api/cam/state", json: ["camera": camera, "mic": mic])
    }

    func stop() async {
        stopCamera()
        if hasTap {
            engine?.inputNode.removeTap(onBus: 0)
            hasTap = false
        }
        engine?.stop()
        engine = nil
        link?.close()
        link = nil
        running = false
        UIApplication.shared.isIdleTimerDisabled = false
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)   // back to music mode
        try? await Connection.shared.post("/api/cam/state", json: ["camera": false, "mic": false])
    }

    // MARK: camera

    private func startCamera(back: Bool, link: CamLink) -> Bool {
        capture.beginConfiguration()
        if capture.canSetSessionPreset(.hd1280x720) {
            capture.sessionPreset = .hd1280x720
        } else if capture.canSetSessionPreset(.high) {
            capture.sessionPreset = .high
        }
        guard let dev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: back ? .back : .front),
              let input = try? AVCaptureDeviceInput(device: dev), capture.canAddInput(input) else {
            capture.commitConfiguration(); error = "Camera not available."; return false
        }
        capture.addInput(input)
        if (try? dev.lockForConfiguration()) != nil {       // steady 30 fps = smooth motion
            let d = CMTime(value: 1, timescale: 30)
            dev.activeVideoMinFrameDuration = d
            dev.activeVideoMaxFrameDuration = d
            dev.unlockForConfiguration()
        }
        let out = AVCaptureVideoDataOutput()
        out.alwaysDiscardsLateVideoFrames = true   // never queue up: a late frame is dropped, so the picture stays live
        let s = FrameSink(link: link)
        out.setSampleBufferDelegate(s, queue: DispatchQueue(label: "mediagrid.cam"))
        guard capture.canAddOutput(out) else { capture.commitConfiguration(); error = "Camera not available."; return false }
        capture.addOutput(out)
        capture.commitConfiguration()
        sink = s
        let cap = capture
        DispatchQueue.global().async { cap.startRunning() }   // blocking call, keep it off the main thread
        return true
    }

    private func stopCamera() {
        if capture.isRunning { capture.stopRunning() }
        capture.beginConfiguration()
        capture.inputs.forEach { capture.removeInput($0) }
        capture.outputs.forEach { capture.removeOutput($0) }
        capture.commitConfiguration()
        sink = nil
    }

    // MARK: microphone

    private func startMic(link: CamLink) -> Bool {
        do {
            let s = AVAudioSession.sharedInstance()
            try s.setCategory(.playAndRecord, mode: .videoChat, options: [.defaultToSpeaker, .mixWithOthers, .allowBluetooth])
            try s.setActive(true)
        } catch { self.error = "Microphone not available: \(error.localizedDescription)"; return false }
        let eng = AVAudioEngine()
        let inFmt = eng.inputNode.inputFormat(forBus: 0)
        guard inFmt.sampleRate > 0, inFmt.channelCount > 0,
              let outFmt = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true),
              let conv = AVAudioConverter(from: inFmt, to: outFmt) else { error = "Microphone format not supported."; return false }

        if hasTap {
            eng.inputNode.removeTap(onBus: 0)
            hasTap = false
        }
        eng.inputNode.installTap(onBus: 0, bufferSize: 1024, format: inFmt) { buf, _ in
            let frameRatio = 16000.0 / inFmt.sampleRate
            let cap = AVAudioFrameCount(Double(buf.frameLength) * frameRatio) + 16
            guard cap > 0, let out = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: cap) else { return }
            var fed = false
            var convErr: NSError?
            conv.convert(to: out, error: &convErr) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true; status.pointee = .haveData; return buf
            }
            guard convErr == nil, out.frameLength > 0, let p = out.int16ChannelData?[0] else { return }
            link.sendAudio(Data(bytes: p, count: Int(out.frameLength) * 2))
        }
        hasTap = true

        do {
            try eng.start()
        } catch {
            eng.inputNode.removeTap(onBus: 0)
            hasTap = false
            self.error = "Could not start microphone: \(error.localizedDescription)"
            return false
        }
        engine = eng
        return true
    }
}

/// One WebSocket to the PC. First byte of every message: 1 = JPEG frame, 2 = PCM audio.
final class CamLink: @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    private let lock = NSLock()
    private var inFlight = 0

    init(url: URL, session: URLSession) {
        task = session.webSocketTask(with: url)
        task.resume()
    }

    /// Two frames may be on the wire at once (keeps the link busy = higher fps); more than that are dropped.
    func sendFrame(_ jpg: Data) {
        lock.lock()
        if inFlight >= 2 { lock.unlock(); return }
        inFlight += 1
        lock.unlock()
        task.send(.data(Data([1]) + jpg)) { [weak self] _ in
            self?.lock.lock(); self?.inFlight -= 1; self?.lock.unlock()
        }
    }

    func sendAudio(_ pcm: Data) { task.send(.data(Data([2]) + pcm)) { _ in } }

    func close() { task.cancel(with: .goingAway, reason: nil) }
}

/// Camera frames -> JPEG (on the GPU) -> PC.
final class FrameSink: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let link: CamLink
    private let ci = CIContext(options: [.priorityRequestLow: true])

    init(link: CamLink) { self.link = link }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // Avoid GPU/Metal calls when in background to prevent OS termination (0x8badf00d)
        guard UIApplication.shared.applicationState != .background,
              let px = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ciImage = CIImage(cvPixelBuffer: px)
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let jpg = ci.jpegRepresentation(of: ciImage, colorSpace: cs,
                                              options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.6]) else { return }
        link.sendFrame(jpg)
    }
}

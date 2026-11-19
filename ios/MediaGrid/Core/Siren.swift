import AVFoundation
import MediaPlayer
import UIKit

/// "Find my iPhone" from the PC: a loud two-tone siren at full system volume until you tap "Found it".
@MainActor
final class Siren {
    static let shared = Siren()
    private var engine: AVAudioEngine?
    private var volume: MPVolumeView?

    func start() {
        guard engine == nil else { return }
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .default)
        try? s.setActive(true)
        maxVolume()
        let e = AVAudioEngine()
        let rate = e.outputNode.outputFormat(forBus: 0).sampleRate
        var phase = 0.0, t = 0.0
        let node = AVAudioSourceNode { _, _, frames, abl in
            let bufs = UnsafeMutableAudioBufferListPointer(abl)
            for i in 0..<Int(frames) {
                t += 1 / rate
                let f = Int(t * 2.5) % 2 == 0 ? 880.0 : 1320.0     // two-tone wail
                phase += 2 * .pi * f / rate
                if phase > 2 * .pi { phase -= 2 * .pi }
                let v: Float = sin(phase) > 0 ? 0.9 : -0.9           // square wave: as loud as it gets
                for b in bufs { b.mData?.assumingMemoryBound(to: Float.self)[i] = v }
            }
            return noErr
        }
        e.attach(node)
        e.connect(node, to: e.mainMixerNode, format: AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
        try? e.start()
        engine = e
    }

    func stop() {
        engine?.stop()
        engine = nil
        volume?.removeFromSuperview()
        volume = nil
    }

    /// iOS has no public volume setter; the hidden slider inside MPVolumeView is the usual way.
    private func maxVolume() {
        let v = MPVolumeView(frame: CGRect(x: -2000, y: -2000, width: 1, height: 1))
        volume = v
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first?.addSubview(v)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { v.subviews.compactMap { $0 as? UISlider }.first?.value = 1 }
    }
}

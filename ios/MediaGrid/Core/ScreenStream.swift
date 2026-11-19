import AVFoundation
import SwiftUI
import UIKit

/// Parsec-style desktop stream: the PC sends H.264 over one WebSocket; the phone hands it straight to
/// AVSampleBufferDisplayLayer, which decodes on the hardware decoder. Far less data and delay than JPEG frames.
@MainActor
final class ScreenStream: ObservableObject {
    @Published private(set) var connected = false
    @Published private(set) var size = CGSize(width: 16, height: 10)
    @Published private(set) var fps = 0.0
    @Published var error: String?
    let display = H264Display()
    private var task: URLSessionWebSocketTask?
    private var frames = 0
    private var since = Date()

    func start(w: Int, fps: Int, kbps: Int) {
        stop()
        error = nil
        let c = Connection.shared
        let t = c.session.webSocketTask(with: c.url("/api/screen/stream", ["w": "\(w)", "fps": "\(fps)", "kbps": "\(kbps)"]))
        task = t
        connected = true
        display.onSize = { [weak self] s in Task { @MainActor in self?.size = s } }
        display.onNeedKey = { [weak t] in t?.send(.string("key")) { _ in } }
        t.resume()
        Self.receive(t, display, onFrame: { [weak self] in Task { @MainActor in self?.tick() } },
                     onEnd: { [weak self] e in Task { @MainActor in self?.ended(e) } })
    }

    func stop() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        connected = false
        fps = 0
        display.reset()
    }

    private func tick() {
        frames += 1
        let dt = Date().timeIntervalSince(since)
        if dt > 1 { fps = Double(frames) / dt; frames = 0; since = Date() }
    }

    private func ended(_ e: Error) {
        guard task != nil else { return }   // we stopped it ourselves
        error = e.localizedDescription
        stop()
    }

    private nonisolated static func receive(_ t: URLSessionWebSocketTask, _ display: H264Display,
                                            onFrame: @escaping @Sendable () -> Void, onEnd: @escaping @Sendable (Error) -> Void) {
        t.receive { result in
            switch result {
            case .success(.data(let d)):
                display.feed(d)
                onFrame()
                receive(t, display, onFrame: onFrame, onEnd: onEnd)
            case .success:
                receive(t, display, onFrame: onFrame, onEnd: onEnd)
            case .failure(let e):
                onEnd(e)
            }
        }
    }
}

/// Annex-B H.264 access units -> CMSampleBuffers on an AVSampleBufferDisplayLayer.
final class H264Display: @unchecked Sendable {
    let layer = AVSampleBufferDisplayLayer()
    var onSize: ((CGSize) -> Void)?
    var onNeedKey: (() -> Void)?
    private var fmt: CMVideoFormatDescription?
    private var sps: Data?
    private var pps: Data?

    init() { layer.videoGravity = .resizeAspect }

    func reset() { fmt = nil; sps = nil; pps = nil; layer.flushAndRemoveImage() }

    func feed(_ au: Data) {
        var avcc = Data()
        for nal in Self.nals(au) {
            switch (nal.first ?? 0) & 0x1F {
            case 7: if nal != sps { sps = nal; fmt = nil }
            case 8: if nal != pps { pps = nal; fmt = nil }
            case 1, 5:
                var len = UInt32(nal.count).bigEndian
                avcc.append(Data(bytes: &len, count: 4))
                avcc.append(nal)
            default: break
            }
        }
        if fmt == nil, let sps, let pps { fmt = Self.format(sps, pps); if let f = fmt { let d = CMVideoFormatDescriptionGetDimensions(f); onSize?(CGSize(width: Int(d.width), height: Int(d.height))) } }
        guard let fmt, !avcc.isEmpty, let sb = Self.sample(avcc, fmt) else { return }
        if layer.status == .failed { layer.flush(); onNeedKey?(); return }   // decoder hiccup: restart from a full frame
        layer.enqueue(sb)
    }

    private static func format(_ sps: Data, _ pps: Data) -> CMVideoFormatDescription? {
        var out: CMVideoFormatDescription?
        sps.withUnsafeBytes { s in
            pps.withUnsafeBytes { p in
                guard let sp = s.bindMemory(to: UInt8.self).baseAddress, let pp = p.bindMemory(to: UInt8.self).baseAddress else { return }
                let ptrs = [sp, pp]
                let sizes = [sps.count, pps.count]
                CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: 2, parameterSetPointers: ptrs,
                                                                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &out)
            }
        }
        return out
    }

    private static func sample(_ avcc: Data, _ fmt: CMVideoFormatDescription) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        let n = avcc.count
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: n, blockAllocator: nil, customBlockSource: nil,
                                                 offsetToData: 0, dataLength: n, flags: 0, blockBufferOut: &block) == noErr, let block else { return nil }
        let ok = avcc.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: n) }
        guard ok == noErr else { return nil }
        var sb: CMSampleBuffer?
        var size = n
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: fmt, sampleCount: 1, sampleTimingEntryCount: 0,
                                        sampleTimingArray: nil, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sb) == noErr, let sb else { return nil }
        if let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true) as? [NSMutableDictionary], let d = arr.first {
            d[kCMSampleAttachmentKey_DisplayImmediately] = true   // live stream: show as soon as decoded
        }
        return sb
    }

    /// Splits an Annex-B stream (00 00 01 / 00 00 00 01 start codes) into NAL units.
    static func nals(_ d: Data) -> [Data] {
        let b = [UInt8](d)
        var out: [Data] = []
        var start = -1
        var i = 0
        while i + 2 < b.count {
            if b[i] == 0, b[i + 1] == 0, b[i + 2] == 1 {
                if start >= 0 { var end = i; if end > start, b[end - 1] == 0 { end -= 1 }; out.append(Data(b[start..<end])) }
                start = i + 3
                i += 3
            } else { i += 1 }
        }
        if start >= 0, start < b.count { out.append(Data(b[start...])) }
        return out
    }
}

/// Hosts the display layer.
struct StreamLayerView: UIViewRepresentable {
    let display: H264Display

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .black
        v.layer.addSublayer(display.layer)
        return v
    }

    func updateUIView(_ v: UIView, context: Context) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        display.layer.frame = v.bounds
        CATransaction.commit()
    }
}

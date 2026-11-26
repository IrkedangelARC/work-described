//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation
import AVFoundation
import CoreMedia
import QuartzCore

/// A camera WITH its sound, for the raw share source (2026-09-24: presentation computers switched through
/// an ATEM Mini, whose USB out is a UVC camera plus a USB audio device; `startShareCamera` is picture only and
/// "share sound" sends the Mac's own output, not that input).
///
/// One AVCaptureSession carries the camera AND the chosen input, so both outputs stamp their buffers on the
/// SAME clock (the session's, converted to host time). Frames become I420 as they arrive; audio is asked of the
/// output as 48 kHz, 16-bit, interleaved stereo (no AGC, no noise suppression, no echo processing: a capture
/// output is the device's raw signal, voice processing exists only on a VPIO unit, which this never uses).
/// `CaptureAligner` then holds the faster stream so both leave at `capture time + the slower path's latency`.
final class CameraFeed: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    static let audioRate = 48000
    static let audioChannels = 2

    let videoQueue = DispatchQueue(label: "arc.zoom.preview.camera.video", qos: .userInteractive)
    let audioQueue = DispatchQueue(label: "arc.zoom.preview.camera.audio", qos: .userInteractive)
    private let sendQueue = DispatchQueue(label: "arc.zoom.preview.camera.send", qos: .userInteractive)
    private let lock = NSLock()
    private var sink: ShareSink?
    private var aligner = CaptureAligner()
    private var peak: Float = 0
    private var clock: CMClock?
    private var chunker = AudioChunker(channels: CameraFeed.audioChannels, rate: CameraFeed.audioRate)
    // sendQueue only:
    private var queue: [(release: Double, item: Item)] = []
    private var timer: DispatchSourceTimer?
    private var counters = (frames: 0, chunks: 0)
    private var warnedFormat = false
    private enum Item { case frame(Data, Int, Int), audio([Int16]) }

    func setClock(_ c: CMClock?) { lock.lock(); clock = c; lock.unlock() }

    func attach(_ s: ShareSink) {
        lock.lock(); sink = s; aligner = CaptureAligner(); chunker.reset(); lock.unlock()
        sendQueue.async {
            guard self.timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: self.sendQueue)
            t.schedule(deadline: .now(), repeating: .milliseconds(4), leeway: .milliseconds(1))
            t.setEventHandler { [weak self] in self?.drain() }
            t.resume()
            self.timer = t
        }
    }

    func detach() {
        lock.lock(); sink = nil; lock.unlock()
        sendQueue.async { self.timer?.cancel(); self.timer = nil; self.queue.removeAll() }
    }

    var attached: Bool { lock.lock(); defer { lock.unlock() }; return sink != nil }
    func takePeak() -> Float { lock.lock(); defer { peak = 0; lock.unlock() }; return peak }
    var stats: (frames: Int, chunks: Int, audioHoldMs: Int) {
        lock.lock(); defer { lock.unlock() }
        return (counters.frames, counters.chunks, Int(aligner.audioHold * 1000))
    }

    /// A buffer's presentation time on the host clock, seconds (CACurrentMediaTime's timeline).
    private func hostTime(_ sb: CMSampleBuffer) -> Double {
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        lock.lock(); let c = clock; lock.unlock()
        guard let c else { return pts.seconds }
        return CMSyncConvertTime(pts, from: c, to: CMClockGetHostTimeClock()).seconds
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        let arrived = CACurrentMediaTime()
        if output is AVCaptureVideoDataOutput { video(sb, arrived: arrived) } else { audio(sb, arrived: arrived) }
    }

    private func video(_ sb: CMSampleBuffer, arrived: Double) {
        lock.lock(); let on = sink != nil; lock.unlock()
        guard on, let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        let captured = hostTime(sb)
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb) & ~1, h = CVPixelBufferGetHeight(pb) & ~1
        var data = Data(count: I420.byteCount(width: w, height: h))
        let ok: Bool = data.withUnsafeMutableBytes { raw in
            let out = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            if CVPixelBufferGetPlaneCount(pb) == 2, let y = CVPixelBufferGetBaseAddressOfPlane(pb, 0), let uv = CVPixelBufferGetBaseAddressOfPlane(pb, 1) {
                I420.fromNV12(y: y.assumingMemoryBound(to: UInt8.self), yStride: CVPixelBufferGetBytesPerRowOfPlane(pb, 0),
                              uv: uv.assumingMemoryBound(to: UInt8.self), uvStride: CVPixelBufferGetBytesPerRowOfPlane(pb, 1), width: w, height: h, into: out)
                return true
            }
            if CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_32BGRA, let base = CVPixelBufferGetBaseAddress(pb) {
                I420.fromBGRA(base.assumingMemoryBound(to: UInt8.self), stride: CVPixelBufferGetBytesPerRow(pb), width: w, height: h, into: out)
                return true
            }
            return false
        }
        guard ok else { return }
        lock.lock()
        aligner.observe(.video, captured: captured, arrived: arrived)
        let release = aligner.release(captured: captured)
        lock.unlock()
        let item = Item.frame(data, w, h)
        sendQueue.async { self.enqueue(release, item) }
    }

    private func audio(_ sb: CMSampleBuffer, arrived: Double) {
        guard let fmt = CMSampleBufferGetFormatDescription(sb), let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(fmt) else { return }
        let asbd = asbdPtr.pointee
        let frames = CMSampleBufferGetNumSamples(sb)
        guard frames > 0 else { return }
        var blockBuffer: CMBlockBuffer?
        var list = AudioBufferList()
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sb, bufferListSizeNeededOut: nil, bufferListOut: &list, bufferListSize: MemoryLayout<AudioBufferList>.size,
                                                                      blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &blockBuffer) == noErr,
              let d = list.mBuffers.mData else { return }
        let inCh = Int(asbd.mChannelsPerFrame)
        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let interleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0 || inCh == 1
        var samples: [Int16]
        if !isFloat, asbd.mBitsPerChannel == 16, interleaved {
            samples = ShareAudio.remap(int16: Array(UnsafeBufferPointer(start: d.assumingMemoryBound(to: Int16.self), count: frames * inCh)), inChannels: inCh, outChannels: Self.audioChannels)
        } else if isFloat, asbd.mBitsPerChannel == 32, interleaved {
            samples = ShareAudio.int16(interleavedFloat: Array(UnsafeBufferPointer(start: d.assumingMemoryBound(to: Float.self), count: frames * inCh)), inChannels: inCh, outChannels: Self.audioChannels)
        } else {
            if !warnedFormat { warnedFormat = true; ShowLog.error("preview: audio input format not handled (\(asbd.mBitsPerChannel)-bit, flags \(asbd.mFormatFlags), \(inCh) ch)") }
            return
        }
        let p = ShareAudio.peak(int16: samples)
        let rate = Int(asbd.mSampleRate.rounded())
        lock.lock()
        peak = max(peak, p)
        guard sink != nil, rate == Self.audioRate else { lock.unlock(); return }
        let captured = hostTime(sb)
        aligner.observe(.audio, captured: captured, arrived: arrived)
        // Each 10 ms chunk keeps its own capture time: the first sample of the buffer, plus its offset.
        let startOffset = Double(chunker.pending.count / Self.audioChannels) / Double(Self.audioRate)
        let chunks = chunker.push(samples)
        let releases = chunks.indices.map { aligner.release(captured: captured - startOffset + Double($0) * 0.01) }
        lock.unlock()
        sendQueue.async { for (c, r) in zip(chunks, releases) { self.enqueue(r, .audio(c)) } }
    }

    /// sendQueue: keep the queue in release order, send whatever is due.
    private func enqueue(_ release: Double, _ item: Item) {
        let i = queue.lastIndex { $0.release <= release }.map { $0 + 1 } ?? 0
        queue.insert((release, item), at: i)
        if queue.count > 400 { queue.removeFirst(queue.count - 400) }   // a stalled sender never grows memory without bound
    }

    private func drain() {
        lock.lock(); let target = sink; lock.unlock()
        guard let target else { queue.removeAll(); return }
        let now = CACurrentMediaTime()
        while let first = queue.first, first.release <= now {
            queue.removeFirst()
            switch first.item {
            case .frame(var data, let w, let h):
                let n = data.count
                data.withUnsafeMutableBytes { raw in target.sendFrame(raw.baseAddress!.assumingMemoryBound(to: UInt8.self), count: n, width: w, height: h, fullRange: false) }
                lock.lock(); counters.frames += 1; lock.unlock()
            case .audio(let s):
                target.sendAudio(s, rate: Self.audioRate, channels: Self.audioChannels)
                lock.lock(); counters.chunks += 1; lock.unlock()
            }
        }
    }
}

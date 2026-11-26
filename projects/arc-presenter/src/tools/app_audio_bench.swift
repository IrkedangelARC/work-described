//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

// V4 bench: is an app actually putting audio out? Captures ONE app's audio with
// ScreenCaptureKit (no video) and prints RMS per half second, so "no sound"
// reports can be measured at the source rather than by ear.
// Usage: swift app_audio_bench.swift <bundle-id> <seconds>
import AppKit
import ScreenCaptureKit
import CoreMedia

let bundleID = CommandLine.arguments[1]
let seconds = Double(CommandLine.arguments[2]) ?? 5
let app = NSApplication.shared; app.setActivationPolicy(.accessory)

final class Sink: NSObject, SCStreamOutput {
    var sumSq: Double = 0; var count: Int = 0; var peak: Float = 0; var errors = 0
    let lock = NSLock()
    var described = false
    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        if !described, let fd = CMSampleBufferGetFormatDescription(sb), let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee {
            described = true
            print(String(format: "  audio format: %.0f Hz, %d ch, %d bits, flags 0x%x (float=%d, nonInterleaved=%d)", asbd.mSampleRate, asbd.mChannelsPerFrame, asbd.mBitsPerChannel, asbd.mFormatFlags, (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0 ? 1 : 0, (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0 ? 1 : 0))
        }
        // Non-interleaved stereo arrives as TWO AudioBuffers; size the list for them.
        var needed = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sb, bufferListSizeNeededOut: &needed, bufferListOut: nil, bufferListSize: 0, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
        let raw = UnsafeMutableRawPointer.allocate(byteCount: max(needed, MemoryLayout<AudioBufferList>.size), alignment: 16)
        defer { raw.deallocate() }
        let ablPtr = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        var block: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sb, bufferListSizeNeededOut: nil, bufferListOut: ablPtr, bufferListSize: max(needed, MemoryLayout<AudioBufferList>.size), blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &block)
        guard status == noErr else { lock.lock(); errors += 1; lock.unlock(); return }
        let buffers = UnsafeMutableAudioBufferListPointer(ablPtr)
        lock.lock()
        for b in buffers {
            guard let data = b.mData else { continue }
            let n = Int(b.mDataByteSize) / MemoryLayout<Float>.size
            let p = data.bindMemory(to: Float.self, capacity: n)
            for i in 0..<n { let v = p[i]; sumSq += Double(v * v); count += 1; peak = max(peak, abs(v)) }
        }
        lock.unlock()
    }
    func take() -> (Double, Float) {
        lock.lock(); defer { lock.unlock() }
        let rms = count > 0 ? (sumSq / Double(count)).squareRoot() : 0
        let pk = peak; sumSq = 0; count = 0; peak = 0
        return (rms, pk)
    }
}
Task {
    do {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else { exit(1) }
        let target = content.applications.first(where: { $0.bundleIdentifier == bundleID })
        if bundleID != "all", target == nil { print("app \(bundleID) not found"); exit(1) }
        let cfg = SCStreamConfiguration()
        cfg.capturesAudio = true; cfg.excludesCurrentProcessAudio = true
        cfg.sampleRate = 48000; cfg.channelCount = 2
        cfg.width = 2; cfg.height = 2; cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        let sink = Sink()
        let filter = target.map { SCContentFilter(display: display, including: [$0], exceptingWindows: []) } ?? SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: cfg, delegate: nil)
        try stream.addStreamOutput(sink, type: .audio, sampleHandlerQueue: DispatchQueue(label: "audio"))
        try await stream.startCapture()
        print("capturing audio of \(target?.applicationName ?? "the whole system") for \(Int(seconds)) s (rms / peak per 0.5 s; 0.000 = silence)")
        let t0 = Date()
        while Date().timeIntervalSince(t0) < seconds {
            try? await Task.sleep(for: .milliseconds(500))
            let (rms, pk) = sink.take()
            print(String(format: "  %4.1fs  rms %.4f  peak %.3f  (abl errors %d)", Date().timeIntervalSince(t0), rms, pk, sink.errors))
        }
        try await stream.stopCapture(); exit(0)
    } catch { print("error: \(error)"); exit(1) }
}
RunLoop.current.run(until: Date().addingTimeInterval(seconds + 15)); print("timed out"); exit(1)

//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

// V4 bench: does a PowerPoint show keep RENDERING (video / animation) while a
// shielding-level window fully covers it, and can ScreenCaptureKit stream it?
// Two SCStream samples of the show window ~1.5 s apart while covered, on a
// slide that is playing a video. Unchanged pixels = the covered window froze.
// Usage: swift covered_video_capture_bench.swift <programDisplayID>
import AppKit
import ScreenCaptureKit

let progID = UInt32(CommandLine.arguments[1])!
let outDir = NSString(string: "/Volumes/DRIVE/ARC Test Media/ARC Capture Suite/v4-bench/item3/covered-video").expandingTildeInPath
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
let app = NSApplication.shared; app.setActivationPolicy(.accessory)
guard let target = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == progID }) else { print("no display"); exit(2) }
let shield = NSWindow(contentRect: target.frame, styleMask: [.borderless], backing: .buffered, defer: false, screen: target)
shield.level = NSWindow.Level(Int(CGShieldingWindowLevel())); shield.collectionBehavior = [.stationary, .canJoinAllSpaces, .ignoresCycle]
// OPAQUE=0 in the environment flags the shield non-opaque (still painted solid
// black) to test whether the window server then stops treating the show window
// as occluded, which is what stops PowerPoint drawing under an opaque shield.
let opaque = ProcessInfo.processInfo.environment["OPAQUE"] != "0"
shield.backgroundColor = .black; shield.isOpaque = opaque; shield.ignoresMouseEvents = true
print("shield isOpaque = \(opaque)")
shield.setFrame(target.frame, display: true)

func sig(_ img: CGImage) -> [Int] {
    let rep = NSBitmapImageRep(cgImage: img); var s: [Int] = []
    for y in stride(from: 0, to: rep.pixelsHigh, by: 24) { for x in stride(from: 0, to: rep.pixelsWide, by: 24) {
        if let c = rep.colorAt(x: x, y: y) { s.append(Int((c.redComponent + c.greenComponent + c.blueComponent) * 85)) } } }
    return s
}
func diff(_ a: [Int], _ b: [Int]) -> Double { guard a.count == b.count, !a.isEmpty else { return -1 }; return Double(zip(a, b).map { abs($0 - $1) }.reduce(0, +)) / Double(a.count) }
func save(_ img: CGImage, _ name: String) { try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(outDir)/\(name).png")) }

final class Sink: NSObject, SCStreamOutput {
    var frames: [(Date, CGImage)] = []
    let lock = NSLock()
    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        let ci = CIImage(cvPixelBuffer: pb)
        guard let cg = CIContext().createCGImage(ci, from: ci.extent) else { return }
        lock.lock(); frames.append((Date(), cg)); if frames.count > 400 { frames.removeFirst() }; lock.unlock()
    }
}

Task {
    do {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let show = content.windows.first(where: { ($0.title ?? "").contains("PowerPoint Slide Show") }) else { print("no show window"); exit(1) }
        let cfg = SCStreamConfiguration()
        cfg.width = Int(show.frame.width); cfg.height = Int(show.frame.height)
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 60); cfg.showsCursor = false; cfg.queueDepth = 5
        let sink = Sink()
        let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: show), configuration: cfg, delegate: nil)
        try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: DispatchQueue(label: "sck"))
        try await stream.startCapture()

        func sample(_ label: String, _ name: String) async -> (Double, Int) {
            sink.lock.lock(); sink.frames.removeAll(); sink.lock.unlock()
            try? await Task.sleep(for: .seconds(1.5))
            sink.lock.lock(); let f = sink.frames; sink.lock.unlock()
            guard let first = f.first, let last = f.last else { print("  [\(label)] NO FRAMES"); return (-1, 0) }
            let d = diff(sig(first.1), sig(last.1)); save(last.1, name)
            print("  [\(label)] \(f.count) frames in 1.5 s (\(Int(Double(f.count) / 1.5)) fps), first-vs-last pixel diff \(String(format: "%.1f", d))  (0 = frozen)")
            return (d, f.count)
        }
        let next = NSAppleScript(source: "tell application id \"com.microsoft.Powerpoint\" to go to next slide slideshow view of slide show window 1")!
        var e: NSDictionary?; next.compileAndReturnError(&e)
        @Sendable func advance() { DispatchQueue.main.async { var e: NSDictionary?; next.executeAndReturnError(&e) } }
        func sampleWithAdvance(_ label: String, _ name: String) async {
            Task { try? await Task.sleep(for: .milliseconds(400)); advance() }
            _ = await sample(label, name)
        }
        print("--- 1. uncovered, idle 1.5 s (a static slide yields 0-1 frames by design) ---")
        _ = await sample("uncovered idle", "1-idle")
        print("--- 2. uncovered, slide advanced at +0.4 s (control: the stream must deliver the change) ---")
        await sampleWithAdvance("uncovered advance", "2-advance")
        await MainActor.run { shield.orderFrontRegardless() }; try? await Task.sleep(for: .seconds(1))
        print("--- 3. COVERED by an opaque shield, slide advanced at +0.4 s ---")
        await sampleWithAdvance("covered advance", "3-covered-advance")
        print("--- 4. still covered, idle ---")
        _ = await sample("covered idle", "4-covered-idle")
        print("--- 5. still covered, advanced again ---")
        await sampleWithAdvance("covered advance 2", "5-covered-advance")
        await MainActor.run { shield.orderOut(nil) }; try? await Task.sleep(for: .seconds(1))
        print("--- 6. uncovered again, advanced ---")
        await sampleWithAdvance("uncovered advance 2", "6-uncovered-advance")
        try await stream.stopCapture()
        exit(0)
    } catch { print("error: \(error)"); exit(1) }
}
RunLoop.current.run(until: Date().addingTimeInterval(40)); print("timed out"); exit(1)

//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

// V4 bench: can Presenter show the operator what is UNDER its shield? Captures
// PowerPoint's show window with ScreenCaptureKit (desktop-independent window
// filter) while a shielding-level black window fully covers it.
// Usage: swift covered_window_capture_bench.swift <programDisplayID>
import AppKit
import ScreenCaptureKit

let progID = UInt32(CommandLine.arguments[1])!
let outDir = NSString(string: "/Volumes/DRIVE/ARC Test Media/ARC Capture Suite/v4-bench/step2/under-shield").expandingTildeInPath
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
let app = NSApplication.shared; app.setActivationPolicy(.accessory)
guard let target = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == progID }) else { print("no display \(progID)"); exit(2) }
let shield = NSWindow(contentRect: target.frame, styleMask: [.borderless], backing: .buffered, defer: false, screen: target)
shield.level = NSWindow.Level(Int(CGShieldingWindowLevel())); shield.collectionBehavior = [.stationary, .canJoinAllSpaces, .ignoresCycle]
shield.backgroundColor = .black; shield.isOpaque = true; shield.ignoresMouseEvents = true
shield.setFrame(target.frame, display: true); shield.orderFrontRegardless()
RunLoop.current.run(until: Date().addingTimeInterval(1))
print("shield up on display \(progID)")

func save(_ img: CGImage, _ name: String) -> String {
    let rep = NSBitmapImageRep(cgImage: img)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
    var s = 0, n = 0
    for y in stride(from: 0, to: rep.pixelsHigh, by: 32) { for x in stride(from: 0, to: rep.pixelsWide, by: 32) {
        if let c = rep.colorAt(x: x, y: y) { s += Int((c.redComponent + c.greenComponent + c.blueComponent) / 3 * 255); n += 1 } } }
    return "\(rep.pixelsWide)x\(rep.pixelsHigh) mean \(s / max(1, n))"
}
Task {
    do {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let show = content.windows.first(where: { ($0.title ?? "").contains("PowerPoint Slide Show") }) else { print("no PowerPoint show window"); exit(1) }
        print("show window: \(show.title ?? "") \(Int(show.frame.width))x\(Int(show.frame.height)) at (\(Int(show.frame.minX)),\(Int(show.frame.minY))) onScreen=\(show.isOnScreen)")
        let cfg = SCStreamConfiguration()
        cfg.width = Int(show.frame.width); cfg.height = Int(show.frame.height); cfg.showsCursor = false
        let winImg = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: show), configuration: cfg)
        print("  window capture under shield : \(save(winImg, "window-under-shield"))   (bright = the slide came through)")
        guard let disp = content.displays.first(where: { $0.displayID == progID }) else { exit(1) }
        let dcfg = SCStreamConfiguration(); dcfg.width = disp.width; dcfg.height = disp.height
        let dispImg = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: disp, excludingWindows: []), configuration: dcfg)
        print("  display capture (control)   : \(save(dispImg, "display-with-shield"))   (should be ~0 = black shield)")
        exit(0)
    } catch { print("error: \(error)"); exit(1) }
}
RunLoop.current.run(until: Date().addingTimeInterval(20)); print("timed out"); exit(1)

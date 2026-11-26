//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

// V4 bench, step 2: the switch itself, against a PowerPoint show that FITS the
// program display (Presenter View on, parked elsewhere). Answers the question
// step 1 could not: when the show window is FULLY covered by the shield and
// PowerPoint advances underneath, does the reveal show the new slide at once, or
// a stale frame? Also records whether Presenter View keeps tracking while the
// show is covered and PowerPoint is in the background.
//
// Usage:  swift shield_switch_bench.swift <programDisplayID> <presenterViewDisplayID>
// Screenshots are taken per display ID with CGDisplayCreateImage, so a three
// display rig does not depend on screencapture -D numbering.

import AppKit

let args = CommandLine.arguments
guard args.count >= 3, let progID = UInt32(args[1]), let pvID = UInt32(args[2]) else {
    print("usage: swift shield_switch_bench.swift <programDisplayID> <presenterViewDisplayID>"); exit(2)
}
let shotDir = NSString(string: "/Volumes/DRIVE/ARC Test Media/ARC Capture Suite/v4-bench/step2/switch").expandingTildeInPath
try? FileManager.default.createDirectory(atPath: shotDir, withIntermediateDirectories: true)

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

guard let target = NSScreen.screens.first(where: {
    ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == progID
}) else { print("display \(progID) not found"); exit(2) }
print("shield display id \(progID): \(Int(target.frame.width))x\(Int(target.frame.height))")

// Exactly how Presenter builds its program output window.
let shield = NSWindow(contentRect: target.frame, styleMask: [.borderless], backing: .buffered, defer: false, screen: target)
shield.level = NSWindow.Level(Int(CGShieldingWindowLevel()))
shield.collectionBehavior = [.stationary, .canJoinAllSpaces, .ignoresCycle]
shield.backgroundColor = .black; shield.isOpaque = true; shield.hasShadow = false; shield.ignoresMouseEvents = true
shield.setFrame(target.frame, display: true)

func settle(_ s: Double) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }
func fade(to a: CGFloat, over seconds: Double) {
    let steps = max(1, Int(seconds * 60)), from = shield.alphaValue
    for i in 1...steps { shield.alphaValue = from + (a - from) * CGFloat(i) / CGFloat(steps); settle(1.0 / 60.0) }
    shield.alphaValue = a
}
/// Screenshot one display by ID; returns a coarse pixel signature for diffing.
/// CGDisplayCreateImage is gone from the macOS 27 SDK for Swift (use
/// ScreenCaptureKit), but the Python Quartz binding still has it, so shell out.
@discardableResult
func shot(_ id: UInt32, _ tag: String) -> [UInt8] {
    let path = "\(shotDir)/\(tag)-d\(id).png"
    let py = """
    import Quartz
    from AppKit import NSBitmapImageRep, NSPNGFileType
    img = Quartz.CGDisplayCreateImage(\(id))
    rep = NSBitmapImageRep.alloc().initWithCGImage_(img)
    rep.representationUsingType_properties_(NSPNGFileType, None).writeToFile_atomically_("\(path)", True)
    """
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/env"); p.arguments = ["python3", "-c", py]
    try? p.run(); p.waitUntilExit()
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)), let rep = NSBitmapImageRep(data: data) else {
        print("  no image for display \(id)"); return []
    }
    var sig: [UInt8] = []
    for y in stride(from: 0, to: rep.pixelsHigh, by: 32) {
        for x in stride(from: 0, to: rep.pixelsWide, by: 32) {
            if let c = rep.colorAt(x: x, y: y) { sig.append(UInt8(c.redComponent * 255)); sig.append(UInt8(c.greenComponent * 255)); sig.append(UInt8(c.blueComponent * 255)) }
        }
    }
    return sig
}
func diff(_ a: [UInt8], _ b: [UInt8]) -> Double {
    guard a.count == b.count, !a.isEmpty else { return -1 }
    var d = 0; for i in 0..<a.count { d += abs(Int(a[i]) - Int(b[i])) }
    return Double(d) / Double(a.count)   // mean abs channel difference, 0-255
}
let next = NSAppleScript(source: "tell application \"Microsoft PowerPoint\" to go to next slide slideshow view of slide show window 1")!
let pos  = NSAppleScript(source: "tell application \"Microsoft PowerPoint\" to get current show position of slideshow view of slide show window 1")!
var err: NSDictionary?
next.compileAndReturnError(&err); pos.compileAndReturnError(&err)
func position() -> Int { Int(pos.executeAndReturnError(&err).int32Value) }

print("\n--- 1. no shield: show visible, position \(position()) ---")
let s1 = shot(progID, "1-no-shield"); shot(pvID, "1-no-shield")
settle(1)

print("--- 2. shield up, opaque black ---")
shield.alphaValue = 1; shield.orderFrontRegardless(); settle(1)
let s2 = shot(progID, "2-shield-up"); shot(pvID, "2-shield-up")
print("  program display under shield: mean level \(s2.reduce(0) { $0 + Int($1) } / max(1, s2.count)) (0 = black)")

print("--- 3. advance PowerPoint TWICE while fully covered ---")
let before = position()
next.executeAndReturnError(&err); settle(0.5); next.executeAndReturnError(&err); settle(2)
let after = position()
print("  position \(before) -> \(after)")
shot(pvID, "3-covered-after-advance")

print("--- 4. fade the shield out over 0.3 s, shoot at +0.05 s, +1 s, +3 s ---")
fade(to: 0, over: 0.3)
settle(0.05); let r0 = shot(progID, "4-revealed-immediately")
settle(0.95); let r1 = shot(progID, "4-revealed-1s")
settle(2.0);  let r3 = shot(progID, "4-revealed-3s"); shot(pvID, "4-revealed-3s")
print("  immediate vs +3s : \(String(format: "%.2f", diff(r0, r3)))  (0 = identical -> no stale frame)")
print("  +1s vs +3s       : \(String(format: "%.2f", diff(r1, r3)))")
print("  immediate vs pre-shield slide : \(String(format: "%.2f", diff(r0, s1)))  (large = the reveal shows a DIFFERENT slide than before, as it should)")

print("--- 5. shield back ---")
fade(to: 1, over: 0.3); settle(0.5); shot(progID, "5-shield-back")
shield.orderOut(nil)
print("\nscreenshots: \(shotDir)")

//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

// V4 bench helper: park a running app's show window fullscreen on the show
// display, via Accessibility — the same approach ARC Switcher uses, and the
// step V4 needs before the shield can mask a switch to that app.
//
// Usage:  swift park_window.swift "Microsoft PowerPoint" [window-name-substring]
//
// Prints what it found and what it did, so a failure says which part failed
// rather than just "didn't work". Exits 4 if the window did not end up exactly
// filling the show display.
//
// Order matters, MEASURED 2026-09-16 (5 fresh slideshow starts):
//   1. un-mirror. PowerPoint turns mirroring on when a show starts, and a window
//      sized while mirrored snaps back to the main display when mirroring ends.
//   2. AX position (accepted), AX size (REFUSED by a running slideshow).
//   3. PowerPoint only: AppleScript width/height/left position/top on the slide
//      show window. That IS honoured (4/4, in either order), and the slide
//      re-renders at the new size rather than scaling. `bounds` is silently
//      ignored, so set the four properties individually.

import AppKit
import ApplicationServices

let appName = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Microsoft PowerPoint"
let hint = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "Slide Show"

guard AXIsProcessTrusted() else {
    print("NOT TRUSTED for Accessibility. Grant the terminal running this in")
    print("System Settings > Privacy & Security > Accessibility, then re-run.")
    exit(3)
}
guard let running = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == appName }) else {
    print("\(appName) is not running"); exit(1)
}

// Step 1: un-mirror. While mirrored there is no second display to park on.
var onlineIDs = [CGDirectDisplayID](repeating: 0, count: 8), onlineCount: UInt32 = 0
CGGetOnlineDisplayList(8, &onlineIDs, &onlineCount)
let mirrored = onlineIDs.prefix(Int(onlineCount)).filter { CGDisplayMirrorsDisplay($0) != kCGNullDirectDisplay }
if !mirrored.isEmpty {
    var cfg: CGDisplayConfigRef?
    CGBeginDisplayConfiguration(&cfg)
    for d in mirrored { CGConfigureDisplayMirrorOfDisplay(cfg, d, kCGNullDirectDisplay) }
    let err = CGCompleteDisplayConfiguration(cfg, .forSession)
    print("un-mirrored \(mirrored.count) display(s), result \(err.rawValue)")
    RunLoop.current.run(until: Date().addingTimeInterval(3))   // let the window server settle
}

// CGDisplayBounds is already top-left global, the same space AX and PowerPoint use.
guard let targetID = onlineIDs.prefix(Int(onlineCount)).first(where: { CGDisplayIsMain($0) == 0 && CGDisplayIsActive($0) != 0 }) else {
    print("need a second display"); exit(2)
}
let f = CGDisplayBounds(targetID)
let axOrigin = f.origin
let axSize = f.size
print("show display: id \(targetID) -> AX origin (\(Int(axOrigin.x)),\(Int(axOrigin.y))) size \(Int(axSize.width))x\(Int(axSize.height))")

let axApp = AXUIElementCreateApplication(running.processIdentifier)
var windowsRef: CFTypeRef?
guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
      let windows = windowsRef as? [AXUIElement], !windows.isEmpty else {
    print("no AX windows for \(appName)"); exit(1)
}

func title(_ w: AXUIElement) -> String {
    var t: CFTypeRef?
    AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &t)
    return (t as? String) ?? ""
}

print("windows:")
for w in windows { print("   - \(title(w))") }

guard let show = windows.first(where: { title($0).contains(hint) }) ?? windows.first else {
    print("no window matching \(hint)"); exit(1)
}
print("parking: \(title(show))")

// Size before position, then position, then size again: some apps clamp a move
// to the display the window is currently on, so one pass is not enough.
var o = axOrigin, s = axSize
for pass in 1...2 {
    if let sv = AXValueCreate(.cgSize, &s) { AXUIElementSetAttributeValue(show, kAXSizeAttribute as CFString, sv) }
    if let ov = AXValueCreate(.cgPoint, &o) { AXUIElementSetAttributeValue(show, kAXPositionAttribute as CFString, ov) }
    var gotP: CFTypeRef?, gotS: CFTypeRef?
    AXUIElementCopyAttributeValue(show, kAXPositionAttribute as CFString, &gotP)
    AXUIElementCopyAttributeValue(show, kAXSizeAttribute as CFString, &gotS)
    var p = CGPoint.zero, z = CGSize.zero
    if let gotP { AXValueGetValue(gotP as! AXValue, .cgPoint, &p) }
    if let gotS { AXValueGetValue(gotS as! AXValue, .cgSize, &z) }
    print("  pass \(pass): now at (\(Int(p.x)),\(Int(p.y))) \(Int(z.width))x\(Int(z.height))")
    if abs(p.x - axOrigin.x) < 2, abs(p.y - axOrigin.y) < 2 { break }
    usleep(300_000)
}

func frameOf(_ w: AXUIElement) -> CGRect {
    var gotP: CFTypeRef?, gotS: CFTypeRef?
    AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &gotP)
    AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &gotS)
    var p = CGPoint.zero, z = CGSize.zero
    if let gotP { AXValueGetValue(gotP as! AXValue, .cgPoint, &p) }
    if let gotS { AXValueGetValue(gotS as! AXValue, .cgSize, &z) }
    return CGRect(origin: p, size: z)
}
func fits(_ r: CGRect) -> Bool {
    abs(r.minX - f.minX) < 2 && abs(r.minY - f.minY) < 2 && abs(r.width - f.width) < 2 && abs(r.height - f.height) < 2
}

// Step 3: a running PowerPoint slideshow refuses AX size; its own dictionary doesn't.
if !fits(frameOf(show)), appName == "Microsoft PowerPoint" {
    print("AX size refused; setting the slide show window through PowerPoint's AppleScript")
    let src = """
    tell application "Microsoft PowerPoint"
      set w to slide show window 1
      set width of w to \(Int(f.width))
      set height of w to \(Int(f.height))
      set left position of w to \(Int(f.minX))
      set top of w to \(Int(f.minY))
    end tell
    """
    var err: NSDictionary?
    NSAppleScript(source: src)?.executeAndReturnError(&err)
    if let err { print("  AppleScript error: \(err)") }
    RunLoop.current.run(until: Date().addingTimeInterval(2))
}

let final = frameOf(show)
print("final: (\(Int(final.minX)),\(Int(final.minY))) \(Int(final.width))x\(Int(final.height)) — \(fits(final) ? "FITS the show display" : "DOES NOT FIT")")
exit(fits(final) ? 0 : 4)

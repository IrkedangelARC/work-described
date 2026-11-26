//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

// V4 bench proof: can a shielding-level borderless window mask a switch to
// another app's fullscreen output, with no compositor and no OBS?
//
// This deliberately does NOT touch ARC Presenter. It stands up the same kind of
// window Presenter's DisplayManager already makes — .borderless, sized to a
// screen, at CGShieldingWindowLevel(), [.stationary, .canJoinAllSpaces,
// .ignoresCycle] — and answers three questions that decide the whole approach:
//
//   Q1 does the shield actually cover another app's show window on that display?
//   Q2 does that app keep drawing while fully covered, or present a stale frame
//      on reveal? (ARC Capture measured PowerPoint going stale when covered,
//      2026-09-11, which is why it parks show windows on a second display)
//   Q3 is the reveal clean when the shield fades out?
//
// Usage:  swift shield_bench.swift [seconds-per-phase]
// It prints the CGWindowList ordering at each phase and screenshots the target
// display, so the answers are measured rather than eyeballed.

import AppKit

let phase = CommandLine.arguments.count > 1 ? (Double(CommandLine.arguments[1]) ?? 3.0) : 3.0
let shotDir = NSString(string: "/Volumes/DRIVE/ARC Test Media/ARC Capture Suite/v4-bench").expandingTildeInPath
try? FileManager.default.createDirectory(atPath: shotDir, withIntermediateDirectories: true)

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// The show display: anything that is not the menu-bar screen.
guard let main = NSScreen.screens.first,
      let target = NSScreen.screens.first(where: { $0 != main }) else {
    print("need a second display"); exit(2)
}
let targetID = (target.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber).uint32Value
print("shield display: \(target.localizedName) \(Int(target.frame.width))x\(Int(target.frame.height)) id=\(targetID)")

// Exactly how Presenter builds its program output window.
let shield = NSWindow(contentRect: target.frame, styleMask: [.borderless],
                      backing: .buffered, defer: false, screen: target)
shield.level = NSWindow.Level(Int(CGShieldingWindowLevel()))
shield.collectionBehavior = [.stationary, .canJoinAllSpaces, .ignoresCycle]
shield.backgroundColor = .black
shield.isOpaque = true
shield.hasShadow = false
shield.ignoresMouseEvents = true
shield.setFrame(target.frame, display: true)

/// Everything on the target display, front to back, as the window server sees it.
func windowsOnTarget(_ tag: String) {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return }
    let tf = target.frame
    // CGWindowList is in flipped global coords; compare against the target's slab.
    let globalTop = (main.frame.height - tf.maxY)
    var rows: [String] = []
    for w in list {
        guard let b = w[kCGWindowBounds as String] as? [String: CGFloat],
              let owner = w[kCGWindowOwnerName as String] as? String,
              let layer = w[kCGWindowLayer as String] as? Int else { continue }
        let x = b["X"] ?? 0, y = b["Y"] ?? 0, wd = b["Width"] ?? 0, ht = b["Height"] ?? 0
        guard wd > 200, ht > 200 else { continue }                       // ignore chrome
        guard x >= tf.minX - 1, y >= globalTop - 1 else { continue }     // on the show display
        let name = (w[kCGWindowName as String] as? String) ?? ""
        let alpha = (w[kCGWindowAlpha as String] as? Double) ?? 1
        rows.append("      layer \(String(format: "%5d", layer))  a=\(String(format: "%.2f", alpha))  \(Int(wd))x\(Int(ht))  \(owner)\(name.isEmpty ? "" : " — \(name)")")
    }
    print("  [\(tag)] front-to-back on the show display:")
    rows.prefix(6).forEach { print($0) }
    if rows.isEmpty { print("      (nothing)") }
}

func shot(_ tag: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    p.arguments = ["-x", "-D", "2", "\(shotDir)/\(tag).png"]
    try? p.run(); p.waitUntilExit()
}

func settle(_ s: Double) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }

func fade(to a: CGFloat, over seconds: Double) {
    let steps = max(1, Int(seconds * 60)), from = shield.alphaValue
    for i in 1...steps {
        shield.alphaValue = from + (a - from) * CGFloat(i) / CGFloat(steps)
        RunLoop.current.run(until: Date().addingTimeInterval(1.0 / 60.0))
    }
    shield.alphaValue = a
}

print("\n--- phase 1: before the shield exists (whatever you parked there is visible) ---")
windowsOnTarget("no shield"); shot("1-no-shield")
settle(phase)

print("\n--- phase 2: shield up, opaque black (Q1: does it cover the app?) ---")
shield.alphaValue = 1
shield.orderFrontRegardless()
settle(1.0)
windowsOnTarget("shield up"); shot("2-shield-up")
settle(phase)

print("\n--- phase 3: fade the shield out over 0.3 s (Q3: is the reveal clean?) ---")
fade(to: 0, over: 0.3)
settle(0.35)
windowsOnTarget("revealed"); shot("3-revealed-immediately")
settle(phase)
shot("4-revealed-after-\(Int(phase))s")     // Q2: did it redraw, or is it stale?

print("\n--- phase 4: fade the shield back in (return to Presenter) ---")
fade(to: 1, over: 0.3)
settle(0.35)
windowsOnTarget("shield back"); shot("5-shield-back")
settle(phase)

shield.orderOut(nil)
print("\nscreenshots: \(shotDir)")

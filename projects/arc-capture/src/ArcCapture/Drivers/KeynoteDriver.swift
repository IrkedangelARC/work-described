//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import AppKit
import ApplicationServices

/// Keynote (the current app, bundle com.apple.Keynote, "Keynote Creator
/// Studio" 15.x; the old com.apple.iWork.Keynote 14.5 is retired). The show
/// plays IN A WINDOW (Play menu, "In Window"): the document window becomes
/// the slide, sized 1920x1080 under its title bar and parked on the second
/// display like PowerPoint's. Deck facts come from Keynote's own scripting
/// (skipped slides, movies and audio per slide, transition effect and
/// duration, movie repetition), not from the file.
final class KeynoteDriver: PresentationDriver {
    let bundleIdentifier = "com.apple.Keynote"
    let displayName = "Keynote"
    private(set) var windowTitleHint = ".key"
    /// In-window play: the whole window is the slide, no title bar (measured 2026-09-12).
    var windowTitleBarHeight: CGFloat { 0 }
    private var openedURL: URL?

    private var app: String { "application id \"\(bundleIdentifier)\"" }

    func analyze(_ url: URL) -> PPTXAnalysis? {
        guard url.pathExtension.lowercased() == "key" else { return nil }
        // Open (idempotent) and read per-slide facts in one script.
        let script = """
        tell \(app)
            set d to open POSIX file "\(url.path)"
            delay 2
            set out to ""
            repeat with i from 1 to count of slides of d
                set s to slide i of d
                set tp to transition properties of s
                set rep to "none"
                if (count of movies of s) > 0 then set rep to (repetition method of movie 1 of s) as string
                set out to out & i & "|" & (skipped of s) & "|" & (count of movies of s) & "|" & (count of audio clips of s) & "|" & (transition effect of tp as string) & "|" & (transition duration of tp) & "|" & rep & linefeed
            end repeat
            return out
        end tell
        """
        guard let text = try? AppleScriptRunner.run(script) else { return nil }
        var a = PPTXAnalysis.empty
        var count = 0
        for line in text.split(separator: "\n") {
            let f = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 7, let n = Int(f[0]) else { continue }
            count = max(count, n)
            if f[1] == "true" { a.hiddenSlides.insert(n) }
            let movies = Int(f[2]) ?? 0, audio = Int(f[3]) ?? 0
            if movies > 0 || audio > 0 {
                a.videoSlides.insert(n)
                a.mediaStartUnknown.insert(n)       // start mode is not scriptable: measured at capture time
                if f[6].contains("loop") { a.loopingSlides.insert(n) }
            }
            let effect = f[4]
            if !effect.isEmpty && effect != "no transition effect" && effect != "none" {
                a.transitionSlides.insert(n)
                a.transitionDurations[n] = Double(f[5]) ?? 1.0
            }
            a.clickCounts[n] = -1                   // builds unknown: every click gets the transition wait
        }
        a.slideCount = count
        // Movie lengths: the package's media files, longest one per movie slide (upper bound).
        var longest: TimeInterval = 0
        if let ffprobe = PPTXAnalyzer.ffprobeURL {
            var dataDir = url.appendingPathComponent("Data")
            var isDir: ObjCBool = false
            if !(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue) {
                // Single-file .key is a zip: pull Data/ out to a temp dir.
                let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("keynote-\(UUID().uuidString)")
                try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
                let z = Process(); z.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
                z.arguments = ["-q", "-o", url.path, "Data/*", "-d", tmp.path]; z.standardOutput = FileHandle.nullDevice; z.standardError = FileHandle.nullDevice
                if (try? z.run()) != nil { z.waitUntilExit() }
                dataDir = tmp.appendingPathComponent("Data")
            }
            for f in (try? FileManager.default.contentsOfDirectory(atPath: dataDir.path)) ?? [] where PPTXAnalyzer.videoExtensions.contains((f as NSString).pathExtension.lowercased()) || PPTXAnalyzer.audioExtensions.contains((f as NSString).pathExtension.lowercased()) {
                let p = Process(); p.executableURL = ffprobe
                p.arguments = ["-v", "quiet", "-show_entries", "format=duration", "-of", "csv=p=0", dataDir.appendingPathComponent(f).path]
                let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
                if (try? p.run()) != nil { p.waitUntilExit(); if let d = TimeInterval(String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") { longest = max(longest, d) } }
            }
        }
        for n in a.videoSlides { a.slideDurations[n] = longest > 0 ? longest : 30 }
        if longest == 0 && !a.videoSlides.isEmpty { a.warnings.append("Keynote: movie lengths unknown (no media files found in the package); 30 s cap") }
        a.warnings.append("Keynote: builds per slide unknown, clicked until the slide moves; media start measured on entry")
        return a
    }

    func openFile(_ url: URL) async throws {
        openedURL = url
        windowTitleHint = url.lastPathComponent
        try AppleScriptRunner.run("tell \(app)\n activate\n open POSIX file \"\(url.path)\"\nend tell")
        try? await Task.sleep(for: .seconds(2))
        // Play → In Window, through the app's menu (in-process Accessibility).
        _ = AXMenus.press(bundleIdentifier: bundleIdentifier, menu: "Play", item: "In Window")
        DebugLog.log("Driver", "Keynote: Play set to In Window")
    }

    /// Keynote plays from the document's current slide, so a range starts where it is asked to (the
    /// session ends the run on its own count, as it does for PowerPoint). Phase 3 of the review queue.
    var supportsRange: Bool { true }

    func startSlideshow(from: Int, to: Int) async throws {
        try AppleScriptRunner.run("tell \(app)\n set current slide of document 1 to slide \(max(1, from)) of document 1\n start slideshow of document 1\nend tell")
        for _ in 0..<40 {
            if ((try? AppleScriptRunner.run("tell \(app) to playing of document 1")) ?? "false") == "true" { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        await moveShowWindowToSecondDisplay()
    }

    func startSlideshow() async throws {
        // Keynote starts from the document's current slide (key1 began on
        // slide 16, the last one selected in the editor, and the capture
        // ended at once). Start from slide 1 explicitly.
        try AppleScriptRunner.run("tell \(app)\n set current slide of document 1 to slide 1 of document 1\n start slideshow of document 1\nend tell")
        for _ in 0..<40 {
            if ((try? AppleScriptRunner.run("tell \(app) to playing of document 1")) ?? "false") == "true" { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        await moveShowWindowToSecondDisplay()
    }

    /// Same geometry as PowerPoint's show window: 1920 x (1080 + title bar)
    /// on a display other than the menu-bar one.
    func moveShowWindowToSecondDisplay() async {
        let screens = NSScreen.screens
        guard let main = screens.first else { return }
        let placed = ShowWindowPlacement.targetScreen()
        DebugLog.log("Driver", "Keynote: \(placed.note)")
        guard let target = placed.screen else { return }
        let f = target.frame
        let topLeftY = main.frame.height - f.maxY
        // Keynote sizes the whole window to the slide; ask for the slide size itself.
        let targetW = min(1920.0, f.width), targetH = (targetW * 9 / 16).rounded()
        let x = Int(f.minX + max(0, (f.width - targetW) / 2)), y = Int(topLeftY + max(0, (f.height - targetH) / 2))
        guard let win = AXWindows.windows(of: bundleIdentifier, titlePrefix: windowTitleHint).first else {
            DebugLog.log("Driver", "Keynote: no window titled \(windowTitleHint) to move"); return
        }
        let ok = AXWindows.set(win, position: CGPoint(x: x, y: y), size: CGSize(width: targetW, height: targetH))
        let now = AXWindows.frame(of: win).map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? "?"
        DebugLog.log("Driver", "Keynote show window moved by AX to \"\(target.localizedName)\": \(ok ? "ok" : "refused"), now \(now)")
        try? await Task.sleep(for: .milliseconds(400))
    }

    func advanceSlide() async throws { try AppleScriptRunner.run("tell \(app) to show next") }

    func sendNextClick() async throws {
        if let win = AXWindows.windows(of: bundleIdentifier, titlePrefix: windowTitleHint).first, let f = AXWindows.frame(of: win) {
            AXWindows.raise(win)
            try? await Task.sleep(for: .milliseconds(300))
            AXWindows.click(at: CGPoint(x: f.midX, y: f.minY + f.height * 0.85))
        } else {
            try await advanceSlide()
        }
    }

    func playCurrentSlideMedia() async throws -> Int { 0 }

    func stopSlideshow() async throws {
        try? AppleScriptRunner.run("tell \(app) to stop slideshow of document 1")
    }

    func closeFile(_ url: URL) async throws {
        try? AppleScriptRunner.run("tell \(app) to close document 1 saving no")
    }

    func slideCount() async throws -> Int {
        Int(try AppleScriptRunner.run("tell \(app) to count of slides of document 1")) ?? 0
    }

    func currentSlideNumber() async throws -> Int {
        Int(try AppleScriptRunner.run("tell \(app) to slide number of current slide of document 1")) ?? 0
    }
}

/// Press a menu item of another app's menu bar through Accessibility.
enum AXMenus {
    static func press(bundleIdentifier: String, menu: String, item: String) -> Bool {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first else { return false }
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        var bar: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, kAXMenuBarAttribute as CFString, &bar) == .success, let barEl = bar else { return false }
        guard let menuItem = children(of: barEl as! AXUIElement).first(where: { title(of: $0) == menu }),
              let menuEl = children(of: menuItem).first,
              let target = children(of: menuEl).first(where: { title(of: $0) == item }) else { return false }
        return AXUIElementPerformAction(target, kAXPressAction as CFString) == .success
    }
    private static func children(of el: AXUIElement) -> [AXUIElement] {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &v) == .success else { return [] }
        return v as? [AXUIElement] ?? []
    }
    private static func title(of el: AXUIElement) -> String {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXTitleAttribute as CFString, &v) == .success else { return "" }
        return v as? String ?? ""
    }
}

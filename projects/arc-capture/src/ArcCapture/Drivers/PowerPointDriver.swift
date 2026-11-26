//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import AppKit

struct PowerPointDriver: PresentationDriver {
    let bundleIdentifier = "com.microsoft.Powerpoint"
    let displayName = "PowerPoint"
    let windowTitleHint = "PowerPoint Slide Show"

    func openFile(_ url: URL) async throws {
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil else {
            throw DriverError.applicationNotFound(displayName)
        }
        let path = url.path(percentEncoded: false)
        let fileName = url.lastPathComponent

        // Close the file if already open, so it starts fresh on slide 1.
        try? AppleScriptRunner.run("""
            tell application "Microsoft PowerPoint"
                repeat with d in (every document)
                    if name of d is "\(fileName)" then
                        close d saving no
                    end if
                end repeat
            end tell
            """)
        try await Task.sleep(for: .milliseconds(500))

        // PowerPoint keeps releasing a closed deck's media for a while and
        // answers a fresh open with a modal "This file is still closing"
        // dialog (measured 2026-09-11, 195 MB video deck). Dismiss it and
        // retry for up to ~30 s.
        var attempt = 0
        var relaunched = false
        while true {
            attempt += 1
            do {
                try AppleScriptRunner.run("""
                    tell application "Microsoft PowerPoint"
                        activate
                        open POSIX file "\(path)"
                    end tell
                    """)
                break
            } catch {
                let dismissed = (try? AppleScriptRunner.run("""
                    tell application "System Events" to tell process "Microsoft PowerPoint"
                        set n to 0
                        repeat with w in (every window whose subrole is "AXDialog")
                            try
                                click button "OK" of w
                                set n to n + 1
                            end try
                        end repeat
                        return n
                    end tell
                    """)) ?? "0"
                DebugLog.log("Driver", "open attempt \(attempt) failed (\(error.localizedDescription)); dismissed \(dismissed) dialog(s)")
                if attempt >= 6 { throw error }
                // PowerPoint wedged: once it answers -9074 ("an error of type -9074"), EVERY later open fails
                // the same way until it is quit gracefully and relaunched, so one bad deck costs the whole run
                // (ARC Test Show 02 fleet run, 2026-09-20: items 3.08 to 3.11 on one laptop, 16 items on the workstation
                // and the mini). A kill does not cure it; `quit saving no` does. Tried ONCE per open.
                if !relaunched, error.localizedDescription.contains("-9074") || error.localizedDescription.contains("16389") {
                    relaunched = true
                    DebugLog.log("Driver", "PowerPoint is wedged; quitting it and starting again")
                    try? AppleScriptRunner.run("tell application \"Microsoft PowerPoint\" to quit saving no")
                    try await Task.sleep(for: .seconds(4))
                    NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier).map { url in
                        let c = NSWorkspace.OpenConfiguration(); c.activates = true
                        NSWorkspace.shared.openApplication(at: url, configuration: c)
                    }
                    try await Task.sleep(for: .seconds(10))
                    continue
                }
                try await Task.sleep(for: .seconds(5))
            }
        }
        // Allow PowerPoint time to fully load the file.
        try await Task.sleep(for: .seconds(2))
    }

    var supportsRange: Bool { true }

    func startSlideshow() async throws {
        try await startSlideshow(from: 1, to: 0)
    }

    /// `to` 0 = the last slide. The show always OPENS on slide 1 and is then
    /// wound forward to `from`.
    ///
    /// PowerPoint 16.113 accepts `starting slide`, reads it back, and opens on
    /// slide 1 regardless (measured on the mini, 2026-09-18; `range type`,
    /// selecting the slide first, `go to slide`, setting the show position and
    /// typing the number in the show were all tried and all refused). What does
    /// work is `go to next slide`, which steps slide to slide without walking
    /// builds: slide 1 to 12 of a 53-slide deck in 2.86 s. The wind-forward
    /// happens before the frame capture starts, so none of it is recorded.
    func startSlideshow(from: Int, to: Int) async throws {
        // Windowed mode: a clean slide in a standalone window, any monitor
        // count, no presenter view, no toolbar. ScreenCaptureKit grabs it.
        // `ending slide` is set for the app's benefit only; the session ends
        // the run on its own count, because this build ignores that too.
        try AppleScriptRunner.run("""
            tell application "Microsoft PowerPoint"
                set theSettings to slide show settings of active presentation
                set show type of theSettings to slide show type window
                set starting slide of theSettings to 1
                set ending slide of theSettings to \(to > 0 ? "\(to)" : "(count slides of active presentation)")
                run slide show theSettings
            end tell
            """)
        // Poll for the show window instead of sleeping 2 s: a movie set to
        // play on entry of slide 1 starts the moment the show does, and
        // every 100 ms here is footage missed (2026-09-11).
        for _ in 0..<40 {
            let n = (try? AppleScriptRunner.run("""
                tell application "System Events" to tell process "Microsoft PowerPoint" to count (every window whose name begins with "PowerPoint Slide Show")
                """)) ?? "0"
            if n != "0" { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        // The window exists before the show reports a position; a settle
        // taken then is a blank frame labelled slide 0 (1.16, 13:45).
        for _ in 0..<30 {
            if ((try? await currentSlideNumber()) ?? 0) > 0 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        if from > 1 { try await windForward(to: from) }
        await moveShowWindowToSecondDisplay()
    }

    /// Step the running show to `slide` without walking its builds, and
    /// without recording anything: `go to next slide` moves slide to slide.
    ///
    /// The stepping happens INSIDE one AppleScript, in chunks. A process per
    /// step (osascript to advance, osascript to read the position) is both
    /// slow and wrong: PowerPoint does not report the new position until the
    /// slide's transition has played, so a poll straight after the step reads
    /// the old number and the wind looks stalled after two slides. In one
    /// script with a short delay it is 11 slides in 2.86 s (measured on the
    /// mini, 2026-09-18). Chunked so no single call nears osascript's timeout.
    func windForward(to slide: Int) async throws {
        let started = Date()
        var last = (try? await currentSlideNumber()) ?? 0
        while last < slide, Date().timeIntervalSince(started) < 90 {
            let chunk = min(12, slide - last)
            let reached = try AppleScriptRunner.run("""
                tell application "Microsoft PowerPoint"
                    set v to slide show view of slide show window 1
                    set steps to 0
                    repeat until (current show position of v) is greater than or equal to \(slide)
                        go to next slide v
                        delay 0.12
                        set steps to steps + 1
                        if steps is greater than or equal to \(chunk) then exit repeat
                    end repeat
                    return (current show position of v) as text
                end tell
                """)
            let now = Int(reached) ?? 0
            if now <= last {
                DebugLog.log("Driver", "the show stopped moving at slide \(last) while winding forward")
                break
            }
            last = now
        }
        DebugLog.log("Driver", "wound the show forward to slide \(last) (wanted \(slide)) in \(String(format: "%.2f", Date().timeIntervalSince(started))) s")
        if last != slide {
            throw DriverError.appleScriptFailed("the show stopped at slide \(last) while winding forward to \(slide)")
        }
    }

    /// With more than one display, park the show window on a display other
    /// than the menu-bar one so the operator's windows on the main display
    /// never cover it: PowerPoint stops drawing a fully covered window and
    /// the capture repeats its last frame (2026-09-11 14:05). System
    /// Events positions are top-left based with the menu-bar display's top
    /// at y = 0; NSScreen frames are bottom-left based.
    func moveShowWindowToSecondDisplay() async {
        let screens = NSScreen.screens
        guard let main = screens.first else { return }
        let placed = ShowWindowPlacement.targetScreen()
        DebugLog.log("Driver", "PowerPoint: \(placed.note)")
        guard let target = placed.screen else { return }
        let f = target.frame
        let topLeftY = main.frame.height - f.maxY
        let sizeText = (try? AppleScriptRunner.run("""
            tell application "System Events" to tell process "Microsoft PowerPoint" to get size of (first window whose name begins with "PowerPoint Slide Show")
            """)) ?? "1600, 900"
        let parts = sizeText.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        let w = parts.count == 2 ? parts[0] : 1600, h = parts.count == 2 ? parts[1] : 900
        // Content exactly 16:9 (1920x1080 under a 28 pt title bar): the
        // default 1920x1122 window letterboxes the slide with 7 px bars and
        // the clips came out 1920x1094, which Presenter's player layer then
        // rescales at the swap (2026-09-12).
        let targetW = min(1920.0, f.width), targetH = (targetW * 9 / 16).rounded() + 28
        let x = Int(f.minX + max(0, (f.width - targetW) / 2))
        let y = Int(topLeftY + max(0, (f.height - targetH) / 2))
        _ = (w, h)
        // In-process first (the app's own Accessibility grant), script second.
        if let win = AXWindows.windows(of: bundleIdentifier, titlePrefix: "PowerPoint Slide Show").first {
            let ok = AXWindows.set(win, position: CGPoint(x: x, y: y), size: CGSize(width: targetW, height: targetH))
            let now = AXWindows.frame(of: win).map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? "?"
            DebugLog.log("Driver", "show window moved by AX to display \"\(target.localizedName)\": \(ok ? "ok" : "refused"), now \(now)")
            if ok { try? await Task.sleep(for: .milliseconds(400)); return }
        } else {
            DebugLog.log("Driver", "AX found no show window (Accessibility trusted: \(AXIsProcessTrusted()))")
        }
        do {
            let placed = try AppleScriptRunner.run("""
                tell application "System Events" to tell process "Microsoft PowerPoint"
                    set w to (first window whose name begins with "PowerPoint Slide Show")
                    set size of w to {\(Int(targetW)), \(Int(targetH))}
                    set position of w to {\(x), \(y)}
                    return (position of w) & (size of w)
                end tell
                """)
            DebugLog.log("Driver", "show window moved to display \"\(target.localizedName)\" at \(placed)")
        } catch {
            DebugLog.log("Driver", "could not move the show window: \(error.localizedDescription)")
        }
        try? await Task.sleep(for: .milliseconds(400))
    }

    func advanceSlide() async throws {
        try AppleScriptRunner.run("""
            tell application "Microsoft PowerPoint"
                go to next slide of slide show view of slide show window 1
            end tell
            """)
    }

    /// Right-arrow via System Events. In slideshow mode this fires the next
    /// click/animation event (a click-to-play video) WITHOUT a slide-level
    /// advance. NOTE: no `activate`; PowerPoint must already be frontmost.
    /// Calling `activate` during a slideshow causes a focus event PowerPoint
    /// counts as an extra advance.
    func sendNextClick() async throws {
        // A key event only lands when PowerPoint is frontmost, and an
        // NSRunningApplication.activate() from a background accessory app is
        // refused (measured 2026-09-11). Raise PowerPoint with an Apple event,
        // send the key, hand focus straight back to the operator's app. The
        // show position is read before and after so a phantom advance from
        // the focus change would be visible in the log.
        let previous = NSWorkspace.shared.frontmostApplication
        let wasFront = previous?.bundleIdentifier == bundleIdentifier
        let before = (try? await currentSlideNumber()) ?? 0
        // In-process path: raise the show window and click inside it with
        // the app's own Accessibility grant; the script path stays as backup.
        if let win = AXWindows.windows(of: bundleIdentifier, titlePrefix: "PowerPoint Slide Show").first,
           let f = AXWindows.frame(of: win) {
            _ = try? AppleScriptRunner.run("tell application \"Microsoft PowerPoint\" to activate")
            AXWindows.raise(win)
            try? await Task.sleep(for: .milliseconds(500))
            let p = CGPoint(x: f.midX, y: f.minY + f.height * 0.85)
            AXWindows.click(at: p)
            try? await Task.sleep(for: .milliseconds(300))
            let after = (try? await currentSlideNumber()) ?? 0
            DebugLog.log("Driver", "AX click at \(Int(p.x)),\(Int(p.y)) position \(before) -> \(after)")
            if !wasFront, let previous { previous.activate() }
            return
        }
        if !wasFront {
            // Activating the app alone left the DOCUMENT window key and the
            // key went nowhere (slide 20 of 1.08, 2026-09-11); raise the show
            // window itself.
            try AppleScriptRunner.run("""
                tell application "Microsoft PowerPoint" to activate
                tell application "System Events" to tell process "Microsoft PowerPoint"
                    set frontmost to true
                    repeat with w in (every window whose name begins with "PowerPoint Slide Show")
                        perform action "AXRaise" of w
                    end repeat
                end tell
                """)
            try? await Task.sleep(for: .milliseconds(700))
        }
        // With the show window raised, a mouse click inside it is the next
        // click event AND makes it key; a key code after a focus change went
        // to a window PowerPoint calls "Window" and did nothing (10:50 run).
        let clicked = try AppleScriptRunner.run("""
            tell application "System Events" to tell process "Microsoft PowerPoint"
                set ws to (every window whose name begins with "PowerPoint Slide Show")
                if (count ws) is 0 then return "no show window"
                set w to item 1 of ws
                set {x, y} to position of w
                set {wd, ht} to size of w
                set px to x + (wd div 2)
                set py to y + (ht * 0.85) as integer
                click at {px, py}
                return "clicked at " & px & "," & py & " front=" & (frontmost as string)
            end tell
            """)
        DebugLog.log("Driver", "click: \(clicked)")
        try? await Task.sleep(for: .milliseconds(300))
        let after = (try? await currentSlideNumber()) ?? 0
        if !wasFront, let name = previous?.localizedName, previous?.bundleIdentifier != bundleIdentifier {
            try? AppleScriptRunner.run("""
                tell application "System Events" to set frontmost of process "\(name)" to true
                """)
            DebugLog.log("Driver", "click sent with PowerPoint raised; focus returned to \(name); position \(before) -> \(after)")
        } else {
            DebugLog.log("Driver", "click sent, PowerPoint was frontmost; position \(before) -> \(after)")
        }
    }

    /// PowerPoint's dictionary offers `get player from ... for <shape>` +
    /// `play player`, but on 16.112 every form of `get player from` returns
    /// nothing ("No result was returned", measured 2026-09-11 on a slide
    /// whose shape IS `media type movie`). Kept as the first attempt in case
    /// a later build honours it; `sendNextClick` (posted to the pid) is what
    /// actually starts the movie without a focus change.
    func playCurrentSlideMedia() async throws -> Int {
        Int(try AppleScriptRunner.run("""
            tell application "Microsoft PowerPoint"
                set ssv to slide show view of slide show window 1
                set n to current show position of ssv
                set played to 0
                repeat with sh in (every shape of slide n of active presentation)
                    if media type of sh is media type movie then
                        set p to get player from ssv for sh
                        play player p
                        set played to played + 1
                    end if
                end repeat
                return played
            end tell
            """)) ?? 0
    }

    func stopSlideshow() async throws {
        try AppleScriptRunner.run("""
            tell application "Microsoft PowerPoint"
                exit slide show slide show view of slide show window 1
            end tell
            """)
    }

    /// Close the document (and its window) by name, never saving. Harmless
    /// if it is already gone.
    /// PowerPoint reports document names WITHOUT the extension (System
    /// Events listed "1.16 Sample Deck - Title Slides" for the
    /// .pptx), so the old name test never matched and windows piled up.
    /// Changing the slide show settings dirties the document, so a plain
    /// close raises a Save sheet and the window never goes away (that is what
    /// left eight windows open and hung `quit` on 2026-09-11). `close active
    /// presentation saving no` is the form PowerPoint honours; the document
    /// collection itself errors with -1728 on 16.112.
    func closeFile(_ url: URL) async throws {
        let stem = url.deletingPathExtension().lastPathComponent
        do {
            try AppleScriptRunner.run("""
                tell application "Microsoft PowerPoint"
                    if name of active presentation is "\(stem)" or name of active presentation is "\(url.lastPathComponent)" then
                        close active presentation saving no
                    end if
                end tell
                """)
        } catch {
            DebugLog.log("Driver", "close active presentation: \(error.localizedDescription); pressing the window's close button")
            try? AppleScriptRunner.run("""
                tell application "System Events"
                    tell process "Microsoft PowerPoint"
                        repeat with w in (every window whose name is "\(stem)")
                            try
                                click (first button of w whose subrole is "AXCloseButton")
                                delay 0.5
                                click button "Don't Save" of sheet 1 of w
                            end try
                        end repeat
                    end tell
                end tell
                """)
        }
        // Wait for the window to go so the next open does not collide with
        // the close still in progress.
        var left = "?"
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(500))
            left = (try? AppleScriptRunner.run("""
                tell application "System Events" to tell process "Microsoft PowerPoint" to count (every window whose name is "\(stem)")
                """)) ?? "?"
            if left == "0" { break }
        }
        DebugLog.log("Driver", "closed \(stem); windows left with that name: \(left)")
    }


    func slideCount() async throws -> Int {
        Int(try AppleScriptRunner.run("""
            tell application "Microsoft PowerPoint"
                count slides of active presentation
            end tell
            """)) ?? 0
    }

    /// `current show position` is the property that answers during a slideshow
    /// (measured 2026-09-11 on PowerPoint 16.112: `slide number of slide show
    /// view` is "missing value", which is why the build walk never saw the
    /// slide move).
    func currentSlideNumber() async throws -> Int {
        Int(try AppleScriptRunner.run("""
            tell application "Microsoft PowerPoint"
                current show position of slide show view of slide show window 1
            end tell
            """)) ?? 0
    }
}

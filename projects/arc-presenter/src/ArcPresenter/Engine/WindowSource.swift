//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//


import AppKit
import ApplicationServices
import ScreenCaptureKit

/// Any on-screen window of any app as a live source under the program shield
/// (2026-09-18: "app agnostic source opening beneath the presenter").
/// Keynote played In Window, a browser, a PDF viewer, a video player: Presenter
/// parks the window on the program display behind its shield, captures it the
/// way it captures PowerPoint's show window, and forwards the clicker as key
/// presses posted straight to the owning process (no focus change, Presenter
/// keeps the keys). Nothing is opened for the operator: the app is already
/// running and showing the window; this only borrows it.
@MainActor
@Observable
final class WindowSource: LiveNavigable {
    enum Phase: String {
        case idle       // nothing attached
        case attached   // parked and capturable
        case lost       // the app quit or the window went away
    }

    /// One shareable window, as listed for the picker and the API.
    struct Pick: Identifiable, Equatable, Sendable {
        let windowID: CGWindowID
        let ownerPID: pid_t
        let bundleID: String
        let appName: String
        let title: String
        let frame: CGRect
        var id: CGWindowID { windowID }
        var label: String { title.isEmpty ? appName : "\(appName): \(title)" }
        /// On the current Space right now; false = another Space or full screen (the capture still works).
        var isOnScreen: Bool = true
    }

    private(set) var phase: Phase = .idle
    private(set) var pick: Pick?
    private(set) var error: String?
    private(set) var parkedFrame: CGRect?
    private(set) var isBusy = false
    /// The app quit or the window closed while attached (audit R4: a lost live
    /// source returns the program to the deck).
    var onLost: ((String) -> Void)?

    var isReady: Bool { phase == .attached }
    /// Attached, and to this window (the frozen rule in ZoomSource reads one line).
    func isAttached(to windowID: CGWindowID) -> Bool { phase == .attached && pick?.windowID == windowID }
    var bundleID: String? { pick?.bundleID }

    // MARK: - Per-source behaviour (PLAN_zoom_source step 2, drill 2026-09-20 findings 3, 12, 17, 23)

    /// Everything that differs per source app, as ONE value on the pick (assessment 2026-09-20: two rules
    /// and two overrides were becoming five knobs). Resolved from the bundle id, then the operator's
    /// overrides on top (`POST /source/window?clicker=0|1&mute=0|1&crop=<pt>`).
    struct SourceProfile: Equatable, Sendable {
        /// True: next/prev go to this window's app. False: they drive the deck while the window is live.
        var clickerDrivesWindow = true
        /// True: RETURN engages the process tap mute on the app (PowerPoint's rule). False: never.
        var mutesOnReturn = true
        /// Points cut off the TOP of the captured picture (an app's own title strip); 0 = none.
        var cropTop: CGFloat = 0

        /// A slideshow-shaped app: Keynote, a browser, a player. Keys to it, mute on RETURN, no crop.
        static let slideshow = SourceProfile()
        /// Zoom: the clicker drives the DECK (the remote watches the share of it), RETURN never mutes (a
        /// panelist keeps talking under the slides; the tap silenced the iPad for 10 s), and the strip
        /// with the traffic lights comes off: Zoom draws them with their centre 29 pt down, so 44 pt
        /// clears them and stays above the thumbnail row at 64 pt (measured on the second window, 720 pt
        /// tall; 28 pt left the lights at the cut edge, 2026-09-20 09:14).
        static let zoom = SourceProfile(clickerDrivesWindow: false, mutesOnReturn: false, cropTop: 44)

        /// ARC Zoom, the sidecar (`~/projects/arc-zoom`): its output windows are OUR pictures, drawn
        /// borderless at the size we asked for, so there is no chrome to crop. It is a Zoom source in
        /// every other way: the remote is watching the share of the DECK, so the clicker drives the
        /// deck, and a panelist on program keeps talking when the operator returns to the slides.
        static let arcZoom = SourceProfile(clickerDrivesWindow: false, mutesOnReturn: false, cropTop: 0)

        nonisolated static func rule(for bundleID: String?) -> SourceProfile {
            switch bundleID {
            case "us.zoom.xos": return .zoom
            case "com.example.arc.ArcZoom": return .arcZoom
            default: return .slideshow
            }
        }
        func overriding(clicker: Bool?, mute: Bool?, cropTop: CGFloat?) -> SourceProfile {
            var p = self
            if let clicker { p.clickerDrivesWindow = clicker }
            if let mute { p.mutesOnReturn = mute }
            if let cropTop { p.cropTop = max(0, cropTop) }
            return p
        }
    }

    /// The attached window's profile: the rule for its app plus the overrides given at attach.
    private(set) var profile = SourceProfile.slideshow
    var clickerDrivesWindow: Bool { profile.clickerDrivesWindow }
    var mutesOnReturn: Bool { profile.mutesOnReturn }

    /// Kept for the tests and callers that ask by bundle id alone.
    nonisolated static func clickerDrivesWindow(bundleID: String?, override: Bool?) -> Bool {
        SourceProfile.rule(for: bundleID).overriding(clicker: override, mute: nil, cropTop: nil).clickerDrivesWindow
    }
    nonisolated static func mutesOnReturn(bundleID: String?, override: Bool?) -> Bool {
        SourceProfile.rule(for: bundleID).overriding(clicker: nil, mute: override, cropTop: nil).mutesOnReturn
    }

    /// Keys the source posts carry this tag so Presenter's own clicker tap
    /// ignores them: a forwarded click must never be forwarded twice.
    nonisolated static let eventTag: Int64 = 0x41524350   // "ARCP"

    private let displays: DisplayManager
    private var terminationObserver: Any?
    private var liveness: Timer?

    init(displays: DisplayManager) { self.displays = displays }

    // MARK: - Listing

    /// Every window another app has open that is worth putting on air: a real
    /// window (layer 0), at least `minSize`, not Presenter's own, on ANY Space
    /// (2026-09-19: "ANY application window that's open"; a full-screen
    /// browser lives on its own Space and `.optionOnScreenOnly` could not see it,
    /// while ScreenCaptureKit captures it fine, measured 2026-09-18). On-screen
    /// ones first; `isOnScreen` says which. Synchronous (the window server list,
    /// front to back) so the control API can answer in its handler; titles need
    /// the Screen Recording grant the capture already has.
    nonisolated static func shareable(minSize: CGSize = CGSize(width: 320, height: 200)) -> [Pick] {
        guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            ShowLog.log("window list: the window server returned nothing")
            return []
        }
        let own = Bundle.main.bundleIdentifier ?? ""
        var apps: [pid_t: NSRunningApplication] = [:]
        return list.compactMap { w in
            guard let id = w[kCGWindowNumber as String] as? UInt32,
                  let pid = w[kCGWindowOwnerPID as String] as? Int32,
                  let bounds = w[kCGWindowBounds as String] as? [String: CGFloat] else { return nil }
            let layer = w[kCGWindowLayer as String] as? Int ?? -1
            let frame = CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0, width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
            let app = apps[pid] ?? NSRunningApplication(processIdentifier: pid)
            apps[pid] = app
            // Every Space lists agents and services too (AutoFill, Siri, panel services, a VPN menu app,
            // 2026-09-19): only an application with a Dock presence is something to put on air.
            guard let app, app.activationPolicy == .regular, !app.isHidden else { return nil }
            let bundleID = app.bundleIdentifier ?? ""
            guard isCandidate(bundleID: bundleID, own: own, layer: layer, size: frame.size, minSize: minSize) else { return nil }
            // `.optionAll` includes windows with no backing store (never drawn): alpha 0 or a zero frame. Skip those.
            guard (w[kCGWindowAlpha as String] as? Double ?? 1) > 0 else { return nil }
            return Pick(windowID: id, ownerPID: pid, bundleID: bundleID,
                        appName: (w[kCGWindowOwnerName as String] as? String) ?? app.localizedName ?? bundleID,
                        title: (w[kCGWindowName as String] as? String) ?? "", frame: frame,
                        isOnScreen: (w[kCGWindowIsOnscreen as String] as? Bool) ?? false)
        }
        .sorted { a, b in a.isOnScreen != b.isOnScreen ? a.isOnScreen : false }   // stable: on-screen first, window-server order within
    }

    // MARK: - Attach / detach

    /// Park `pick` on the program display (behind the shield, sized to fit) and
    /// watch its app. Returns false with `error` set when the window is gone.
    @discardableResult
    /// `clicker` / `mute`: this pick's overrides of the bundle-id rule (nil = the rule). They belong to
    /// the pick, so every attach resets them first (assessment 2026-09-20 blocker 3: an API override
    /// leaked to the next window picked from the popover).
    func attach(_ pick: Pick, park: Bool = true, clicker: Bool? = nil, mute: Bool? = nil, cropTop: CGFloat? = nil) async -> Bool {
        guard !isBusy else { return false }
        profile = SourceProfile.rule(for: pick.bundleID).overriding(clicker: clicker, mute: mute, cropTop: cropTop)
        isBusy = true
        defer { isBusy = false }
        // The previous window goes home BEFORE this one is parked, awaited: fired and forgotten it raced the
        // park when both resolved to the same window (review, 2026-09-19).
        if let previous = self.pick, let parked = parkedFrame, phase == .attached {
            let home = homeFrame(for: previous)
            _ = await Task.detached { Self.move(pid: previous.ownerPID, title: previous.title, near: parked, to: home) }.value
        }
        detach(sendHome: false)
        error = nil
        guard let app = NSRunningApplication(processIdentifier: pick.ownerPID), !app.isTerminated else {
            error = "\(pick.appName) is not running any more"
            phase = .idle
            return false
        }
        guard Self.windowExists(pick.windowID) else {
            error = "the window \"\(pick.label)\" is gone"
            phase = .idle
            return false
        }
        self.pick = pick
        if park, let frame = displays.programScreenFrame {
            // NSScreen frames are bottom-left (Cocoa); AX positions are top-left global.
            // Measured 2026-09-18: the unconverted frame parked Keynote at y=321 on a
            // display whose top is y=-128.
            let target = Self.parkFrame(for: pick.frame.size, in: Self.topLeft(frame))
            let moved = await Task.detached { Self.move(pid: pick.ownerPID, title: pick.title, near: pick.frame, to: target) }.value
            parkedFrame = moved ? target : nil
            // An app lists no Accessibility windows for a Space that is not the current one (Music, 2026-09-19):
            // such a window cannot be parked, and is captured where it is; the take and the clicker still work.
            ShowLog.log(moved ? "window parked: \(pick.label) -> \(Int(target.width))x\(Int(target.height)) on the program display"
                              : "window NOT moved (\(pick.label)); captured where it is\(pick.isOnScreen ? "" : " (on another Space: not reachable to park)")")
        } else {
            parkedFrame = nil
        }
        phase = .attached
        watch(pick)
        ShowLog.log("window source attached: \(pick.label)")
        return true
    }

    /// Park the attached window on the CONTROL monitor at `size`, bottom-right (ZoomSource PICK, 2026-09-20:
    /// Zoom's dual-monitor second window must stay where the operator sees it, and its size IS the
    /// capture size). Top-left space. False when the window cannot be moved (another Space).
    func parkOnControl(size: CGSize) async -> Bool {
        guard let pick, phase == .attached,
              let screen = OperatorWindowSizing.operatorWindow?.screen ?? NSScreen.main else { return false }
        let c = Self.topLeft(screen.visibleFrame)
        let w = min(size.width, c.width - 32), h = min(size.height, c.height - 32)
        let target = CGRect(x: (c.maxX - w - 16).rounded(), y: (c.maxY - h - 16).rounded(), width: w.rounded(), height: h.rounded())
        let near = parkedFrame ?? pick.frame
        let moved = await Task.detached { Self.move(pid: pick.ownerPID, title: pick.title, near: near, to: target) }.value
        if moved { parkedFrame = target }
        ShowLog.log(moved ? "window parked on the control monitor: \(pick.label) -> \(Int(w))x\(Int(h))" : "window NOT moved to the control monitor (\(pick.label))")
        return moved
    }

    /// Give the window back: a window we parked goes HOME, to where it was, or to the control
    /// monitor when where it was is the program display or off every screen (2026-09-19:
    /// "when we let the window go I want it to return to the control monitor"). The app is
    /// otherwise not touched.
    func detach(sendHome: Bool = true) {
        if let o = terminationObserver { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        terminationObserver = nil
        liveness?.invalidate(); liveness = nil
        if sendHome, let pick, let parked = parkedFrame, phase == .attached {
            let home = homeFrame(for: pick)
            let label = pick.label
            Task.detached {
                let moved = Self.move(pid: pick.ownerPID, title: pick.title, near: parked, to: home)
                ShowLog.log(moved ? "window returned: \(label) -> \(Int(home.minX)),\(Int(home.minY)) \(Int(home.width))x\(Int(home.height))"
                                  : "window NOT returned (\(label)); it stays where it is")
            }
        }
        if pick != nil { ShowLog.log("window source detached") }
        pick = nil
        parkedFrame = nil
        phase = .idle
    }

    private func homeFrame(for pick: Pick) -> CGRect {
        let program = displays.programScreenFrame.map { Self.topLeft($0) }
        let screens = NSScreen.screens.map { Self.topLeft($0.frame) }
        let control = (OperatorWindowSizing.operatorWindow?.screen ?? NSScreen.main).map { Self.topLeft($0.frame) }
        return Self.homeFrame(original: pick.frame, program: program, control: control, screens: screens)
    }

    /// Where a parked window goes on LET GO. Its original frame, unless that frame's centre is on
    /// the program display (it would sit under the shield) or on no screen at all (a display that
    /// went away); then the control monitor, fitted and centred, never enlarged. Top-left space.
    /// With one display the control monitor IS the program display: then the original, untouched.
    nonisolated static func homeFrame(original: CGRect, program: CGRect?, control: CGRect?, screens: [CGRect]) -> CGRect {
        let centre = CGPoint(x: original.midX, y: original.midY)
        let onProgram = program?.contains(centre) ?? false
        let onAScreen = screens.contains { $0.contains(centre) }
        guard onProgram || !onAScreen, let control, control != program else { return original }
        let scale = min(1, control.width / max(1, original.width), control.height / max(1, original.height))
        let w = (original.width * scale).rounded(), h = (original.height * scale).rounded()
        return CGRect(x: (control.minX + (control.width - w) / 2).rounded(), y: (control.minY + (control.height - h) / 2).rounded(), width: w, height: h)
    }

    private func watch(_ pick: Pick) {
        terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier == pick.ownerPID else { return }
            Task { @MainActor in self?.lost("\(pick.appName) quit") }
        }
        liveness = Timer.commonModes(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.phase == .attached else { return }
                if !Self.windowExists(pick.windowID) { self.lost("the window \"\(pick.label)\" closed") }
            }
        }
    }

    private func lost(_ reason: String) {
        guard phase == .attached else { return }
        liveness?.invalidate(); liveness = nil
        phase = .lost
        error = reason
        ShowLog.error("window source lost: \(reason)")
        onLost?(reason)
    }

    // MARK: - Clicker (LiveNavigable)

    // Arrow keys and Home/End, posted to the owning process only. Every
    // slideshow app and every viewer tried takes arrows; space and page keys
    // do not survive a browser or a PDF viewer the same way.
    func liveNext()      { press(Self.keyCode(for: .next)) }
    func livePrevious()  { press(Self.keyCode(for: .previous)) }
    func liveGoToFirst() { press(Self.keyCode(for: .first)) }
    func liveGoToLast()  { press(Self.keyCode(for: .last)) }

    enum Command { case next, previous, first, last }
    nonisolated static func keyCode(for command: Command) -> CGKeyCode {
        switch command {
        case .next: return 124      // right arrow
        case .previous: return 123  // left arrow
        case .first: return 115     // home
        case .last: return 119      // end
        }
    }

    private func press(_ key: CGKeyCode) {
        guard phase == .attached, let pick else { ShowLog.log("click ignored: no window attached"); return }
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false) else { return }
        for e in [down, up] {
            e.setIntegerValueField(.eventSourceUserData, value: Self.eventTag)
            e.postToPid(pick.ownerPID)
        }
    }

    // MARK: - Pure rules (unit tested)

    nonisolated static func isCandidate(bundleID: String, own: String, layer: Int, size: CGSize, minSize: CGSize) -> Bool {
        !bundleID.isEmpty && bundleID != own && layer == 0 && size.width >= minSize.width && size.height >= minSize.height
    }

    /// Where the window goes: the program display, the window's aspect kept,
    /// as large as fits, centred. Top-left global space (AX, AppleScript).
    nonisolated static func parkFrame(for size: CGSize, in display: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return display }
        let scale = min(display.width / size.width, display.height / size.height)
        let w = (size.width * scale).rounded(), h = (size.height * scale).rounded()
        return CGRect(x: (display.minX + (display.width - w) / 2).rounded(),
                      y: (display.minY + (display.height - h) / 2).rounded(), width: w, height: h)
    }

    /// Cocoa (bottom-left origin, main screen height) -> top-left global space.
    nonisolated static func topLeft(_ cocoa: CGRect, mainHeight: CGFloat? = nil) -> CGRect {
        let h = mainHeight ?? NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: cocoa.minX, y: h - cocoa.maxY, width: cocoa.width, height: cocoa.height)
    }

    // MARK: - Accessibility + window server

    /// Does the window still exist, on ANY Space. `.optionIncludingWindow` alone answers only for a
    /// window on screen: with the picker listing every Space, a window on another one attached as
    /// "gone" and a parked one behind a full-screen app read as "closed" by the liveness watch
    /// (soak, 2026-09-19: twenty attaches refused while the window server listed the window).
    nonisolated private static func windowExists(_ id: CGWindowID) -> Bool {
        // The full listing, then a search: CGWindowListCreateDescriptionFromArray answered NOTHING for a
        // Swift-bridged CGWindowID in a compiled probe while the full listing had the window (2026-09-19).
        guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return false }
        return list.contains { ($0[kCGWindowNumber as String] as? UInt32) == id }
    }

    /// Move the AX window of `pid`: the one sitting at `near` (its last known frame) first, then the
    /// one titled `title`, then, only when the app has a single window, that one. Never "the first
    /// window" of an app with several: a title that changed while parked sent the operator's own
    /// window of that app flying (review, 2026-09-19). A minimized window is brought back first.
    /// Attributed to Presenter's own Accessibility grant.
    nonisolated private static func move(pid: pid_t, title: String, near: CGRect?, to frame: CGRect) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 2.0)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &ref) == .success,
              let windows = ref as? [AXUIElement] else { return false }
        func frameOf(_ w: AXUIElement) -> CGRect? {
            var pv: CFTypeRef?, sv: CFTypeRef?
            guard AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &pv) == .success,
                  AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &sv) == .success else { return nil }
            var p = CGPoint.zero, sz = CGSize.zero
            AXValueGetValue(pv as! AXValue, .cgPoint, &p); AXValueGetValue(sv as! AXValue, .cgSize, &sz)
            return CGRect(origin: p, size: sz)
        }
        func titleOf(_ w: AXUIElement) -> String? { var t: CFTypeRef?; AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &t); return t as? String }
        var hit: AXUIElement?
        if let near { hit = windows.first { w in guard let f = frameOf(w) else { return false }; return abs(f.minX - near.minX) < 4 && abs(f.minY - near.minY) < 4 && abs(f.width - near.width) < 4 && abs(f.height - near.height) < 4 } }
        if hit == nil, !title.isEmpty { hit = windows.first { titleOf($0) == title } }
        // The app moved it since it was listed: the window of that SIZE, if there is exactly one.
        if hit == nil, let near { let same = windows.filter { w in guard let f = frameOf(w) else { return false }; return abs(f.width - near.width) < 4 && abs(f.height - near.height) < 4 }; if same.count == 1 { hit = same.first } }
        if hit == nil, windows.count == 1 { hit = windows.first }
        guard let w = hit else {
            let seen = windows.map { w in "\(titleOf(w) ?? "")@\(frameOf(w).map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? "?")" }.joined(separator: " | ")
            ShowLog.log("window move: no AX window matched title \"\(title)\" near \(near.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? "nil"); seen: \(seen)")
            return false
        }
        var unminimized: DarwinBoolean = false
        AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        _ = unminimized
        var p = frame.origin, s = frame.size
        guard let pv = AXValueCreate(.cgPoint, &p), let sv = AXValueCreate(.cgSize, &s) else { return false }
        // Size, move, size again: some apps clamp the size to the display the window sat on.
        let a = AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, sv)
        let b = AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, pv)
        let c = AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, sv)
        return a == .success && b == .success && c == .success
    }

    var stateJSON: String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
        }
        func rect(_ r: CGRect?) -> String {
            guard let r else { return "null" }
            return "{\"x\":\(Int(r.minX)),\"y\":\(Int(r.minY)),\"w\":\(Int(r.width)),\"h\":\(Int(r.height))}"
        }
        let p = pick.map { "{\"id\":\($0.windowID),\"pid\":\($0.ownerPID),\"bundleID\":\"\(esc($0.bundleID))\",\"app\":\"\(esc($0.appName))\",\"title\":\"\(esc($0.title))\"}" } ?? "null"
        let e = error.map { "\"\(esc($0))\"" } ?? "null"
        return "{\"phase\":\"\(phase.rawValue)\",\"ready\":\(isReady),\"window\":\(p),\"parked\":\(rect(parkedFrame)),\"clicker\":\"\(clickerDrivesWindow ? "window" : "deck")\",\"muteOnReturn\":\(mutesOnReturn),\"cropTop\":\(Int(profile.cropTop)),\"error\":\(e)}"
    }

    nonisolated static func listJSON(_ picks: [Pick]) -> String {
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        let rows = picks.map {
            "{\"id\":\($0.windowID),\"pid\":\($0.ownerPID),\"bundleID\":\"\(esc($0.bundleID))\",\"app\":\"\(esc($0.appName))\",\"title\":\"\(esc($0.title))\",\"w\":\(Int($0.frame.width)),\"h\":\(Int($0.frame.height)),\"onScreen\":\($0.isOnScreen)}"
        }
        return "{\"windows\":[\(rows.joined(separator: ","))]}"
    }
}

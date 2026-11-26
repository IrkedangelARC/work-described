//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import AppKit
import ApplicationServices

/// V4 build plan item 2: open a PowerPoint deck natively, start the show with
/// Presenter View, park Presenter View on the confidence display, verify the
/// show landed on the program display, and hand focus back to Presenter.
///
/// Every rule here was MEASURED on the office workstation, 2026-09-16, PowerPoint 16.112
/// on macOS 27 (docs/V4_SWITCHER.md, step 2). Read that before changing the
/// order of anything:
/// - Presenter View ON stops PowerPoint forcing display mirroring.
/// - Presenter View moves ONLY by `bounds`. Never set it to the main display's
///   exact frame: the window is lost until the show restarts.
/// - PowerPoint picks which external gets the show and it cannot be moved by
///   script while Presenter View is on, so a wrong display is reported, not fixed.
/// - Presenter View on the MAIN display hides for good when PowerPoint loses
///   focus, and a `bounds` set brings a hidden Presenter View back on screen
///   (test D). So PowerPoint is never given focus: it launches in the
///   background, the show starts without `activate`, and the park orders
///   Presenter View in on the confidence display. Presenter stays frontmost.
///
/// Waits and verification go through Accessibility (window titles and frames),
/// which Presenter is already granted, not CGWindowList (window titles need
/// Screen Recording). The one-time setup Apple Events and the waits run OFF the
/// main thread: a live deck and the clicker must not freeze while PowerPoint
/// launches (the first on-box run blocked the main thread for more than 5 s).
@MainActor
@Observable
final class PowerPointSource: LiveNavigable {
    nonisolated static let bundleID = "com.microsoft.Powerpoint"
    /// Only the formats that were measured. .ppsx and friends open differently.
    static let documentExtensions: Set<String> = ["pptx", "ppt", "pptm"]

    enum Phase: String {
        case idle       // nothing opened by Presenter
        case opening    // PowerPoint launching / waiting for the document window
        case starting   // run slide show sent, waiting for the show windows
        case parked     // show running; `problems` says whether it is safe to take
        case failed     // the open sequence stopped, see `error`
    }

    private(set) var phase: Phase = .idle
    /// While `.opening`: what the wait is for ("downloading from iCloud 41%").
    private(set) var progress: String?
    private(set) var file: URL?
    private(set) var error: String?
    /// Empty while parked = ready to take. Recomputed by every verify.
    private(set) var problems: [String] = []
    private(set) var showFrame: CGRect?
    private(set) var presenterViewFrame: CGRect?
    /// Focus after the park: "kept" (Presenter never lost it), "activate",
    /// "launchServices" or "none". Architecture B wants Presenter frontmost; if it is not, the
    /// clicker still works (PowerPoint receives the keys itself) but Hot Corners
    /// are live and the control window is not key.
    private(set) var focusReturnedBy: String?

    var isReady: Bool { phase == .parked && problems.isEmpty }
    var isBusy: Bool { phase == .opening || phase == .starting }

    private let displays: DisplayManager
    @ObservationIgnored private let commands = PowerPointCommandQueue()
    /// Clicker telemetry: pending, sent, dropped (stale), failed, latency.
    private(set) var clickStats = PowerPointCommandQueue.Stats()
    private var reparkTask: Task<Void, Never>?
    /// PowerPoint quit or crashed while parked (or live). SwitchEngine returns
    /// to the deck; nothing else would notice until the next refresh.
    var onLost: ((String) -> Void)?

    init(displays: DisplayManager) {
        self.displays = displays
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == Self.bundleID else { return }
            Task { @MainActor in self?.powerPointTerminated() }
        }
        // Any display change re-lays PowerPoint out (step 1), so re-park after it.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.displaysChanged() }
        }
    }

    // MARK: - Open + park

    func open(_ url: URL) async {
        guard !isBusy else { return }
        file = url
        error = nil
        problems = []
        showFrame = nil
        presenterViewFrame = nil
        focusReturnedBy = nil
        let base = url.deletingPathExtension().lastPathComponent

        guard Self.documentExtensions.contains(url.pathExtension.lowercased()) else {
            return fail("only .pptx, .ppt and .pptm are supported so far: \(url.lastPathComponent)")
        }
        guard !url.lastPathComponent.hasPrefix("~$"), !url.lastPathComponent.hasPrefix(".") else {
            return fail("\(url.lastPathComponent) is PowerPoint's lock file, not a deck")
        }
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) else {
            return fail("Microsoft PowerPoint is not installed")
        }

        ShowLog.log("PowerPoint open: \(url.lastPathComponent)")
        phase = .opening
        progress = nil
        // 0. An iCloud placeholder (Desktop and Documents live in iCloud Drive;
        //    a 969 MB keynote deck was evicted, 2026-09-16) makes PowerPoint
        //    sit with no window until the bytes arrive. Download it first, with
        //    progress on the status line, then open.
        if let problem = await Self.materialize(url, progress: { [weak self] in self?.progress = $0 }) {
            return fail(problem)
        }
        progress = nil
        // 1. Open the file in the background. Presenter keeps focus (architecture B).
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        do {
            _ = try await NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: config)
        } catch {
            return fail("PowerPoint could not open \(url.lastPathComponent): \(error.localizedDescription)")
        }
        // A cold launch took ~20 s on the office workstation; files on iCloud Desktop can take longer.
        dialog = nil
        guard await waitForWindow(seconds: 90, { Self.isDocumentWindow($0, base: base) }) != nil else {
            if let dialog { return fail("PowerPoint is showing a dialog and cannot open \(base): \(dialog)") }
            return fail("PowerPoint did not show \(base) within 90 s")
        }
        // Make sure the show about to start is THIS file, not another open deck.
        let (name, nameError) = await Self.osascript(Self.script("get name of active presentation", timeout: 10))
        guard let active = name, active == url.lastPathComponent || active == base else {
            return fail("PowerPoint's active presentation is \(name ?? nameError ?? "unknown"), not \(url.lastPathComponent)")
        }

        // 2. Start the show with Presenter View.
        phase = .starting
        let (_, runError) = await Self.osascript(Self.script("""
            set sss to slide show settings of active presentation
            set show with presenter of sss to true
            run slide show sss
            """, timeout: 20))
        if let runError { return fail("PowerPoint would not start the show: \(runError)") }
        guard await waitForWindow(seconds: 20, { Self.isShowWindow($0, base: base) }) != nil else {
            if let dialog { return fail("PowerPoint is showing a dialog and the show did not start: \(dialog)") }
            return fail("the slide show did not start within 20 s")
        }

        // 3. Park Presenter View BEFORE Presenter takes focus back.
        var parkProblem: String?
        if await waitForWindow(seconds: 5, { Self.isPresenterViewWindow($0, base: base) }) != nil {
            parkProblem = await parkPresenterView()
            try? await Task.sleep(for: .milliseconds(1500))
        } else {
            parkProblem = "Presenter View did not open, so there are no notes on the confidence display"
        }

        // 3b. PowerPoint saves the show monitor PER PRESENTATION: a deck that
        //     was set up on another machine can put its show on the main display
        //     (a 1.25 deck, 2026-09-16). `swap displays` moves the show to
        //     the external and hides Presenter View, and a re-park brings it back.
        await verifyOffMain()
        if let show = showFrame, Self.framesMatch(show, CGDisplayBounds(CGMainDisplayID())),
           let programID = displays.programScreenID, !Self.framesMatch(show, CGDisplayBounds(programID)) {
            ShowLog.log("show landed on the main display; swapping displays")
            let (_, swapError) = await Self.osascript(Self.script("swap displays presenter tool of presenter view window 1", timeout: 10))
            if let swapError { ShowLog.log("swap displays failed: \(swapError)") }
            try? await Task.sleep(for: .milliseconds(2500))
            if let p = await parkPresenterView() { parkProblem = parkProblem ?? p }
            try? await Task.sleep(for: .milliseconds(1500))
        }

        // A close() that raced this open (the operator hit CLOSE, or opened
        // another deck) already reset the state; do not resurrect it.
        guard file == url else { ShowLog.log("open of \(base) abandoned: closed while parking"); return }
        // 4. Architecture B: Presenter keeps focus and forwards the clicker. If
        //    PowerPoint grabbed focus anyway (a cold launch can), try to take it back.
        phase = .parked
        focusReturnedBy = NSApp.isActive ? "kept" : await takeFocusBack()
        // PowerPoint's document window, created by a background app, can still
        // land above Presenter's control windows on the work monitor (seen
        // 2026-09-16). Put Presenter's ordinary windows back on top.
        for window in NSApp.windows where window.isVisible && window.level == .normal { window.orderFrontRegardless() }
        // The composite reveal needs Screen Recording; prompt now, not at the take.
        WindowCapture.requestPermission()
        // Re-check after the focus change: that is when a badly parked
        // Presenter View disappears.
        try? await Task.sleep(for: .milliseconds(1500))
        guard file == url, phase == .parked else { ShowLog.log("open of \(base) abandoned: closed during the final check"); return }
        await verifyOffMain()
        guard file == url, phase == .parked else { return }
        if let parkProblem, !problems.contains(parkProblem) { problems.insert(parkProblem, at: 0) }
        ShowLog.log("parked \(base): ready=\(isReady) show=\(showFrame.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? "none") pv=\(presenterViewFrame.map { "\(Int($0.minX)),\(Int($0.minY))" } ?? "none") focus=\(focusReturnedBy ?? "?")\(problems.isEmpty ? "" : " problems: " + problems.joined(separator: " | "))")
    }

    /// After a relaunch: the show may still be running in PowerPoint exactly
    /// as it was parked. Adopt it instead of re-opening (which would take 10 s
    /// and be refused for 90 s while the old show closes). False when
    /// PowerPoint is gone or the deck is not showing; `file` stays set so the
    /// SOURCES window can offer to reopen it.
    @discardableResult
    func reattach(_ url: URL) async -> Bool {
        guard phase == .idle else { return false }
        file = url
        error = nil
        problems = []
        let base = url.deletingPathExtension().lastPathComponent
        guard let pid = Self.runningPowerPoint?.processIdentifier else {
            error = "PowerPoint is not running; REOPEN restarts \(url.lastPathComponent)"
            ShowLog.log("re-attach: PowerPoint not running for \(base)")
            return false
        }
        let windows = await Task.detached { Self.axWindows(pid: pid) }.value
        guard windows.contains(where: { Self.isShowWindow($0, base: base) }) else {
            error = "\(base) is not showing in PowerPoint; REOPEN restarts it"
            ShowLog.log("re-attach: no show window for \(base)")
            return false
        }
        phase = .parked
        apply(windows: windows)
        focusReturnedBy = NSApp.isActive ? "kept" : "none"
        ShowLog.log("re-attached to the PowerPoint show \(base): ready=\(isReady)\(problems.isEmpty ? "" : " problems: " + problems.joined(separator: " | "))")
        return true
    }

    /// End the show and close the presentation. Never quits PowerPoint: a
    /// scripted quit parks it in its file gallery ignoring further quits, and a
    /// kill relaunches it (measured 2026-09-16).
    func close() async {
        guard phase == .parked || phase == .failed else { return }
        ShowLog.log("PowerPoint close: \(file?.lastPathComponent ?? "?")")
        _ = await Self.osascript(Self.script("""
            try
            exit slide show slideshow view of slide show window 1
            end try
            try
            close active presentation saving no
            end try
            """, timeout: 10))
        phase = .idle
        file = nil
        error = nil
        problems = []
        showFrame = nil
        presenterViewFrame = nil
        focusReturnedBy = nil
    }

    /// PowerPoint is gone: say so everywhere at once instead of leaving a
    /// parked phase and a frozen picture (stability audit 2026-09-16, R4).
    private func powerPointTerminated() {
        guard phase != .idle else { return }
        let wasParked = phase == .parked
        phase = .failed
        progress = nil
        error = "PowerPoint quit"
        problems = ["PowerPoint quit"]
        showFrame = nil
        presenterViewFrame = nil
        reparkTask?.cancel(); reparkTask = nil
        ShowLog.error("PowerPoint quit while \(wasParked ? "parked" : "opening")")
        onLost?("PowerPoint quit")
    }

    /// Re-read what PowerPoint is actually doing. Moves nothing. The AX reads
    /// run off main (they took up to 1 s per attribute on a busy PowerPoint,
    /// audit R3); `problems` updates when they return.
    func refresh() {
        guard phase == .parked else { return }
        Task { @MainActor in await verifyOffMain() }
    }

    /// macOS 14+ activation is cooperative, and on 2026-09-16 `NSApp.activate()`
    /// alone left PowerPoint frontmost. Try it, check, then ask LaunchServices.
    private func takeFocusBack() async -> String {
        NSApp.activate()
        try? await Task.sleep(for: .milliseconds(500))
        if NSApp.isActive { return "activate" }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        _ = try? await NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config)
        try? await Task.sleep(for: .milliseconds(500))
        if NSApp.isActive { return "launchServices" }
        NSLog("ARC Presenter: could not take focus back from PowerPoint")
        return "none"
    }

    private func displaysChanged() {
        guard phase == .parked else { return }
        reparkTask?.cancel()
        reparkTask = Task { @MainActor in
            // DisplayManager restores its own outputs ~0.5 s after the change.
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled, phase == .parked else { return }
            let problem = await parkPresenterView()
            try? await Task.sleep(for: .milliseconds(1000))
            await verifyOffMain()
            if let problem, !problems.contains(problem) { problems.insert(problem, at: 0) }
            ShowLog.log("displays changed, re-parked: ready=\(isReady) \(problems)")
        }
    }

    /// Returns a problem string when Presenter View could not be parked.
    private func parkPresenterView() async -> String? {
        guard let confidenceID = displays.confidenceScreenID else {
            return "No confidence display assigned, so Presenter View stays where PowerPoint put it"
        }
        let target = CGDisplayBounds(confidenceID)
        if let refusal = Self.presenterViewRefusal(target: target, main: CGDisplayBounds(CGMainDisplayID())) {
            return refusal
        }
        let (_, parkError) = await Self.osascript(Self.script("set bounds of presenter view window 1 to \(Self.appleScriptBounds(target))", timeout: 5))
        return parkError.map { "Presenter View could not be moved: \($0)" }
    }

    private func verify() {
        guard let pid = Self.runningPowerPoint?.processIdentifier else { return apply(windows: nil) }
        apply(windows: Self.axWindows(pid: pid))
    }

    private func verifyOffMain() async {
        guard let pid = Self.runningPowerPoint?.processIdentifier else { return apply(windows: nil) }
        apply(windows: await Task.detached { Self.axWindows(pid: pid) }.value)
    }

    private func apply(windows: [WindowInfo]?) {
        guard let windows, let base = file?.deletingPathExtension().lastPathComponent else {
            showFrame = nil
            presenterViewFrame = nil
            problems = ["PowerPoint is not running"]
            return
        }
        showFrame = windows.first { Self.isShowWindow($0, base: base) }?.frame
        presenterViewFrame = windows.first { Self.isPresenterViewWindow($0, base: base) }?.frame
        problems = Self.problems(
            show: showFrame, presenterView: presenterViewFrame,
            program: displays.programScreenID.map { CGDisplayBounds($0) },
            confidence: displays.confidenceScreenID.map { CGDisplayBounds($0) },
            name: displayName)
    }

    private func fail(_ message: String) {
        phase = .failed
        progress = nil
        error = message
        ShowLog.error("PowerPoint open FAILED: \(message)")
    }

    private func displayName(for frame: CGRect) -> String {
        displays.availableScreens.first { Self.framesMatch(CGDisplayBounds($0.id), frame) }?.localizedName
            ?? "\(Int(frame.width))x\(Int(frame.height)) at (\(Int(frame.minX)),\(Int(frame.minY)))"
    }

    // Never set the show's `slide state` (paused/running) over AppleScript: it
    // froze the show window's video while the audio kept playing (2026-09-16).

    // MARK: - Clicker (LiveNavigable)

    // Compiled once, executed per click: 26 ms median measured, vs 175 ms for osascript.
    func liveNext()      { navigate("go to next slide") }
    func livePrevious()  { navigate("go to previous slide") }
    func liveGoToFirst() { navigate("go to first slide") }
    func liveGoToLast()  { navigate("go to last slide") }

    private func navigate(_ verb: String) {
        // Never `tell` an app that is not running: AppleScript would launch
        // PowerPoint into its recovery dialog after a crash (audit R3).
        guard Self.runningPowerPoint != nil else {
            ShowLog.log("click \(verb) ignored: PowerPoint is not running")
            return
        }
        commands.send(Self.script("\(verb) slideshow view of slide show window 1", timeout: 2), key: verb) { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                self.clickStats = self.commands.statsSnapshot
                if let error { ShowLog.log("PowerPoint \(verb): \(error)") }
            }
        }
    }

    // MARK: - iCloud placeholders

    /// Returns a problem string, or nil once the file's bytes are on disk.
    static func materialize(_ url: URL, timeout: TimeInterval = 600, progress: @MainActor (String) -> Void) async -> String? {
        let keys: Set<URLResourceKey> = [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey, .ubiquitousItemDownloadingErrorKey, .fileSizeKey, .fileAllocatedSizeKey]
        guard let values = try? url.resourceValues(forKeys: keys), values.isUbiquitousItem == true else { return nil }
        if values.ubiquitousItemDownloadingStatus == .current { return nil }
        let total = values.fileSize ?? 0
        do { try FileManager.default.startDownloadingUbiquitousItem(at: url) }
        catch { return "\(url.lastPathComponent) is in iCloud and the download could not start: \(error.localizedDescription)" }
        ShowLog.log("downloading from iCloud: \(url.lastPathComponent) (\(total / 1_000_000) MB)")
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try? await Task.sleep(for: .seconds(1))
            guard let now = try? url.resourceValues(forKeys: keys) else { continue }
            if let err = now.ubiquitousItemDownloadingError { return "iCloud download failed: \(err.localizedDescription)" }
            if now.ubiquitousItemDownloadingStatus == .current { ShowLog.log("iCloud download complete"); return nil }
            let have = now.fileAllocatedSize ?? 0
            let pct = total > 0 ? Int(Double(have) / Double(total) * 100) : 0
            progress("downloading from iCloud \(min(pct, 99))% (\(have / 1_000_000) of \(total / 1_000_000) MB)")
        }
        return "\(url.lastPathComponent) is still downloading from iCloud after \(Int(timeout / 60)) min. Keep the show files on the local disk"
    }

    // MARK: - Apple Events + Accessibility

    /// One-time setup commands, run by osascript on a background thread so the
    /// main thread (live deck, clicker, control API) never waits on PowerPoint.
    /// NSAppleScript cannot do this: it is main-thread only.
    nonisolated static func osascript(_ source: String) async -> (String?, String?) {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", source]
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            do { try process.run() } catch { return (nil, error.localizedDescription) }
            process.waitUntilExit()
            let stdout = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard process.terminationStatus == 0 else {
                return (nil, stderr.isEmpty ? "osascript exited \(process.terminationStatus)" : stderr)
            }
            return (stdout, nil)
        }.value
    }

    nonisolated private static var runningPowerPoint: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    }

    struct WindowInfo: Equatable {
        let title: String
        let frame: CGRect   // top-left global, the same space as CGDisplayBounds and AppleScript bounds
    }

    /// Text of a modal dialog PowerPoint is showing, if any. A dialog ("found a
    /// problem with content… Repair?", 2026-09-16) blocks every later open, so
    /// the wait reports it instead of sitting out its 90 s.
    private(set) var dialog: String?

    private func waitForWindow(seconds: Double, _ match: (WindowInfo) -> Bool) async -> WindowInfo? {
        let deadline = Date().addingTimeInterval(seconds)
        var polls = 0
        while Date() < deadline {
            if let pid = Self.runningPowerPoint?.processIdentifier {
                // A launching PowerPoint can stall AX calls, so poll off the main thread.
                let windows = await Task.detached { Self.axWindows(pid: pid) }.value
                if let hit = windows.first(where: match) { return hit }
                polls += 1
                if polls % 4 == 0 {
                    let text: String? = await Task.detached { Self.dialogText(pid: pid) }.value
                    if let text { dialog = text; return nil }
                }
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return nil
    }

    /// The static text of PowerPoint's front dialog or sheet, or nil.
    nonisolated private static func dialogText(pid: pid_t) -> String? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1.0)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &ref) == .success,
              let windows = ref as? [AXUIElement] else { return nil }
        for window in windows {
            var sub: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &sub)
            let subrole = (sub as? String) ?? ""
            var sheets: CFTypeRef?
            AXUIElementCopyAttributeValue(window, "AXSheets" as CFString, &sheets)
            let sheet = (sheets as? [AXUIElement])?.first
            guard subrole == "AXDialog" || subrole == "AXSystemDialog" || sheet != nil else { continue }
            var kids: CFTypeRef?
            AXUIElementCopyAttributeValue(sheet ?? window, kAXChildrenAttribute as CFString, &kids)
            let texts = ((kids as? [AXUIElement]) ?? []).compactMap { child -> String? in
                var role: CFTypeRef?, value: CFTypeRef?
                AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &role)
                guard (role as? String) == "AXStaticText" else { return nil }
                AXUIElementCopyAttributeValue(child, kAXValueAttribute as CFString, &value)
                return (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty }
            let joined = texts.joined(separator: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return joined.isEmpty ? "a dialog with no text" : joined
        }
        return nil
    }

    nonisolated private static func axWindows(pid: pid_t) -> [WindowInfo] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1.0)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &ref) == .success,
              let windows = ref as? [AXUIElement] else { return [] }
        return windows.compactMap { window in
            var title: CFTypeRef?, position: CFTypeRef?, size: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title)
            AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &position)
            AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &size)
            guard let position, let size,
                  CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
            var point = CGPoint.zero, extent = CGSize.zero
            AXValueGetValue(position as! AXValue, .cgPoint, &point)
            AXValueGetValue(size as! AXValue, .cgSize, &extent)
            return WindowInfo(title: (title as? String) ?? "", frame: CGRect(origin: point, size: extent))
        }
    }

    // MARK: - Pure rules (unit tested)

    static func script(_ body: String, timeout: Int) -> String {
        """
        with timeout of \(timeout) seconds
        tell application id "\(bundleID)"
        \(body)
        end tell
        end timeout
        """
    }

    /// AppleScript bounds are {left, top, right, bottom} in top-left global space.
    static func appleScriptBounds(_ frame: CGRect) -> String {
        "{\(Int(frame.minX)), \(Int(frame.minY)), \(Int(frame.maxX)), \(Int(frame.maxY))}"
    }

    static func isDocumentWindow(_ window: WindowInfo, base: String) -> Bool {
        window.title.hasPrefix(base) && !window.title.hasPrefix("PowerPoint ")
    }

    static func isShowWindow(_ window: WindowInfo, base: String) -> Bool {
        window.title.hasPrefix("PowerPoint Slide Show - [\(base)")
    }

    static func isPresenterViewWindow(_ window: WindowInfo, base: String) -> Bool {
        window.title.hasPrefix("PowerPoint Presenter View - [\(base)")
    }

    static func framesMatch(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 2) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    /// Why Presenter View must not be sent to `target`, or nil when it is safe.
    static func presenterViewRefusal(target: CGRect, main: CGRect) -> String? {
        guard framesMatch(target, main) else { return nil }
        return "The confidence display is the main display. Presenter View there hides when Presenter takes focus back, and setting it to the main display's frame loses the window until the show restarts"
    }

    static func problems(show: CGRect?, presenterView: CGRect?,
                         program: CGRect?, confidence: CGRect?,
                         name: (CGRect) -> String) -> [String] {
        var out: [String] = []
        if let show {
            if let program {
                if !framesMatch(show, program) {
                    out.append("PowerPoint put the show on \(name(show)), not the program display \(name(program)). Presenter swaps a show off the main display; any other display needs the arrangement changed")
                }
            } else {
                out.append("No program display is assigned")
            }
        } else {
            out.append("The PowerPoint slide show is not running")
        }
        if let confidence {
            if let presenterView {
                if !framesMatch(presenterView, confidence) {
                    out.append("Presenter View is on \(name(presenterView)), not the confidence display \(name(confidence))")
                }
            } else if show != nil {
                out.append("Presenter View is not on screen. Restart the PowerPoint show to get it back")
            }
        }
        return out
    }

    // MARK: - Control API

    var stateJSON: String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\t", with: "\\t")
        }
        func rect(_ r: CGRect?) -> String {
            guard let r else { return "null" }
            return "{\"x\":\(Int(r.minX)),\"y\":\(Int(r.minY)),\"w\":\(Int(r.width)),\"h\":\(Int(r.height))}"
        }
        let file = self.file.map { "\"\(esc($0.path))\"" } ?? "null"
        let error = self.error.map { "\"\(esc($0))\"" } ?? "null"
        let progress = self.progress.map { "\"\(esc($0))\"" } ?? "null"
        let problems = self.problems.map { "\"\(esc($0))\"" }.joined(separator: ",")
        let focus = focusReturnedBy.map { "\"\($0)\"" } ?? "null"
        let clicks = "{\"pending\":\(clickStats.pending),\"sent\":\(clickStats.sent),\"dropped\":\(clickStats.dropped),\"failed\":\(clickStats.failed),\"lastMs\":\(clickStats.lastLatencyMs),\"maxMs\":\(clickStats.maxLatencyMs)}"
        return "{\"clicks\":\(clicks),\"phase\":\"\(phase.rawValue)\",\"ready\":\(isReady),\"progress\":\(progress),\"file\":\(file),\"error\":\(error),\"show\":\(rect(showFrame)),\"presenterView\":\(rect(presenterViewFrame)),\"presenterFrontmost\":\(NSApp.isActive),\"focusReturnedBy\":\(focus),\"problems\":[\(problems)]}"
    }
}

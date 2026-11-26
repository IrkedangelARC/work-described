//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import AppKit

/// PLAN_zoom_source build A + B (2026-09-20: "zoom to have its own control sub window under
/// the sources expanded control"). What Presenter can know and do about the Zoom client beside it,
/// all from the window list, no Zoom API:
///
/// - the meeting is up (a "Zoom Meeting" window exists), dual monitors are ON (TWO of them: the
///   drill measured that Zoom's MAIN meeting window collapses off screen on every share start while
///   the dual-monitor SECOND window survives, so the second window is the only usable source);
/// - Zoom is sharing (its "zoom share statusbar window" is on screen) and sharing OUR share window
///   (its "Annotation - Zoom" overlay sits exactly on the share window's frame);
/// - the attached window went off screen or its picture stopped: FROZEN, said out loud (finding 6:
///   the capture held a frame for 90 s while the source read "attached");
/// - the share ENDED under us: Zoom was sharing our window and now is not while the meeting is still
///   up. A Presenter relaunch (install, the Guard after a crash) closes the share window and Zoom's
///   share dies with it; nobody is reading a checklist at that moment (assessment blocker 2).
///
/// PICK attaches the second window in place, parks it on the CONTROL monitor at a fixed size (Zoom
/// put it under the program shield the first time, finding 18), opens the share window when it is
/// closed, and arms the switch. The bundle-id rule in WindowSource keeps the clicker on the deck and
/// RETURN from muting Zoom.
///
/// The window listing runs OFF the main actor once a second (292 windows took 3.5 ms plus a running
/// application lookup per window on the main thread before; assessment item 6); `classify` is pure.
@MainActor
@Observable
final class ZoomSource {
    nonisolated static let bundleID = "us.zoom.xos"
    nonisolated static let meetingTitle = "Zoom Meeting"
    nonisolated static let shareBarTitle = "zoom share statusbar window"
    nonisolated static let annotationTitle = "Annotation - Zoom"
    /// Where PICK parks the second window on the control monitor: capture = window size, and 1280 wide
    /// is the floor for a program picture that is not soft.
    nonisolated static let controlParkSize = CGSize(width: 1280, height: 720)
    /// A live source whose picture is older than this while its window is off screen is FROZEN.
    nonisolated static let frozenAfter: TimeInterval = 4
    /// Remembered across relaunches: Zoom was sharing our window when we last looked.
    nonisolated static let wasSharingKey = "zoom.wasSharingOurs"
    /// The XCTest host runs this class too; it must never touch the operator's memory.
    nonisolated static let underTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    /// One Zoom window as the window server reports it (points, top-left space).
    struct Win: Equatable, Sendable {
        let id: CGWindowID
        let title: String
        let frame: CGRect
        let onScreen: Bool
    }

    /// What the window list says right now. Pure to build, so it is tested.
    struct Snapshot: Equatable, Sendable {
        var running = false
        var meetingWindows: [Win] = []
        var sharing = false
        var sharingOurs = false
        var dualMonitors: Bool { meetingWindows.count >= 2 }
        var inMeeting: Bool { !meetingWindows.isEmpty }
        /// The dual-monitor second window: Zoom creates it after the main one, so it carries the higher
        /// window number. With one meeting window there is no second, and PICK refuses.
        var secondWindowID: CGWindowID? {
            guard meetingWindows.count >= 2 else { return nil }
            return meetingWindows.map(\.id).max()
        }
        var mainWindowID: CGWindowID? { meetingWindows.map(\.id).min() }
    }

    enum SourceState: String { case none, ready, live, frozen, lost }

    private(set) var snapshot = Snapshot()
    private(set) var sourceState: SourceState = .none
    /// Zoom was sharing our window (this run or the last) and is not now, with the meeting still up.
    private(set) var shareEnded = false
    private(set) var lastError: String?
    private(set) var isBusy = false

    private let windows: WindowSource
    private let capture: WindowCapture
    private let switcher: SwitchEngine
    private let share: ShareOutput
    private let defaults: UserDefaults
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var isRefreshing = false
    @ObservationIgnored private var reopenedShare = false
    @ObservationIgnored private var noMeetingRefreshes = 0
    @ObservationIgnored private var isTerminating = false
    @ObservationIgnored private var terminateObserver: NSObjectProtocol?

    init(windows: WindowSource, capture: WindowCapture, switcher: SwitchEngine, share: ShareOutput, defaults: UserDefaults = .standard) {
        self.windows = windows
        self.capture = capture
        self.switcher = switcher
        self.share = share
        self.defaults = defaults
        timer = Timer.commonModes(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        // No scan during teardown: what it reads then is not the room's state.
        terminateObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.isTerminating = true; self?.timer?.invalidate(); self?.timer = nil }
        }
        Task { @MainActor in await refresh() }
    }

    // MARK: - Pure rules (tested)

    /// Build the snapshot from window records. `shareFrame` is our share window's frame (top-left
    /// space) when it is open; Zoom's annotation overlay on that frame means Zoom is sharing it.
    nonisolated static func classify(zoomWindows: [Win], zoomRunning: Bool, shareFrame: CGRect?) -> Snapshot {
        var s = Snapshot()
        s.running = zoomRunning
        s.meetingWindows = zoomWindows.filter { $0.title == meetingTitle && $0.frame.width >= 300 && $0.frame.height >= 200 }
        s.sharing = zoomWindows.contains { $0.title == shareBarTitle && $0.onScreen }
        if let shareFrame, s.sharing {
            s.sharingOurs = zoomWindows.contains { w in
                w.title == annotationTitle && w.onScreen && abs(w.frame.minX - shareFrame.minX) <= 2 && abs(w.frame.minY - shareFrame.minY) <= 2
                    && abs(w.frame.width - shareFrame.width) <= 2 && abs(w.frame.height - shareFrame.height) <= 2
            }
        }
        return s
    }

    /// FROZEN: the source is live or armed, its window is off screen (collapsed, hidden) and no frame
    /// has arrived for `frozenAfter`. A window on another Space still renders, so on-screen alone is
    /// not the test; a static picture on an on-screen window is normal (SCK sends changes only).
    nonisolated static func isFrozen(windowOnScreen: Bool, lastFrameAge: TimeInterval?, captureRunning: Bool) -> Bool {
        guard captureRunning, !windowOnScreen else { return false }
        guard let age = lastFrameAge else { return true }
        return age >= frozenAfter
    }

    /// SHARE ENDED: we remember Zoom sharing our window; it is not now; the meeting is still up. Once
    /// Zoom shares our window again, or the meeting ends, the memory clears.
    nonisolated static func shareEnded(wasSharing: Bool, sharingOurs: Bool, inMeeting: Bool) -> Bool {
        wasSharing && !sharingOurs && inMeeting
    }

    // MARK: - Refresh

    /// One pass: the window listing off the main actor, then the rules on it. Overlapping calls (the
    /// timer, `GET /zoom`, PICK) collapse into one.
    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID)
        let pids = Set(apps.map(\.processIdentifier))
        let shareFrame = share.isOpen ? ShareOutput.frameTopLeft() : nil
        let wins = await Task.detached(priority: .utility) { Self.zoomWindows(ofPIDs: pids) }.value
        let snap = Self.classify(zoomWindows: wins, zoomRunning: !pids.isEmpty, shareFrame: shareFrame)
        if snap != snapshot { snapshot = snap }
        sourceState = computeSourceState(wins)
        updateShareMemory(snap)
    }

    private func updateShareMemory(_ snap: Snapshot) {
        let was = defaults.bool(forKey: Self.wasSharingKey)
        if snap.sharingOurs {
            if !was, !Self.underTest { defaults.set(true, forKey: Self.wasSharingKey) }
            if shareEnded { ShowLog.log("Zoom is sharing the program picture again") }
            shareEnded = false
            return
        }
        if !snap.inMeeting {
            // Forget only when ZOOM ITSELF is gone, three refreshes in a row, never while quitting. "No
            // meeting window" is not enough: a process without the Screen Recording grant reads no window
            // titles at all (the XCTest host cleared the flag between a quit and a relaunch, twice, 09:11
            // and 09:26), and a meeting that ends while Zoom stays up costs nothing to remember.
            noMeetingRefreshes += 1
            if was, !snap.running, noMeetingRefreshes >= 3, !isTerminating, !Self.underTest {
                defaults.set(false, forKey: Self.wasSharingKey)
                ShowLog.log("Zoom share memory cleared: Zoom not running for \(noMeetingRefreshes) s")
            }
            shareEnded = false
            return
        }
        noMeetingRefreshes = 0
        let ended = Self.shareEnded(wasSharing: was, sharingOurs: snap.sharingOurs, inMeeting: snap.inMeeting)
        if ended, !shareEnded { ShowLog.error("Zoom SHARE ENDED: Zoom was sharing \"\(ShareOutput.title)\" and is not now; re-share it in Zoom (a Presenter relaunch closes the share window)") }
        shareEnded = ended
        // The share window itself comes back on its own after a relaunch, so the operator's only step is Zoom's picker.
        if ended, !share.isOpen, !reopenedShare {
            reopenedShare = true
            Task { @MainActor in await share.open() }
        }
    }

    private func computeSourceState(_ wins: [Win]) -> SourceState {
        guard let pick = windows.pick, pick.bundleID == Self.bundleID else { return .none }
        if windows.phase == .lost { return .lost }
        guard windows.isAttached(to: pick.windowID) else { return .none }
        let onScreen = wins.first { $0.id == pick.windowID }?.onScreen ?? false
        if capture.windowID == pick.windowID,
           Self.isFrozen(windowOnScreen: onScreen, lastFrameAge: capture.pictureAge, captureRunning: capture.isRunning) {
            if sourceState != .frozen { ShowLog.error("Zoom source FROZEN: \(pick.label) is off screen and its picture is \(Int(capture.pictureAge ?? 99)) s old (Zoom collapses its main window on share start; use the dual-monitor second window)") }
            return .frozen
        }
        return switcher.liveSource == .window ? .live : .ready
    }

    /// The window server's records for `pids` only: no per-window object creation, callable off main.
    nonisolated private static func zoomWindows(ofPIDs pids: Set<pid_t>) -> [Win] {
        guard !pids.isEmpty, let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { w in
            guard let pid = w[kCGWindowOwnerPID as String] as? pid_t, pids.contains(pid),
                  let id = w[kCGWindowNumber as String] as? UInt32,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { return nil }
            let frame = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
            return Win(id: id, title: (w[kCGWindowName as String] as? String) ?? "", frame: frame,
                       onScreen: (w[kCGWindowIsOnscreen as String] as? Bool) ?? false)
        }
    }

    // MARK: - Actions

    /// PICK: the dual-monitor second window onto the control monitor, armed. Refuses with the reason
    /// when Zoom has no meeting or one meeting window only (the main one collapses on share start).
    /// Opens the share window when it is closed: the recipe needs both, and the JSON says so.
    @discardableResult
    func pick() async -> Bool {
        guard !isBusy else { return false }
        isBusy = true; defer { isBusy = false }
        lastError = nil
        await refresh()
        guard snapshot.running else { return fail("Zoom is not running") }
        guard snapshot.inMeeting else { return fail("Zoom has no meeting window: start or join the meeting first") }
        guard let second = snapshot.secondWindowID else {
            return fail("Zoom shows ONE meeting window: turn on Use dual monitors (Settings > Meetings & webinars > In-meeting experience > Display). The main window collapses when a share starts, so it cannot be the source")
        }
        guard switcher.liveSource != .window, !switcher.isBusy else { return fail("return to the deck before picking a Zoom window") }
        if !share.isOpen { await share.open() }
        guard let p = WindowSource.shareable().first(where: { $0.windowID == second }) else {
            return fail("Zoom's second window is not listable (too small, or gone)")
        }
        if capture.isRunning { await capture.stop() }
        guard await windows.attach(p, park: false) else { return fail(windows.error ?? "could not attach Zoom's second window") }
        _ = await windows.parkOnControl(size: Self.controlParkSize)
        let prepared = await switcher.prepare(.window)
        if !prepared { ShowLog.log("Zoom: attached, capture not yet prepared (\(switcher.lastError ?? "no reason"))") }
        ShowLog.log("Zoom: second window \(second) picked, armed")
        await refresh()
        return true
    }

    func take() async { _ = await switcher.takeWindow() }
    func returnToDeck() async { _ = await switcher.returnToDeck() }

    func letGo() async {
        guard switcher.liveSource != .window else { return }
        if capture.windowID == windows.pick?.windowID { await capture.stop() }
        windows.detach()
        await refresh()
    }

    private func fail(_ reason: String) -> Bool {
        lastError = reason
        ShowLog.error("Zoom pick refused: \(reason)")
        return false
    }

    // MARK: - Readout

    /// The health chip: what the STATUS window and the footer say about Zoom. The state word is set
    /// HERE only (HealthMonitor passes it through).
    var chip: (level: HealthMonitor.Level, state: String, detail: String) {
        if shareEnded {
            return (.bad, "SHARE ENDED", "Zoom was sharing \"\(ShareOutput.title)\" and is not now (a Presenter relaunch closes the share window). Re-share it in Zoom: Share, Application windows, \"\(ShareOutput.title)\", Share sound ticked")
        }
        switch sourceState {
        case .frozen: return (.bad, "FROZEN", "Zoom's window is off screen and its picture stopped: it collapsed on share start. RETURN, then PICK the dual-monitor second window")
        case .lost: return (.bad, "LOST", windows.error ?? "Zoom's window is gone")
        case .live: return (.ok, "LIVE", "Zoom on the program output\(snapshot.sharingOurs ? ", sharing the program picture" : "")")
        case .ready: return (.ok, "READY", "Zoom's second window armed\(snapshot.sharingOurs ? ", sharing the program picture" : "")")
        case .none:
            if !snapshot.running { return (.off, "OFF", "Zoom is not running") }
            if !snapshot.inMeeting { return (.off, "NO MEETING", "Zoom is running with no meeting window") }
            if !snapshot.dualMonitors { return (.warn, "ONE WINDOW", "Zoom shows one meeting window: turn on Use dual monitors before PICK") }
            return (.off, "NOT PICKED", "Zoom meeting up with dual monitors; PICK arms its second window")
        }
    }

    var json: String {
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        let wins = snapshot.meetingWindows.map { "{\"id\":\($0.id),\"w\":\(Int($0.frame.width)),\"h\":\(Int($0.frame.height)),\"onScreen\":\($0.onScreen)}" }.joined(separator: ",")
        let err = lastError.map { "\"\(esc($0))\"" } ?? "null"
        let c = chip
        return "{\"running\":\(snapshot.running),\"inMeeting\":\(snapshot.inMeeting),\"dualMonitors\":\(snapshot.dualMonitors),\"meetingWindows\":[\(wins)],\"secondWindow\":\(snapshot.secondWindowID.map(String.init) ?? "null"),\"sharing\":\(snapshot.sharing),\"sharingOurs\":\(snapshot.sharingOurs),\"shareEnded\":\(shareEnded),\"shareOpen\":\(share.isOpen),\"source\":\"\(sourceState.rawValue)\",\"chip\":{\"level\":\"\(c.level.rawValue)\",\"state\":\"\(c.state)\",\"detail\":\"\(esc(c.detail))\"},\"error\":\(err),\"poll\":\"GET /zoom (a POST answers with the state BEFORE the action; PICK also opens the share window)\"}"
    }
}

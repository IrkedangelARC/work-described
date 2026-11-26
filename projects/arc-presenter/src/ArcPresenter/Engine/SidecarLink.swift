//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import AppKit

/// ARC Zoom, the sidecar (arc-zoom, HTTP 8766), driven from Presenter. Decision 2026-09-20 evening
///: Presenter is the only operator surface and owns every output; the Zoom SDK lives in its own
/// process. So this class does three things and nothing else:
///
/// 1. KNOWS the sidecar: polls `/state`, `/meeting` and `/health` once a second and keeps the words the
///    operator needs (in a meeting, program on, co-host needed, warning, own uplink quality).
/// 2. LAUNCHES it when asked (`/Applications/ARC Zoom.app`), and leaves it running: the SDK's 600 MB
///    of frameworks and its own threads never enter this process (stability assessment, item 1).
/// 3. AUTO-ATTACHES its program window as the window source whenever the sidecar has a meeting and a
///    program window and nothing is attached, so the operator never repeats the attach after a sidecar
///    restart (every restart makes a new window id, PLAN_controls.md trap 9).
///
/// SCOPE (2026-09-20 21:50): "the control of the zoom should stay in the stand alone app and only
/// use ARC Presenter for screen and audio control." So Presenter forwards exactly two things: the SCREEN
/// (attach / let go; TAKE and RETURN are the switcher's) and the ROOM AUDIO (the call's return level and
/// its mute, PLAN_controls.md 3.9). Meetings, participants, spotlight, settings and sound presets are
/// ARC Zoom's own window. LAUNCH exists only so the operator is never stuck with a dead sidecar.
@MainActor
@Observable
final class SidecarLink {
    nonisolated static let bundleID = "com.example.arc.ArcZoom"
    nonisolated static let programTitle = "ARC Zoom Program"
    nonisolated static let base = URL(string: "http://127.0.0.1:8766")!
    nonisolated static let appURL = URL(fileURLWithPath: "/Applications/ARC Zoom.app")
    nonisolated static let underTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    /// What the sidecar said last, reduced to what the room needs.
    struct Snapshot: Equatable, Sendable {
        var reachable = false
        var engine = ""
        var state = ""                      // idle, joining, inMeeting, reconnecting, failed
        var meetingNumber: String?
        var participants = 0
        var programName: String?
        var programOpen = false
        var amHost = false
        var coHostNeeded = false
        var warning: String?
        var uplink: String?                 // video.up from /health selfQuality
        var preset = ""
        var speakerVolume = -1.0
        var speakerOutput = true
        var audioConfig = ""
        var inMeeting: Bool { state == "inMeeting" }
    }

    private(set) var snapshot = Snapshot()
    private(set) var lastError: String?
    private(set) var isBusy = false
    /// Auto-attach is on unless the operator LETS GO of the sidecar window; then it waits for ATTACH.
    var autoAttach = true

    private let windows: WindowSource
    private let capture: WindowCapture
    private let switcher: SwitchEngine
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var isRefreshing = false
    @ObservationIgnored private var attaching = false
    @ObservationIgnored private var lastAttachAttempt: Date = .distantPast

    init(windows: WindowSource, capture: WindowCapture, switcher: SwitchEngine) {
        self.windows = windows
        self.capture = capture
        self.switcher = switcher
        guard !Self.underTest else { return }
        timer = Timer.commonModes(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        Task { @MainActor in await refresh() }
    }

    // MARK: - Pure rules (tested)

    /// Reduce the three JSON documents to the snapshot. Missing documents leave their fields at rest.
    nonisolated static func classify(state: [String: Any]?, meeting: [String: Any]?, health: [String: Any]?, sound: [String: Any]?) -> Snapshot {
        var s = Snapshot()
        guard let state else { return s }
        s.reachable = true
        s.engine = state["engine"] as? String ?? ""
        s.state = state["state"] as? String ?? ""
        s.meetingNumber = state["meeting"] as? String
        let people = state["participants"] as? [[String: Any]] ?? []
        s.participants = people.count
        s.programName = people.first { ($0["program"] as? Bool) == true }?["display"] as? String
        s.programOpen = (state["windows"] as? [[String: Any]] ?? []).contains { ($0["kind"] as? String) == "program" && ($0["open"] as? Bool) == true }
        if let meeting {
            s.amHost = meeting["amHost"] as? Bool ?? false
            s.coHostNeeded = meeting["coHostNeeded"] as? Bool ?? false
            s.warning = meeting["warning"] as? String
        }
        if let health, let q = health["selfQuality"] as? [String: String] { s.uplink = q["video.up"] }
        if let sound {
            s.preset = sound["preset"] as? String ?? ""
            s.speakerVolume = sound["speakerVolume"] as? Double ?? -1
            s.speakerOutput = sound["speakerOutput"] as? Bool ?? true
            s.audioConfig = sound["config"] as? String ?? ""
        }
        return s
    }

    /// Attach when: the sidecar is in a meeting with its program window open, auto-attach is on, the
    /// window source is not already on that window, and no other window source is live.
    nonisolated static func shouldAttach(snapshot: Snapshot, autoAttach: Bool, attachedToProgram: Bool, windowLive: Bool, busy: Bool) -> Bool {
        autoAttach && snapshot.inMeeting && snapshot.programOpen && !attachedToProgram && !windowLive && !busy
    }

    // MARK: - Refresh

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        async let st = get("/state")
        async let me = get("/meeting")
        async let he = get("/health")
        async let so = get("/sound")
        let snap = Self.classify(state: await st, meeting: await me, health: await he, sound: await so)
        if snap != snapshot {
            if snap.reachable != snapshot.reachable { ShowLog.log(snap.reachable ? "ARC Zoom sidecar reachable on 8766" : "ARC Zoom sidecar not answering on 8766") }
            if snap.coHostNeeded, !snapshot.coHostNeeded { ShowLog.error("ARC Zoom needs CO-HOST: ask the meeting's host to promote it before any meeting-wide control") }
            snapshot = snap
        }
        await autoAttachIfWanted()
    }

    private var attachedToProgram: Bool {
        guard let p = windows.pick, p.bundleID == Self.bundleID, p.title == Self.programTitle else { return false }
        return windows.isAttached(to: p.windowID)
    }

    private func autoAttachIfWanted() async {
        let windowLive = switcher.liveSource == .window
        guard Self.shouldAttach(snapshot: snapshot, autoAttach: autoAttach, attachedToProgram: attachedToProgram,
                                windowLive: windowLive, busy: attaching || windows.isBusy || switcher.isBusy) else { return }
        guard Date().timeIntervalSince(lastAttachAttempt) > 3 else { return }
        lastAttachAttempt = Date()
        _ = await attach()
    }

    // MARK: - Actions

    /// Launch the installed sidecar. Everything after that (engine, meeting, devices) is done in its window.
    @discardableResult
    func launch() async -> Bool {
        guard FileManager.default.fileExists(atPath: Self.appURL.path) else { return fail("ARC Zoom is not installed at \(Self.appURL.path)") }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        do {
            _ = try await NSWorkspace.shared.openApplication(at: Self.appURL, configuration: config)
            ShowLog.log("ARC Zoom launched")
            return true
        } catch {
            return fail("could not launch ARC Zoom: \(error.localizedDescription)")
        }
    }

    /// Attach the sidecar's program window as the window source and arm the switch. Same path as a
    /// hand-picked window; the arcZoom profile applies (no crop, keys stay on the deck).
    @discardableResult
    func attach() async -> Bool {
        guard !attaching else { return false }
        attaching = true; defer { attaching = false }
        guard let p = WindowSource.shareable().first(where: { $0.bundleID == Self.bundleID && $0.title == Self.programTitle }) else {
            return fail("the sidecar's program window is not on screen (POST 8766/window?kind=program&on=1)")
        }
        if windows.isAttached(to: p.windowID) { return true }
        guard switcher.liveSource != .window, !switcher.isBusy else { return fail("return to the deck before attaching the sidecar") }
        if capture.isRunning { await capture.stop() }
        guard await windows.attach(p, park: true) else { return fail(windows.error ?? "could not attach the sidecar's program window") }
        let prepared = await switcher.prepare(.window)
        ShowLog.log("ARC Zoom program window \(p.windowID) attached, \(prepared ? "armed" : "attached, capture not yet prepared")")
        autoAttach = true
        return true
    }

    func letGo() async {
        guard switcher.liveSource != .window else { return }
        autoAttach = false
        if capture.windowID == windows.pick?.windowID { await capture.stop() }
        windows.detach()
    }

    /// The call's return level into the room, BASIC and CONSOLE only (3.9).
    func returnLevel(delta: Double) async {
        let v = max(0, min(100, (snapshot.speakerVolume < 0 ? 100 : snapshot.speakerVolume) + delta))
        _ = await post("/audio/speaker?volume=\(Int(v))")
        await refresh()
    }
    func returnMute(_ mute: Bool) async { _ = await post("/audio/speaker?on=\(mute ? 0 : 1)"); await refresh() }
    private func fail(_ reason: String) -> Bool {
        lastError = reason
        ShowLog.error("ARC Zoom: \(reason)")
        return false
    }

    // MARK: - HTTP

    nonisolated private func get(_ path: String) async -> [String: Any]? {
        var req = URLRequest(url: Self.base.appendingPathComponent(path))
        req.timeoutInterval = 1.5
        guard let (data, resp) = try? await URLSession.shared.data(for: req), let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    nonisolated private func post(_ pathAndQuery: String) async -> [String: Any]? {
        guard let url = URL(string: Self.base.absoluteString + pathAndQuery) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        guard let (data, resp) = try? await URLSession.shared.data(for: req), let http = resp as? HTTPURLResponse else { return nil }
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if http.statusCode >= 400 {
            let reason = body?["error"] as? String ?? "HTTP \(http.statusCode)"
            await MainActor.run { self.lastError = reason; ShowLog.error("ARC Zoom \(pathAndQuery): \(reason)") }
            return nil
        }
        return body ?? [:]
    }

    // MARK: - Readout

    var chip: (level: HealthMonitor.Level, state: String, detail: String) {
        if !snapshot.reachable { return (.off, "OFF", "ARC Zoom is not running; LAUNCH it") }
        if snapshot.coHostNeeded { return (.warn, "CO-HOST NEEDED", "ARC Zoom is in someone else's meeting and not yet co-host: meeting-wide controls will refuse until the host promotes it") }
        if let w = snapshot.warning { return (.bad, w, "Zoom's own warning for the sidecar's connection") }
        switch snapshot.state {
        case "inMeeting":
            let uplink = snapshot.uplink ?? "?"
            if attachedToProgram {
                return (switcher.liveSource == .window ? .ok : .ok, switcher.liveSource == .window ? "LIVE" : "READY",
                        "sidecar program on \(snapshot.programName ?? "nobody"), uplink \(uplink)")
            }
            return (snapshot.programOpen ? .warn : .warn, snapshot.programOpen ? "NOT ATTACHED" : "NO PROGRAM WINDOW",
                    snapshot.programOpen ? "the sidecar's program window is up; ATTACH" : "the sidecar has no program window open")
        case "joining": return (.warn, "JOINING", "the sidecar is joining")
        case "reconnecting": return (.bad, "RECONNECTING", "the sidecar lost the meeting and is reconnecting")
        case "failed": return (.bad, "FAILED", "the sidecar's meeting failed")
        default: return (.off, "NO MEETING", "ARC Zoom is up (\(snapshot.engine)) with no meeting; start one in ARC Zoom")
        }
    }

    var json: String {
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        let c = chip
        return "{\"reachable\":\(snapshot.reachable),\"engine\":\"\(snapshot.engine)\",\"state\":\"\(snapshot.state)\",\"participants\":\(snapshot.participants),"
            + "\"program\":\(snapshot.programName.map { "\"\(esc($0))\"" } ?? "null"),\"programOpen\":\(snapshot.programOpen),\"attached\":\(attachedToProgram),\"autoAttach\":\(autoAttach),"
            + "\"amHost\":\(snapshot.amHost),\"coHostNeeded\":\(snapshot.coHostNeeded),\"uplink\":\(snapshot.uplink.map { "\"\($0)\"" } ?? "null"),"
            + "\"preset\":\"\(snapshot.preset)\",\"audioConfig\":\"\(snapshot.audioConfig)\",\"speakerVolume\":\(snapshot.speakerVolume),\"speakerOutput\":\(snapshot.speakerOutput),"
            + "\"chip\":{\"level\":\"\(c.level.rawValue)\",\"state\":\"\(c.state)\",\"detail\":\"\(esc(c.detail))\"},"
            + "\"error\":\(lastError.map { "\"\(esc($0))\"" } ?? "null")}"
    }
}

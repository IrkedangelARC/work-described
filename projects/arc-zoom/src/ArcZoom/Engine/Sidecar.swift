//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import AppKit
import CoreVideo

/// The orchestrator: one engine, three output windows, and the rules about who appears where.
///
/// The distinction that matters, and the reason this class exists rather than the views talking to the
/// engine: SPOTLIGHT is a Zoom call that changes what every ATTENDEE sees, and PROGRAM is a local
/// choice that changes what the ROOM sees. They are usually the same person and occasionally must not
/// be. Presenter's operator drives PROGRAM; the meeting's host drives SPOTLIGHT; this holds both.
@MainActor
@Observable
final class Sidecar {
    /// How PROGRAM picks its participant.
    enum ProgramMode: String, CaseIterable, Sendable {
        /// Whoever the meeting spotlights, falling back to the first remote. The default: one action in
        /// the operator page spotlights AND puts them on the program monitor.
        case spotlight
        /// The operator chose; the meeting's spotlight does not move it.
        case manual
    }

    private(set) var engine: any ZoomEngine
    let windows: [LayoutWindow.Kind: LayoutWindow]

    // Mirrored from the engine so SwiftUI has one source and the views never hold the existential.
    private(set) var roster: [Participant] = []
    private(set) var state: MeetingState = .idle
    private(set) var lastError: String?
    /// What the operator surface shows: the engine's refusal for 8 s after it happened, else ours.
    var errorLine: String? {
        if let sdk = engine as? SDKZoomEngine, let e = sdk.lastError, let t = sdk.lastErrorAt, Date().timeIntervalSince(t) < 8 { return e }
        return lastError
    }
    private(set) var isSharing = false
    private(set) var sharedWindowTitle: String?
    var engineKind: String { engine.kind }

    /// Which output windows are open. Mirrored here because `LayoutWindow` is a plain class and SwiftUI
    /// cannot observe it: the OUTPUT WINDOWS chips read OFF while the windows were plainly open
    /// (2026-09-20).
    private(set) var openKinds: Set<LayoutWindow.Kind> = []

    var programMode: ProgramMode = .spotlight { didSet { OperatorPrefs.set("programMode", programMode.rawValue) } }
    private(set) var programID: UInt32?
    /// The aspect every tile is drawn at. 16:9 unless a room needs otherwise.
    var tileAspect: CGFloat = 16.0 / 9.0 { didSet { OperatorPrefs.set("tileAspect", Double(tileAspect)) } }

    /// The window ARC Presenter opens for Zoom to share. Named here because the sidecar is what starts
    /// that share, which is the step that removes Zoom's picker from the operator's show.
    static let presenterShareWindow = "ARC Presenter Program"

    @ObservationIgnored private var frames: [UInt32: CVPixelBuffer] = [:]
    /// Outputs the operator has blacked while they sit on a display.
    private(set) var blackKinds: Set<LayoutWindow.Kind> = []
    /// Pinned by the operator: the client, the keynote, the person who must never be scrolled away.
    private(set) var vips: Set<UInt32> = []
    let micMeter = MicMeter()
    /// The PREVIEW module (OUTPUTS panel): a camera or a video file, seen here before SHARE THIS sends it.
    let preview = PreviewPlayer()
    /// The pre-flight TEST MIC / TEST AUDIO OUT sequences (2026-09-21), run before a meeting.
    let audioCheck = AudioCheck()
    private(set) var isCreatingMeeting = false

    func toggleVIP(_ id: UInt32) { if vips.contains(id) { vips.remove(id) } else { vips.insert(id) } }
    func isVIP(_ id: UInt32) -> Bool { vips.contains(id) }

    /// The roster the operator reads: the host first, then whoever spoke most recently, then the VIPs,
    /// then everyone else by name. We are listed last unless we are the host.
    /// When each participant was first seen this meeting: the roster's order is JOIN order and nothing
    /// else, so a row never moves under the pointer (2026-09-21: "participants are jumping in
    /// order which makes clicking the right one impossible"; the old rank put the latest talker second).
    @ObservationIgnored private var firstSeen: [UInt32: (Int, Date)] = [:]
    @ObservationIgnored private var seenCounter = 0

    /// Host first, then the VIPs the operator pinned (a deliberate act, so it may reorder once), then
    /// everyone in the order they joined, the operator last. TALKING is a lamp on the row, never a rank.
    var orderedRoster: [Participant] {
        func rank(_ p: Participant) -> (Int, Int, String) {
            if p.isHost { return (0, 0, p.displayName) }
            if vips.contains(p.id) { return (1, firstSeen[p.id]?.0 ?? .max, p.displayName) }
            if p.isMe { return (3, 0, p.displayName) }
            return (2, firstSeen[p.id]?.0 ?? .max, p.displayName)
        }
        return roster.sorted { a, b in
            let ra = rank(a), rb = rank(b)
            if ra.0 != rb.0 { return ra.0 < rb.0 }
            if ra.1 != rb.1 { return ra.1 < rb.1 }
            return ra.2.localizedCaseInsensitiveCompare(rb.2) == .orderedAscending
        }
    }

    /// Pure form of the same rule, for the test: ids in join order, then a roster in any order.
    nonisolated static func stableOrder(_ roster: [Participant], joinOrder: [UInt32], vips: Set<UInt32>) -> [UInt32] {
        func rank(_ p: Participant) -> (Int, Int, String) {
            if p.isHost { return (0, 0, p.displayName) }
            if vips.contains(p.id) { return (1, joinOrder.firstIndex(of: p.id) ?? .max, p.displayName) }
            if p.isMe { return (3, 0, p.displayName) }
            return (2, joinOrder.firstIndex(of: p.id) ?? .max, p.displayName)
        }
        return roster.sorted { a, b in
            let ra = rank(a), rb = rank(b)
            if ra.0 != rb.0 { return ra.0 < rb.0 }
            if ra.1 != rb.1 { return ra.1 < rb.1 }
            return ra.2.localizedCaseInsensitiveCompare(rb.2) == .orderedAscending
        }.map(\.id)
    }

    /// CREATE MEETING: the SDK engine if we are not on it yet, authenticate, start the ARC Tech meeting
    /// as host. One press from cold. The invite lands in the header when the meeting is up.
    func createMeeting(displayName: String = "ARC Zoom") async -> Bool {
        guard !isCreatingMeeting else { return false }
        isCreatingMeeting = true; defer { isCreatingMeeting = false }
        guard let sdk = await ensureSDK() else { return false }
        let ok = await sdk.startMeeting(displayName: displayName)
        if !ok { lastError = sdk.lastError }
        return ok
    }

    /// The SDK engine, switched to and authenticated, without a meeting: what CREATE MEETING does
    /// first, and what the pre-flight audio checks need (the SDK's device list and test helpers work
    /// with no meeting up). nil = the reason is in `lastError`.
    func ensureSDK() async -> SDKZoomEngine? {
        var sdk = engine as? SDKZoomEngine
        if sdk == nil {
            guard SDKZoomEngine.available else { lastError = SDKZoomEngine.unavailableReason; return nil }
            let s = SDKZoomEngine()
            await use(s)
            sdk = s
        }
        guard let sdk else { return nil }
        if !sdk.isAuthenticated { guard await sdk.prepare() else { lastError = sdk.lastError; return nil } }
        return sdk
    }

    func endMeeting() async {
        if let sdk = engine as? SDKZoomEngine, sdk.amHost { await sdk.endForAll(); try? await Task.sleep(nanoseconds: 1_500_000_000) }
        await engine.leave()
    }
    /// What each output shows. Defaults: PROGRAM = the speaker, GALLERY = the gallery, STRIP = the strip.
    private(set) var scenes: [LayoutWindow.Kind: OutputScene] = [
        .program: OutputScene.named("SPEAKER")!, .gallery: OutputScene.named("GALLERY")!, .strip: OutputScene.named("STRIP")!,
    ]
    /// The active share's source id once the share subscription exists; nil draws the SHARE placeholder.
    var shareSourceID: UInt32?

    func scene(for kind: LayoutWindow.Kind) -> OutputScene { scenes[kind] ?? OutputScene.presets[0] }

    @discardableResult
    func setScene(_ name: String, for kind: LayoutWindow.Kind) -> Bool {
        guard let sc = OutputScene.named(name) else { lastError = "no scene named \(name); presets: \(OutputScene.presets.map(\.name).joined(separator: ", "))"; return false }
        scenes[kind] = sc
        OperatorPrefs.set("scene." + kind.rawValue, sc.name)
        ShowLog.log("\(kind.title): scene \(sc.name)")
        Task { await resubscribe() }
        relayout()
        return true
    }

    /// Who fills an element right now.
    func people(for element: OutputScene.Element) -> [UInt32] {
        switch element {
        case .speaker: return programID.flatMap { id in roster.contains { $0.id == id } ? [id] : nil } ?? []
        // Remotes first; the sidecar's own camera last, and only while SELF VIEW is on (2026-09-20:
        // "self view not working in gallery", then "self view does not toggle the gallery").
        case .gallery, .strip: return remotes.filter(\.videoOn).map(\.id) + (selfViewOn ? people(for: .selfView) : [])
        case .share: return shareSourceID.map { [$0] } ?? []
        case .selfView: return roster.first { $0.isMe && $0.videoOn }.map { [$0.id] } ?? []
        // Everyone spotlit in the MEETING, in the order they were spotlit; the operator is never on the
        // room's screen. Zoom only spotlights video-on participants, so nothing is filtered here.
        case .spotlight: return roster.filter { $0.isSpotlighted && !$0.isMe }.sorted { ($0.spotlightRank ?? .max) < ($1.spotlightRank ?? .max) }.map(\.id)
        }
    }
    /// Previews in the operator window (Presenter's format: the picture on the left), drawn exactly like
    /// the windows and from the same frames, so what the operator sees IS what the room gets.
    @ObservationIgnored private var mirrors: [LayoutWindow.Kind: TileHostView] = [:]

    /// SELF VIEW: our own camera in the operator window. Off by default; the SDK hands us our own frames
    /// through the same renderer when we subscribe to our own id.
    var selfViewOn = false { didSet { guard oldValue != selfViewOn else { return }; OperatorPrefs.set("selfView", selfViewOn); Task { await resubscribe() }; relayout() } }
    @ObservationIgnored private var selfHost: TileHostView?
    func selfMirror() -> TileHostView {
        if let h = selfHost { return h }
        let h = TileHostView(frame: .zero)
        h.onLayout = { [weak self] in self?.relayout() }
        selfHost = h
        return h
    }

    func mirror(for kind: LayoutWindow.Kind) -> TileHostView {
        if let m = mirrors[kind] { return m }
        let m = TileHostView(frame: .zero)
        m.onLayout = { [weak self] in self?.relayout() }
        mirrors[kind] = m
        Task { await resubscribe() }
        return m
    }
    @ObservationIgnored private var resizeObserver: NSObjectProtocol?

    init(engine: any ZoomEngine) {
        self.engine = engine
        var made: [LayoutWindow.Kind: LayoutWindow] = [:]
        for kind in LayoutWindow.Kind.allCases { made[kind] = LayoutWindow(kind: kind) }
        self.windows = made
        wire()
        restorePrefs()
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: nil, queue: .main) { [weak self] note in
                guard let w = note.object as? NSWindow else { return }
                MainActor.assumeIsolated {
                    guard let self, self.windows.values.contains(where: { $0.window === w }) else { return }
                    self.relayout()
                }
            }
    }

    /// What the operator had set last time (OperatorPrefs). Windows stay closed; outputs stay off.
    private func restorePrefs() {
        var notes: [String] = []
        for kind in LayoutWindow.Kind.allCases {
            if let name = OperatorPrefs.string("scene." + kind.rawValue), let sc = OutputScene.named(name), sc != scene(for: kind) { scenes[kind] = sc; notes.append("\(kind.rawValue) \(sc.name)") }
        }
        if let m = OperatorPrefs.string("programMode").flatMap(ProgramMode.init(rawValue:)), m != programMode { programMode = m; notes.append("program follows \(m.rawValue)") }
        let a = CGFloat(OperatorPrefs.double("tileAspect", default: Double(tileAspect)))
        if a != tileAspect { tileAspect = a; notes.append(String(format: "aspect %.2f", a)) }
        if OperatorPrefs.bool("selfView", default: false) { selfViewOn = true; notes.append("self view on") }
        if !notes.isEmpty { ShowLog.log("prefs restored: \(notes.joined(separator: ", "))") }
    }

    private func wire() {
        engine.onRosterChange = { [weak self] in self?.rosterChanged() }
        engine.onStateChange = { [weak self] s in self?.stateChanged(s) }
        engine.onFrame = { [weak self] id, buffer in self?.frameArrived(id, buffer) }
        (engine as? SDKZoomEngine)?.onShareChange = { [weak self] id in self?.shareChanged(id) }
        (engine as? SDKZoomEngine)?.onMicDeviceChange = { [weak self] name in self?.micMeter.restart(deviceNamed: name) }
    }

    private func shareChanged(_ id: UInt32?) {
        if let old = shareSourceID, old != id { engine.unsubscribe(from: old); frames[old] = nil }
        shareSourceID = id
        ShowLog.log(id.map { "SHARE source \($0) on the scenes" } ?? "SHARE slot empty")
        Task { await resubscribe() }
        relayout()
    }

    /// Swap the fake engine for the SDK one (or back) without restarting the app. Phase 0 will use this
    /// constantly: rehearse on the fake, then point at a real meeting.
    func use(_ new: any ZoomEngine) async {
        await engine.leave()
        engine.onRosterChange = nil; engine.onStateChange = nil; engine.onFrame = nil
        engine = new
        frames = [:]
        wire()
        rosterChanged()
        stateChanged(new.state)
        ShowLog.log("engine = \(new.kind)")
    }

    #if DEBUG
    /// Layout tests and their screenshots only (WindowSizingTests): the console drawn as if in a meeting,
    /// with no meeting, no SDK call, no mic meter and no subscription. Compiled out of Release.
    func stageForLayout(state: MeetingState, roster: [Participant]) {
        self.state = state
        self.roster = roster
    }
    #endif

    // MARK: - Engine callbacks

    private func rosterChanged() {
        roster = engine.participants
        for p in roster where firstSeen[p.id] == nil { seenCounter += 1; firstSeen[p.id] = (seenCounter, Date()) }
        if roster.isEmpty { firstSeen = [:]; seenCounter = 0 }
        isSharing = engine.isSharing
        sharedWindowTitle = engine.sharedWindowTitle
        if let sdk = engine as? SDKZoomEngine { sdk.syncPreview(preview) } else { preview.onAir = false; preview.shareMode = nil }
        Task { await resubscribe() }
        resolveProgram()
        relayout()
    }

    /// The Mac must not idle-sleep under a meeting (audit P1). Held while in a meeting, released on idle.
    @ObservationIgnored private var sleepAssertion: NSObjectProtocol?
    private func holdAwake(_ on: Bool) {
        if on, sleepAssertion == nil {
            sleepAssertion = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .idleDisplaySleepDisabled, .userInitiated], reason: "ARC Zoom meeting in progress")
            ShowLog.log("sleep held off for the meeting")
        } else if !on, let a = sleepAssertion {
            ProcessInfo.processInfo.endActivity(a); sleepAssertion = nil
            ShowLog.log("sleep allowed again")
        }
    }

    private func stateChanged(_ s: MeetingState) {
        state = s
        lastError = engine.lastError
        holdAwake(s == .inMeeting || s == .joining || s == .reconnecting)
        if s != .inMeeting { frames = [:]; roster = engine.participants; shareSourceID = nil; relayout(); micMeter.stop() }
        else {
            (engine as? SDKZoomEngine)?.wireMeetingDelegates()
            (engine as? SDKZoomEngine)?.refreshShare()
            (engine as? SDKZoomEngine)?.joinAudioOnEntry()
            micMeter.start(deviceNamed: (engine as? SDKZoomEngine)?.audioDevices.mic)
        }
        ShowLog.log("meeting \(s.rawValue)\(engine.meetingNumber.map { " (\($0))" } ?? "")")
    }

    private func frameArrived(_ id: UInt32, _ buffer: CVPixelBuffer) {
        frames[id] = buffer
        for (kind, window) in windows where window.isOpen && !blackKinds.contains(kind) {
            window.host.show(buffer, for: id)
        }
        for m in mirrors.values { m.show(buffer, for: id) }
        if selfViewOn, let h = selfHost { h.show(buffer, for: id) }
    }

    /// Subscribe to everyone the room could be shown, unsubscribe from the rest. Raw video is per
    /// participant in the SDK and is not free, so this is not "subscribe to all and forget".
    private func resubscribe() async {
        let wanted = Set(shownAnywhere())
        for id in Array(frames.keys) where !wanted.contains(id) { frames[id] = nil }   // one BGRA buffer per departed id leaked (audit P1)
        for id in wanted {
            if id == shareSourceID, let sdk = engine as? SDKZoomEngine { _ = await sdk.subscribeShare(id) }
            else { _ = await engine.subscribe(to: id) }
        }
        for p in engine.participants where !wanted.contains(p.id) { engine.unsubscribe(from: p.id) }
    }

    /// Every participant any open window would draw.
    private func shownAnywhere() -> [UInt32] {
        var ids: Set<UInt32> = []
        for (kind, window) in windows where window.isOpen {
            ids.formUnion(participants(for: kind).map(\.id))
        }
        for kind in mirrors.keys { ids.formUnion(participants(for: kind).map(\.id)) }
        if selfViewOn { ids.formUnion(people(for: .selfView)) }
        if let sid = shareSourceID {
            let wantsShare = windows.contains { k, w in w.isOpen && scene(for: k).elements.contains(.share) } || mirrors.keys.contains { scene(for: $0).elements.contains(.share) }
            if wantsShare { ids.insert(sid) }
        }
        // PROGRAM's participant is worth having ready even with every window shut, so a TAKE is instant.
        if let programID { ids.insert(programID) }
        return Array(ids)
    }

    // MARK: - Who goes where

    /// Everyone but us. PROGRAM never shows ourselves (the operator is in the room); GALLERY and STRIP do.
    var remotes: [Participant] { roster.filter { !$0.isMe } }

    /// Everyone this output's scene draws, in first-appearance order.
    func participants(for kind: LayoutWindow.Kind) -> [Participant] {
        var seen: Set<UInt32> = [], out: [Participant] = []
        for el in scene(for: kind).elements {
            for id in people(for: el) where !seen.contains(id) {
                if let p = roster.first(where: { $0.id == id }) { seen.insert(id); out.append(p) }
            }
        }
        return out
    }

    /// PROGRAM's participant under the current mode. Pure enough to test: given a roster and a mode,
    /// who fills the room's screen?
    nonisolated static func resolveProgram(roster: [Participant], mode: ProgramMode, current: UInt32?) -> UInt32? {
        let remotes = roster.filter { !$0.isMe }
        switch mode {
        case .spotlight:
            // The EARLIEST spotlight, by the SDK's own order, not the first spotlit person in the
            // participant list: adding a second spotlight must not move the room's screen.
            if let s = remotes.filter({ $0.isSpotlighted }).min(by: { ($0.spotlightRank ?? .max) < ($1.spotlightRank ?? .max) }) { return s.id }
            return remotes.first?.id
        case .manual:
            // Checked against REMOTES, not the whole roster: asked for by id or not, the operator never
            // goes on the room's screen, and a participant who left falls back rather than showing black.
            if let current, remotes.contains(where: { $0.id == current }) { return current }
            return remotes.first?.id
        }
    }

    private func resolveProgram() {
        let next = Self.resolveProgram(roster: roster, mode: programMode, current: programID)
        if next != programID {
            programID = next
            ShowLog.log("PROGRAM = \(next.map { id in roster.first { $0.id == id }?.displayName ?? "\(id)" } ?? "nobody")")
        }
    }

    /// Put a specific participant on the room's screen. Switches to manual, because an operator who
    /// picks someone does not want the meeting's spotlight moving it back.
    func setProgram(_ id: UInt32?) {
        programMode = .manual
        programID = id
        ShowLog.log("PROGRAM = \(id.map { i in roster.first { $0.id == i }?.displayName ?? "\(i)" } ?? "nobody") (manual)")
        Task { await resubscribe() }
        relayout()
    }

    func setProgramMode(_ mode: ProgramMode) {
        programMode = mode
        resolveProgram()
        Task { await resubscribe() }
        relayout()
    }

    // MARK: - Drawing

    func relayout() {
        for (kind, window) in windows where window.isOpen && !blackKinds.contains(kind) { draw(kind, into: window.host, size: window.size) }
        for (kind, m) in mirrors { draw(kind, into: m, size: m.bounds.size) }
        if let h = selfHost {
            if selfViewOn {
                var names: [UInt32: String] = [:]
                for p in roster { names[p.id] = p.displayName }
                let entries = OutputScene.named("SELF VIEW")!.tiles(in: CGRect(origin: .zero, size: h.bounds.size), aspect: tileAspect, people: { self.people(for: $0) }, names: names)
                h.set(entries: entries)
                for id in Set(entries.compactMap(\.participant)) { if let b = frames[id] { h.show(b, for: id) } }
            } else { h.clear() }
        }
        (engine as? SDKZoomEngine)?.hdID = programID
    }

    private func draw(_ kind: LayoutWindow.Kind, into host: TileHostView, size: CGSize) {
        let bounds = CGRect(origin: .zero, size: size)
        var names: [UInt32: String] = [:]
        for p in roster { names[p.id] = p.displayName }
        let entries = scene(for: kind).tiles(in: bounds, aspect: tileAspect, people: { self.people(for: $0) }, names: names)
        host.set(entries: entries)
        // Anything already held gets drawn at once, so a newly opened window is never black.
        for id in Set(entries.compactMap(\.participant)) { if let b = frames[id] { host.show(b, for: id) } }
    }

    // MARK: - Actions

    func open(_ kind: LayoutWindow.Kind, size: CGSize? = nil) {
        blackKinds.remove(kind)
        windows[kind]?.open(size: size)
        openKinds.insert(kind)
        Task { await resubscribe() }
        relayout()
    }

    /// OFF. If the window is on a display, this is BLACK: the window stays where it is, cleared to black,
    /// because PGM and MON never show the desktop (2026-09-20, the Presenter rule). Otherwise the
    /// ordinary window closes.
    func close(_ kind: LayoutWindow.Kind) {
        if windows[kind]?.isHeldOnDisplay == true {
            blackKinds.insert(kind)
            windows[kind]?.host.clear()
            ShowLog.log("\(kind.title): BLACK")
            return
        }
        windows[kind]?.close()
        openKinds.remove(kind)
        Task { await resubscribe() }
    }

    /// BLACK on any open window, held on a display or not, without closing it (audit P1: `/black` on an
    /// ordinary window used to close it and reopen it at the default size).
    func setBlack(_ kind: LayoutWindow.Kind, _ on: Bool) {
        guard windows[kind]?.isOpen == true else { return }
        if on { blackKinds.insert(kind); windows[kind]?.host.clear(); ShowLog.log("\(kind.title): BLACK") }
        else { blackKinds.remove(kind); relayout(); ShowLog.log("\(kind.title): picture") }
    }

    /// The display holding this window went away: the window was ordered out by DisplayManager, so the
    /// operator's chips must not keep saying ON AIR (audit P1, `didClose` was never wired).
    func displayLost(_ kind: LayoutWindow.Kind) {
        guard openKinds.contains(kind) else { return }
        windows[kind]?.close()
        openKinds.remove(kind); blackKinds.remove(kind)
        ShowLog.log("\(kind.title): closed, its display is gone")
        Task { await resubscribe() }
    }

    /// Held on a display right now.
    func isHeld(_ kind: LayoutWindow.Kind) -> Bool { windows[kind]?.isHeldOnDisplay == true }
    func isBlack(_ kind: LayoutWindow.Kind) -> Bool { blackKinds.contains(kind) }
    /// Every held output to black (or back to picture).
    func blackAll(_ on: Bool) {
        for kind in LayoutWindow.Kind.allCases where isHeld(kind) { on ? close(kind) : open(kind) }
    }

    func isOpen(_ kind: LayoutWindow.Kind) -> Bool { openKinds.contains(kind) }

    @discardableResult
    func spotlight(_ id: UInt32?, on: Bool = true) async -> Bool {
        let ok = await engine.spotlight(id, on: on)
        if ok {
            roster = engine.participants
            resolveProgram()
            relayout()
        } else {
            lastError = engine.lastError
        }
        return ok
    }

    @discardableResult
    func startShare(window title: String = Sidecar.presenterShareWindow, sound: Bool = true) async -> Bool {
        let ok = await engine.startShare(windowTitle: title, withSound: sound)
        isSharing = engine.isSharing
        sharedWindowTitle = engine.sharedWindowTitle
        lastError = engine.lastError
        ShowLog.log(ok ? "sharing \"\(title)\"\(sound ? " with sound" : "")" : "share refused: \(engine.lastError ?? "no reason")")
        return ok
    }

    func stopShare() async {
        await engine.stopShare()
        isSharing = engine.isSharing
        sharedWindowTitle = engine.sharedWindowTitle
        if let sdk = engine as? SDKZoomEngine { sdk.syncPreview(preview) } else { preview.onAir = false; preview.shareMode = nil }
        ShowLog.log("share stopped")
    }

    /// SHARE THIS in PREVIEW: exactly what the module shows goes to the call (SDKZoomEngine+RawShare).
    @discardableResult
    func sharePreview() async -> Bool {
        guard let sdk = engine as? SDKZoomEngine else { lastError = "not in a meeting (the rehearsal engine cannot share)"; return false }
        let ok = await sdk.sharePreview(preview)
        isSharing = sdk.isSharing
        sharedWindowTitle = sdk.sharedWindowTitle
        if !ok { lastError = sdk.lastError; preview.note = sdk.lastError }
        return ok
    }

    func stopPreviewShare() async {
        guard let sdk = engine as? SDKZoomEngine else { return }
        await sdk.stopPreviewShare(preview)
        isSharing = sdk.isSharing
        sharedWindowTitle = sdk.sharedWindowTitle
    }

    // MARK: - Control API

    var stateJSON: String {
        let people = roster.map { p in
            "{\"id\":\(p.id),\"name\":\"\(jsonEscape(p.name))\",\"display\":\"\(jsonEscape(p.displayName))\",\"me\":\(p.isMe),\"host\":\(p.isHost),\"coHost\":\(p.isCoHost),\"video\":\(p.videoOn),\"audio\":\(p.audioOn),\"audioJoined\":\(p.audioJoined),\"spotlight\":\(p.isSpotlighted),\"program\":\(p.id == programID)}"
        }.joined(separator: ",")
        let wins = LayoutWindow.Kind.allCases.compactMap { k in windows[k].map { w in
            w.json.replacingOccurrences(of: "\"open\":", with: "\"scene\":\"\(jsonEscape(scene(for: k).name))\",\"black\":\(blackKinds.contains(k)),\"held\":\(isHeld(k)),\"open\":") } }.joined(separator: ",")
        let err = lastError.map { "\"\(jsonEscape($0))\"" } ?? "null"
        let shared = sharedWindowTitle.map { "\"\(jsonEscape($0))\"" } ?? "null"
        return """
        {"engine":"\(engine.kind)","sdkAvailable":\(SDKZoomEngine.available),"state":"\(state.rawValue)",\
        "meeting":\(engine.meetingNumber.map { "\"\(jsonEscape($0))\"" } ?? "null"),\
        "programMode":"\(programMode.rawValue)","program":\(programID.map(String.init) ?? "null"),\
        "sharing":\(isSharing),"sharedWindow":\(shared),\
        "participants":[\(people)],"windows":[\(wins)],"error":\(err)}
        """
    }
}

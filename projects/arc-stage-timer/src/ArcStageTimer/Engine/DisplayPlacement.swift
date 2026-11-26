//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

#if os(macOS)
import AppKit
import Observation

/// What the displays look like right now, readable from the HTTP server's own queue. The window list and the
/// screen list are main-actor state; this is a copy taken on the main actor whenever either changes.
final class DisplaySnapshot: @unchecked Sendable {
    struct Row: Sendable { let index: Int; let name: String; let uuid: String; let width: Int; let height: Int; let isMain: Bool; let windows: [String] }
    static let shared = DisplaySnapshot()
    private let lock = NSLock()
    private var rows: [Row] = []
    private var _outputs: [String: String] = [:]
    private var _warnings: [String] = []
    var current: [Row] { lock.lock(); defer { lock.unlock() }; return rows }
    /// window -> "not set" | "<n> <name> <WxH>" | "UNPLUGGED <name>", and the warnings in plain words.
    var outputs: [String: String] { lock.lock(); defer { lock.unlock() }; return _outputs }
    var warnings: [String] { lock.lock(); defer { lock.unlock() }; return _warnings }
    func set(_ new: [Row]) { lock.lock(); rows = new; lock.unlock() }
    func setAssignments(_ outputs: [String: String], warnings: [String]) { lock.lock(); _outputs = outputs; _warnings = warnings; lock.unlock() }
}

/// The NSWindow titles of the scenes, in ONE place: the scene declarations and every title match use these.
/// Deliberately the 1.2 titles, not the operator's names (see `StageWindow.titleMatch`).
enum StageWindowTitle {
    static let stage = "Stage Display"            // shown to the operator as CONFIDENCE MONITOR
    static let keyOverlay = "Confidence Output"   // shown to the operator as KEY OVERLAY
    static let widget = "Operate"
}

/// Scene ids. The operator window is named so it can be opened on demand; the outputs already were.
enum StageWindowID {
    static let control = "control"
    static let stage = "stage-display"
    static let confidence = "confidence-output"
    /// The OPERATE widget (ConsoleMode.swift).
    static let widget = "operate"
}

/// Which of ARC Stage Timer's windows a placement is about.
enum StageWindow: String, CaseIterable, Sendable {
    /// The operator's console: the cue list, the transport, the controls.
    case control
    /// What the room sees.
    case stage
    /// What the presenter sees.
    case confidence
    /// The floating OPERATE widget.
    case widget

    /// How the window announces itself in `NSApplication.shared.windows`: its NSWindow TITLE, which is
    /// NOT the operator's name for it (2026-09-24: the stage output is shown as CONFIDENCE MONITOR and the
    /// confidence output as KEY OVERLAY). The titles stay as they were, because windows are found by them and
    /// "Confidence Monitor" would be caught by a matcher looking for the key layer. See `StageWindowTitle`.
    var titleMatch: String {
        switch self {
        case .control: return ""            // anything that is not one of the others
        case .stage: return StageWindowTitle.stage
        case .confidence: return StageWindowTitle.keyOverlay
        case .widget: return StageWindowTitle.widget
        }
    }

    /// Which output window a title belongs to; nil = not an output (the console, or an untitled helper).
    /// The ONE matcher: `windows(for:)`, the headless sweep and the key layer's close all go through it.
    static func matching(title: String) -> StageWindow? {
        guard !title.isEmpty else { return nil }
        return StageWindow.allCases.first { $0 != .control && title.contains($0.titleMatch) }
    }

    /// A window named in an API call: the internal names (`stage`, `confidence`, `control`, `widget`, kept so
    /// saved scripts work) or the operator's names (`confidence-monitor`/`conf-mon` = stage,
    /// `key-overlay`/`key` = confidence). Exact names only: "confidence" is the KEY OVERLAY, as it always was.
    init?(apiName: String) {
        switch apiName.lowercased() {
        case "stage", "stage-display", "confidence-monitor", "conf-mon", "confmon": self = .stage
        case "confidence", "confidence-output", "key-overlay", "key", "keyoverlay": self = .confidence
        case "control": self = .control
        case "widget", "operate": self = .widget
        default: return nil
        }
    }

    /// A window that fills a display, borderless, when placed.
    var isOutput: Bool { self == .stage || self == .confidence }

    /// The scene id this window is opened with (`StageWindowID`).
    var sceneID: String {
        switch self {
        case .control: return StageWindowID.control
        case .stage: return StageWindowID.stage
        case .confidence: return StageWindowID.confidence
        case .widget: return StageWindowID.widget
        }
    }

    init?(sceneID: String) {
        guard let match = StageWindow.allCases.first(where: { $0.sceneID == sceneID }) else { return nil }
        self = match
    }
}

/// Where each window goes, so the operator can run a show on the second and third displays and leave the
/// primary alone (2026-09-17: "put the control and output on the 2nd and 3rd monitor leaving Ghostty
/// on the primary"). A display is named by UUID, by name, or by 1-based index, and the UUID is what is
/// remembered: a display keeps its UUID across a reboot and a cable swap, its index does not.
///
/// THE PRIMARY IS NEVER TAKEN BY ACCIDENT. A reference has to name it (by its UUID, its name, index 1, or
/// "primary") for a window to land there. `--headless` leaves it with no window at all.
@MainActor
@Observable
final class DisplayPlacement {
    struct Display: Identifiable, Equatable {
        let id: String          // the display's UUID, stable across reboots
        let name: String
        let index: Int          // 1-based, in NSScreen order
        let width: Int
        let height: Int
        let isMain: Bool
    }

    /// Which display each window belongs to, by display IDENTITY (OutputAssignments.swift). Persisted; an
    /// unplugged display keeps its assignment and gets its window back when it returns.
    private(set) var book = OutputAssignmentBook()
    /// window -> the display UUID it belongs to (the 1.2 shape, still read by the console mode and the API).
    var assignments: [StageWindow: String] {
        var out: [StageWindow: String] = [:]
        for w in StageWindow.allCases { if let s = book.stored(w) { out[w] = s.id } }
        return out
    }
    /// The displays connected right now, refreshed on every screen change.
    private(set) var connected: [DisplayInfo] = []
    private(set) var lastError: String?
    @ObservationIgnored fileprivate var appliedLaunchArguments = false
    @ObservationIgnored fileprivate var sweptLate = false
    /// Output windows taken off screen because their display went away, brought back when it returns.
    @ObservationIgnored private var parked: [StageWindow: NSWindow] = [:]

    /// "KEY OVERLAY (ATEM)" (Settings, and the OUTPUTS panel's ADVANCED section). Off: the KEY OVERLAY leaves
    /// every rule and surface, its assignment is kept dormant, and any KEY OVERLAY window is closed.
    var keyOverlayEnabled: Bool = KeyOverlaySetting.isEnabled {
        didSet {
            guard keyOverlayEnabled != oldValue else { return }
            KeyOverlaySetting.isEnabled = keyOverlayEnabled
            UserDefaults.standard.set(keyOverlayEnabled, forKey: KeyOverlaySetting.defaultsKey)
            if !keyOverlayEnabled { closeDormantKeyOverlay(reason: "Key Overlay turned off in Settings") }
            refreshSnapshot()
            StageLog.log("Key Overlay \(keyOverlayEnabled ? "enabled" : "disabled") in Settings")
        }
    }

    /// While the KEY OVERLAY is off, no window of it stays open (the assignment is kept).
    func closeDormantKeyOverlay(reason: String) {
        let open = Self.windows(for: .confidence)
        parked[.confidence] = nil
        guard !open.isEmpty else { return }
        for w in open { w.close() }
        ArcStageTimerApp.sharedConfidenceState.config.isEnabled = false
        StageLog.log("closed \(open.count) KEY OVERLAY window(s): \(reason)")
    }

    init(restoring: Bool = true) {
        connected = Self.infos()
        if restoring { book = OutputAssignmentBook.load(from: .standard, displays: connected) }
        if !KeyOverlaySetting.isEnabled, let s = book.stored(.confidence) {
            StageLog.log("Key Overlay is off in Settings: its assignment (\(s.name)) is kept, dormant")
        }
        refreshSnapshot()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.screensChanged()
            }
        }
    }

    /// A display came or went. An output whose display is gone is taken OFF screen (macOS would otherwise
    /// throw a borderless full-screen stage window onto the console); a display that came back gets its
    /// windows back. Assignments are never dropped here.
    func screensChanged() {
        connected = Self.infos()
        for w in StageWindow.roomOutputs {
            if case .unplugged(let s) = book.state(w, among: connected) {
                for win in Self.windows(for: w) {
                    win.orderOut(nil)
                    parked[w] = win
                    StageLog.log("\(w.rawValue) display \(s.name) unplugged: output parked, assignment kept")
                }
            }
        }
        refreshSnapshot()
        restoreAssignments()
    }

    // MARK: What this Mac has

    /// `NSScreen.main` is the screen with the KEYBOARD FOCUS, not the primary: it moves as windows are
    /// clicked, and using it made "the primary" wander between displays (2026-09-17). The primary is the one
    /// with the menu bar, which AppKit always puts first in `NSScreen.screens`.
    static var displays: [Display] {
        NSScreen.screens.enumerated().map { i, screen in
            Display(id: uuid(of: screen) ?? "index:\(i + 1)", name: screen.localizedName, index: i + 1,
                    width: Int(screen.frame.width), height: Int(screen.frame.height), isMain: i == 0)
        }
    }

    /// The connected displays as `DisplayInfo`, with PIXEL resolution (what a tech reads off a monitor's menu).
    static func infos() -> [DisplayInfo] {
        NSScreen.screens.enumerated().map { i, screen in
            let number = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            let mode = CGDisplayCopyDisplayMode(number)
            let scale = screen.backingScaleFactor
            return DisplayInfo(id: uuid(of: screen) ?? "index:\(i + 1)", name: screen.localizedName, index: i + 1,
                               frame: screen.frame,
                               pixelWidth: mode?.pixelWidth ?? Int(screen.frame.width * scale),
                               pixelHeight: mode?.pixelHeight ?? Int(screen.frame.height * scale),
                               isPrimary: i == 0, isBuiltIn: CGDisplayIsBuiltin(number) != 0)
        }
    }

    static func screen(for display: DisplayInfo) -> NSScreen? {
        NSScreen.screens.first { uuid(of: $0) == display.id }
    }

    static func uuid(of screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let cf = CGDisplayCreateUUIDFromDisplayID(CGDirectDisplayID(number.uint32Value)) else { return nil }
        return CFUUIDCreateString(nil, cf.takeRetainedValue()) as String
    }

    /// A display from what the operator typed: its UUID, its name (or part of one), a 1-based index,
    /// "primary"/"main", or "secondary"/"external" for the first display that is not the primary.
    static func resolve(_ ref: String) -> Display? {
        let all = displays
        let want = ref.trimmingCharacters(in: .whitespaces)
        guard !want.isEmpty else { return nil }
        if let exact = all.first(where: { $0.id.caseInsensitiveCompare(want) == .orderedSame }) { return exact }
        switch want.lowercased() {
        case "primary", "main": return all.first { $0.isMain }
        case "secondary", "external", "next": return all.first { !$0.isMain }
        default: break
        }
        if let n = Int(want) { return all.first { $0.index == n } }
        if let byName = all.first(where: { $0.name.caseInsensitiveCompare(want) == .orderedSame }) { return byName }
        return all.first { $0.name.localizedCaseInsensitiveContains(want) }
    }

    // MARK: Placing

    /// Put `window` on `display`. An OUTPUT fills the display, borderless and above the menu bar; the CONTROL
    /// window keeps its title bar and stays an ordinary window, because someone has to be able to move it.
    @discardableResult
    func place(_ window: StageWindow, on display: Display, fullScreen: Bool? = nil, half: ConsoleHalf? = nil) -> Bool {
        guard let screen = NSScreen.screens.first(where: { Self.uuid(of: $0) == display.id })
            ?? NSScreen.screens.first(where: { $0.localizedName == display.name }) else {
            lastError = "display \(display.name) is not connected"
            return false
        }
        if let win = parked[window], !win.isVisible { win.orderFront(nil); parked[window] = nil }
        guard let target = nsWindow(for: window) else {
            lastError = "the \(window.rawValue) window is not open"
            return false
        }
        // A room output on the console's own display opens as a WINDOW: full screen it would bury the console
        // (and the only screen of a one-display Mac). The OUTPUTS panel warns about it.
        let full = fullScreen ?? (window.isOutput && display.id != controlDisplayID(excluding: window))
        if full {
            target.styleMask = [.borderless]
            target.collectionBehavior = [.fullScreenNone, .canJoinAllSpaces]
            target.level = .init(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
            target.setFrame(screen.frame, display: true)
        } else if window == .control {
            // The console takes HALF the display, left or right (2026-09-17: "one half of the display
            // area when programming"); the other half is for the show's other tools.
            let side = half ?? ConsoleModeController.shared.half
            if let half { ConsoleModeController.shared.half = half }
            let v = screen.visibleFrame
            let f = CGRect(x: side == .left ? v.minX : v.midX, y: v.minY, width: v.width / 2, height: v.height)
            target.setFrame(f, display: true)
        } else if window.isOutput {
            // Windowed output (it shares the console's display): an ordinary window, half the display, at the
            // normal level, so the console stays on top of it when clicked.
            target.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            target.level = .normal
            target.collectionBehavior = [.fullScreenNone]
            let v = screen.visibleFrame
            let w = (v.width * 0.45).rounded(), h = (w * 9 / 16).rounded()
            target.setFrame(CGRect(x: v.maxX - w - 24, y: v.minY + 24, width: w, height: h), display: true)
        } else {
            let f = screen.visibleFrame.insetBy(dx: 24, dy: 24)
            target.setFrame(f, display: true)
        }
        target.orderFront(nil)
        if let info = Self.infos().first(where: { $0.id == display.id }) { book.assign(window, to: info) }
        save()
        refreshSnapshot()
        lastError = nil
        StageLog.log("placed the \(window.rawValue) window on \(display.name) (\(display.width)x\(display.height))")
        // The frame is set again after SwiftUI's own layout pass, which otherwise puts an output back.
        if full {
            let frame = screen.frame
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak target] in
                target?.styleMask = [.borderless]
                target?.level = .init(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
                target?.setFrame(frame, display: true)
            }
        }
        return true
    }

    @discardableResult
    func place(_ window: StageWindow, onRef ref: String, fullScreen: Bool? = nil, half: ConsoleHalf? = nil) -> Bool {
        guard let display = Self.resolve(ref) else {
            lastError = "no display matches \"\(ref)\""
            return false
        }
        return place(window, on: display, fullScreen: fullScreen, half: half)
    }

    /// Put every window back where it was last put, if those displays are still here. Called after the
    /// windows exist, and again when the screens change.
    func restoreAssignments() {
        let now = Self.infos()
        for window in StageWindow.allCases {
            guard let info = book.resolve(window, among: now),
                  let display = Self.displays.first(where: { $0.id == info.id }) else { continue }
            // Only windows that exist (or were parked) move; a closed output is not opened by a replug.
            guard parked[window] != nil || !Self.windows(for: window).isEmpty else { continue }
            place(window, on: display)
        }
    }

    /// The default for a Mac with three displays and a terminal on the primary: control on the second, stage
    /// output on the third, nothing on the first. HEADLESS has no control window, so the stage output takes
    /// the second display and the confidence monitor the third.
    @discardableResult
    func placeOffPrimary() -> String {
        let others = Self.displays.filter { !$0.isMain }
        let primary = Self.displays.first { $0.isMain }?.name ?? "the primary"
        guard !others.isEmpty else { return "only one display: nothing was moved" }
        // Only what actually moved is reported: a window that is not open yet cannot be placed, and saying it
        // was would be a lie the operator acts on.
        var moved: [String] = []
        func put(_ w: StageWindow, _ d: Display) { if place(w, on: d) { moved.append("\(w.rawValue) on \(d.name)") } }
        if StageTimerLaunch.isHeadless {
            put(.stage, others[0])
            if others.count > 1 { put(.confidence, others[1]) }
        } else if others.count == 1 {
            put(.stage, others[0])
        } else {
            put(.control, others[0])
            put(.stage, others[1])
        }
        guard !moved.isEmpty else { return "nothing to move yet: no window is open (they are placed as they open)" }
        return moved.joined(separator: ", ") + ", nothing on \(primary)"
    }

    // MARK: Bits

    /// Every window that answers to `window`, front one first.
    ///
    /// It returns a LIST because there can be more than one: a `WindowGroup` makes a new window on every
    /// `openWindow(id:)` call, and macOS RESTORES every one of them on the next launch (a session that ended
    /// with four stacked "Stage Display" windows opened with four again, 2026-09-17). Untitled windows (the
    /// DeckLink overlay, a stage flash) never match. The operator's window is the one that is NOT an output,
    /// matched that way round because SwiftUI names it after the show, so there is no title to look for.
    ///
    /// ON SCREEN ONLY. `close()` does not take a SwiftUI window out of `NSApplication.shared.windows`, it
    /// keeps its content view, so a closed duplicate would be counted and "closed" again on every pass.
    static func windows(for window: StageWindow) -> [NSWindow] {
        let matching = NSApplication.shared.windows.filter { w in
            guard w.isVisible, w.contentView != nil else { return false }
            if window != .control { return StageWindow.matching(title: w.title) == window }
            return StageWindow.matching(title: w.title) == nil && w.canBecomeKey && !Self.isSettingsWindow(w)
        }
        // Front to back. `orderedWindows` leaves out anything off screen, so those go last rather than
        // disappearing: a window that exists but is not on screen yet is still not a second window to open.
        let order = NSApp.orderedWindows
        return matching.sorted { (order.firstIndex(of: $0) ?? .max) < (order.firstIndex(of: $1) ?? .max) }
    }

    /// The Settings window (Cmd-,) is not the console: it must never be placed, halved or counted as one.
    static func isSettingsWindow(_ w: NSWindow) -> Bool {
        (w.identifier?.rawValue ?? "").localizedCaseInsensitiveContains("settings")
    }

    /// Close every duplicate output window, keeping the front one of each. Called after a placement pass and
    /// after the run screen has opened its routes, because a duplicate that arrives late is still a duplicate.
    static func closeDuplicateOutputs() {
        for window in StageWindow.allCases where window.isOutput {
            let all = windows(for: window)
            guard all.count > 1 else { continue }
            for extra in all.dropFirst() { extra.close() }
            StageLog.log("closed \(all.count - 1) duplicate \(window.rawValue) window(s)")
        }
    }

    private func nsWindow(for window: StageWindow) -> NSWindow? {
        Self.windows(for: window).first
    }

    /// Copy the display list and what sits on each, for readers off the main actor.
    func refreshSnapshot() {
        let now = Self.infos()
        if now != connected { connected = now }
        var outs: [String: String] = [:]
        for w in StageWindow.assignable {
            switch book.state(w, among: now) {
            case .notSet: outs[w.rawValue] = "not set"
            case .onDisplay(let d): outs[w.rawValue] = "\(d.index) \(d.name) \(d.resolution)"
            case .unplugged(let st): outs[w.rawValue] = "UNPLUGGED \(st.name)"
            }
        }
        DisplaySnapshot.shared.setAssignments(outs, warnings: book.warnings(among: now, controlDisplayID: controlDisplayID()).map(\.text))
        DisplaySnapshot.shared.set(Self.displays.map { d in
            .init(index: d.index, name: d.name, uuid: d.id, width: d.width, height: d.height, isMain: d.isMain,
                  windows: assignments.filter { $0.value == d.id }.map(\.key.rawValue).sorted())
        })
    }

    private func save() {
        book.save(to: .standard)
    }

    // MARK: The operator's assignments (header OUTPUTS chips and the OUTPUTS panel)

    /// Where the console is: the display its window is on, else the one it is assigned to, else the primary.
    /// Nil when headless (no console to cover). `excluding` keeps a window from counting as the console.
    func controlDisplayID(excluding: StageWindow? = nil) -> String? {
        guard !StageTimerLaunch.isHeadless else { return nil }
        if excluding != .control, let s = Self.windows(for: .control).first?.screen, let id = Self.uuid(of: s) { return id }
        if let d = book.resolve(.control, among: connected) { return d.id }
        return connected.first(where: \.isPrimary)?.id
    }

    func state(_ window: StageWindow) -> OutputState { book.state(window, among: connected) }
    var warnings: [AssignmentWarning] { book.warnings(among: connected, controlDisplayID: controlDisplayID()) }

    /// Assign `window` to `display` (nil = not set). An output that is on screen moves at once; one that is
    /// not open is only recorded, and opens there next time. Clearing a room output takes it off the air.
    func assign(_ window: StageWindow, to display: DisplayInfo?) {
        guard let display else {
            book.clear(window); save(); refreshSnapshot()
            if window.isOutput { for w in Self.windows(for: window) { w.orderOut(nil) }; parked[window] = nil }
            StageLog.log("\(window.rawValue): not set")
            return
        }
        book.assign(window, to: display)
        save(); refreshSnapshot()
        StageLog.log("\(window.rawValue) assigned to \(display.name) (\(display.resolution))")
        if !Self.windows(for: window).isEmpty, let d = Self.displays.first(where: { $0.id == display.id }) {
            place(window, on: d)
        }
    }

    /// The display a room output should open on: its assignment, or (none yet) the suggestion, which is then
    /// recorded so the chip shows where it went. Nil when unplugged or nowhere sensible.
    func targetForOpening(_ window: StageWindow) -> DisplayInfo? {
        switch state(window) {
        case .onDisplay(let d): return d
        case .unplugged: return nil
        case .notSet:
            guard let d = book.suggestion(for: window, among: connected, controlDisplayID: controlDisplayID()) else { return nil }
            assign(window, to: d)
            return d
        }
    }

    /// Put a just-opened output on its display, retrying while SwiftUI brings the window up.
    func placeWhenOpen(_ window: StageWindow, attempt: Int = 0) {
        guard let target = targetForOpening(window) else {
            StageLog.log("\(window.rawValue) opened with no display to go to: left where it is")
            return
        }
        if !Self.windows(for: window).isEmpty, let d = Self.displays.first(where: { $0.id == target.id }) {
            place(window, on: d)
            Self.closeDuplicateOutputs()
        } else if attempt < 12 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                MainActor.assumeIsolated { self?.placeWhenOpen(window, attempt: attempt + 1) }
            }
        }
    }

    /// Is this output on the air: its window up, on the display it belongs to.
    func isLive(_ window: StageWindow) -> Bool {
        guard let win = Self.windows(for: window).first else { return false }
        guard let d = state(window).display else { return false }
        return win.screen.flatMap(Self.uuid(of:)) == d.id
    }

    /// Is the output's window open at all (anywhere).
    func isOpen(_ window: StageWindow) -> Bool { !Self.windows(for: window).isEmpty }

    // MARK: GO LIVE

    /// A display besides the console's exists: something GO LIVE may use.
    var hasOutputDisplay: Bool { let c = controlDisplayID(); return connected.contains { $0.id != c } }
    /// The room outputs up on their own displays right now.
    var liveOutputs: Set<StageWindow> { Set(StageWindow.roomOutputs.filter { isLive($0) }) }
    var goLiveButton: GoLiveButtonState {
        let live = liveOutputs
        return OutputAssignmentBook.goLiveButton(
            live: live, expected: book.goLiveExpected(among: connected, controlDisplayID: controlDisplayID(), live: live),
            hasOutputDisplay: hasOutputDisplay)
    }

    /// STAGE and CONFIDENCE up on their displays in one move (CONTROL is never touched). An output with no
    /// assignment gets the fallback, which is RECORDED so its chip shows where it went. `open` asks SwiftUI
    /// for the window (only a view can); placement follows as each window appears.
    @discardableResult
    func goLive(open: @escaping (StageWindow) -> Void) -> GoLivePlan {
        let plan = book.goLivePlan(among: connected, controlDisplayID: controlDisplayID(), alreadyLive: liveOutputs)
        for w in plan.takeOff { close(w); StageLog.log("GO LIVE: \(w.outputLabel) taken off, it shares the CONFIDENCE MONITOR's display") }
        for w in plan.fallback { if let d = plan.targets[w] { book.assign(w, to: d) } }
        if !plan.fallback.isEmpty { save(); refreshSnapshot() }
        for (i, w) in StageWindow.roomOutputs.filter({ plan.targets[$0] != nil }).enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.4) { [weak self] in
                MainActor.assumeIsolated {
                    open(w)
                    self?.placeWhenOpen(w)
                }
            }
        }
        let went = plan.targets.map { "\($0.key.outputLabel) on \($0.value.name)" + (plan.fallback.contains($0.key) ? " (fallback)" : "") }
        let held = plan.skipped.map { "\($0.key.outputLabel) held: \($0.value.text)" }
        StageLog.log("GO LIVE: " + ((went + held).isEmpty ? "already live" : (went + held).sorted().joined(separator: ", ")))
        return plan
    }

    /// Both room outputs off the air (the same as TAKE ALL OFF). Assignments are kept.
    func takeOffAir() {
        for w in StageWindow.roomOutputs { close(w) }
        NSApp.presentationOptions = []
        StageLog.log("OFF AIR: confidence monitor and key overlay closed")
    }

    /// Take a room output off the air.
    func close(_ window: StageWindow) {
        for w in Self.windows(for: window) { w.close() }
        parked[window] = nil
    }

    var json: String {
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        let rows = Self.displays.map { d in
            let on = assignments.filter { $0.value == d.id }.map(\.key.rawValue).sorted()
            return "{\"index\":\(d.index),\"name\":\"\(esc(d.name))\",\"uuid\":\"\(d.id)\",\"width\":\(d.width),\"height\":\(d.height),\"main\":\(d.isMain),\"windows\":[\(on.map { "\"\($0)\"" }.joined(separator: ","))]}"
        }
        let err = lastError.map { "\"\(esc($0))\"" } ?? "null"
        return "{\"displays\":[\(rows.joined(separator: ","))],\"headless\":\(StageTimerLaunch.isHeadless),\"lastError\":\(err)}"
    }
}

/// What the app was asked for on the command line.
enum StageTimerLaunch {
    /// `--headless`: no operator window on the primary, the HTTP API is the console. The outputs still open.
    static var isHeadless: Bool { CommandLine.arguments.contains("--headless") }

    /// `--control-display <ref>`, `--stage-display <ref>`, `--confidence-display <ref>`.
    static func display(for window: StageWindow) -> String? {
        value(after: "--\(window.rawValue)-display")
    }

    /// `--off-primary`: control on the second display, stage output on the third, nothing on the primary.
    static var wantsOffPrimary: Bool { CommandLine.arguments.contains("--off-primary") }

    /// `--test-show [name]` and `--cues N`: build a test show and open it on the run screen, so the app can be
    /// driven and looked at with nobody at the keyboard.
    static var wantsTestShow: Bool { CommandLine.arguments.contains("--test-show") }
    /// `--extended`: open the control-panel layout (stage display connected), not the standalone one.
    static var wantsExtended: Bool { CommandLine.arguments.contains("--extended") }
    static var testShowName: String { value(after: "--test-show") ?? "ARC Style Review" }
    static var testShowCues: Int { Int(value(after: "--cues") ?? "") ?? 3 }

    static func value(after flag: String) -> String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: flag), i + 1 < args.count, !args[i + 1].hasPrefix("--") else { return nil }
        return args[i + 1]
    }
}
#endif

#if os(macOS)
import SwiftUI

extension DisplayPlacement {
    /// Opening an output window is IDEMPOTENT.
    ///
    /// `openWindow(id:)` on a `WindowGroup` creates a NEW window on every single call, and six code paths
    /// call it for the same two outputs: the run screen's `onAppear`, the SEND chip, the routing sheet's
    /// APPLY, the confidence toggle, a restored route, and `POST /api/window/open`. Two and three "Stage
    /// Display" windows piled up on the stage display, nothing closed them, and every screenshot after that
    /// photographed whichever one happened to be in front (2026-09-17). So an output that is already open is
    /// brought forward, any duplicate behind it is closed, and a window is only created when there is none.
    ///
    /// `openWindow` is asynchronous: the window does not exist the instant it returns. A second caller a
    /// fraction of a second later would therefore still find nothing and open a second window, so an open
    /// stays PENDING for a few seconds and is not asked for twice.
    ///
    /// Returns whether a new window was asked for.
    @discardableResult
    static func openOutput(_ sceneID: String, using openWindow: OpenWindowAction) -> Bool {
        guard let window = StageWindow(sceneID: sceneID) else {
            openWindow(id: sceneID)
            return true
        }
        // The console may be in the Dock (OPERATE minimizes it): that is open, not missing.
        if window == .control, let parked = NSApplication.shared.windows.first(where: { $0.isMiniaturized && $0.contentView != nil && $0.canBecomeKey }) {
            parked.deminiaturize(nil)
            parked.makeKeyAndOrderFront(nil)
            return false
        }
        let existing = windows(for: window)
        if let front = existing.first {
            pendingOpens[sceneID] = nil
            if existing.count > 1 {
                for extra in existing.dropFirst() { extra.close() }
                StageLog.log("closed \(existing.count - 1) duplicate \(window.rawValue) window(s)")
            }
            front.orderFront(nil)
            return false
        }
        if let asked = pendingOpens[sceneID], Date().timeIntervalSince(asked) < openGrace {
            StageLog.log("the \(window.rawValue) window is already opening; not opening a second one")
            return false
        }
        pendingOpens[sceneID] = Date()
        openWindow(id: sceneID)
        StageLog.log("opening the \(window.rawValue) output window")
        return true
    }

    /// Opens asked for but not yet on screen, by scene id.
    private static var pendingOpens: [String: Date] = [:]
    /// How long an open stays pending. SwiftUI takes a beat; a window that has not appeared by then is gone.
    private static let openGrace: TimeInterval = 4

    /// What the command line asked for, once the windows exist. `--off-primary` first, then any explicit
    /// `--<window>-display`, so a single flag can override the shorthand.
    func applyLaunchArguments() {
        guard !appliedLaunchArguments else { return }
        appliedLaunchArguments = true
        // The windows are not on screen the instant the first view appears.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [self] in placeAll() }
    }

    /// The whole placement pass: `--off-primary` or the remembered assignments, then any explicit flag, then
    /// the duplicate sweep. Run at launch, and again when a console had to be opened late (a run killed in
    /// OPERATE left none to restore, and the one opened in its place landed on the stage's display, 2026-09-17).
    func placeAll() {
        if StageTimerLaunch.wantsOffPrimary {
            StageLog.log(placeOffPrimary())
        } else {
            restoreAssignments()
        }
        for window in StageWindow.allCases {
            guard let ref = StageTimerLaunch.display(for: window) else { continue }
            if !place(window, onRef: ref) { StageLog.log("could not place \(window.rawValue): \(lastError ?? "unknown")") }
        }
        sweepRestoredOutputs()
        Self.closeDuplicateOutputs()
        if StageTimerLaunch.isHeadless { StageAppDelegate.hideControlWindow() }
        // macOS can restore an output window after this pass has run: look again once, a few seconds on.
        if !sweptLate {
            sweptLate = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                MainActor.assumeIsolated { self?.sweepRestoredOutputs() }
            }
        }
    }

    /// Output windows that exist at launch (restored by macOS) follow their assignment: none -> closed; a
    /// connected display -> placed live on it (restoreAssignments / the flags have done that); an unplugged
    /// one -> parked until it returns. Logged.
    func sweepRestoredOutputs() {
        if !KeyOverlaySetting.isEnabled { closeDormantKeyOverlay(reason: "Key Overlay is off in Settings") }
        let now = Self.infos()
        for w in StageWindow.roomOutputs {
            let open = Self.windows(for: w)
            guard !open.isEmpty else { continue }
            switch book.restoredWindowAction(w, among: now) {
            case .close:
                for win in open { win.close() }
                parked[w] = nil
                StageLog.log("closed \(open.count) restored \(w.outputLabel) window(s): no display assigned")
            case .park(let s):
                for win in open { win.orderOut(nil) }
                parked[w] = open.first
                StageLog.log("parked the restored \(w.outputLabel) window: its display \(s.name) is unplugged")
            case .place(let d):
                // Normally already placed; a window that came back late is put on its display here.
                if !isLive(w), let disp = Self.displays.first(where: { $0.id == d.id }) { place(w, on: disp) }
            }
        }
    }
}

/// Headless: no operator window and no Dock icon, the HTTP API on :8080 is the console, and the primary
/// display is left to whatever is already on it. The outputs still open and can still be placed.
final class StageAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Placement is driven from HERE, not from a view's onAppear: a headless run has no view to appear
        // (2026-09-17, the first headless run only placed anything because a window flashed up first).
        MainActor.assumeIsolated {
            ArcStageTimerApp.sharedPlacement.applyLaunchArguments()
            if StageTimerLaunch.wantsTestShow {
                var request = Automation.defaultTestShow(name: StageTimerLaunch.testShowName, cues: StageTimerLaunch.testShowCues)
                request.open = true
                Automation.shared.ask(.testShow(request))
            }
            // `--console operate`: the widget, once the windows and the show exist.
            if ConsoleModeController.shared.mode == .operate && !StageTimerLaunch.isHeadless {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    MainActor.assumeIsolated { ConsoleModeController.shared.apply() }
                }
            }
        }
        // With a GUI there is ALWAYS an operator window. SwiftUI restores whatever the last run left open, and
        // after a headless run that is nothing at all: the app came up with no window to click (2026-09-17).
        if !StageTimerLaunch.isHeadless {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                MainActor.assumeIsolated {
                    // A launch is PROGRAM: a widget macOS brought back from the last run is closed.
                    if ConsoleModeController.shared.mode == .program {
                        for w in DisplayPlacement.windows(for: .widget) { w.close() }
                    }
                    Self.ensureControlWindow()
                }
            }
        }
        // Review hooks (screenshots at fixed sizes, with nobody at the keyboard): `--console-size 1512x900`
        // sizes the console window; `--outputs-panel` opens the OUTPUTS panel.
        if let size = StageTimerLaunch.value(after: "--console-size")?.split(separator: "x").compactMap({ Double($0) }), size.count == 2 {
            for delay in [2.0, 5.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    MainActor.assumeIsolated {
                        guard let w = DisplayPlacement.windows(for: .control).first, let v = w.screen?.visibleFrame else { return }
                        w.setFrame(CGRect(x: v.minX + 20, y: v.maxY - size[1] - 10, width: size[0], height: size[1]), display: true)
                    }
                }
            }
        }
        if CommandLine.arguments.contains("--outputs-panel") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { MainActor.assumeIsolated { OutputsPanelController.shared.isOpen = true } }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            let rows = NSApplication.shared.windows.map { w in
                "\"\(w.title)\" \(Int(w.frame.width))x\(Int(w.frame.height)) visible=\(w.isVisible) key=\(w.canBecomeKey) content=\(w.contentView != nil) id=\(w.identifier?.rawValue ?? "-")"
            }
            StageLog.log("windows: \(rows.isEmpty ? "none" : rows.joined(separator: " | "))")
        }
        guard StageTimerLaunch.isHeadless else { return }
        NSApp.setActivationPolicy(.accessory)
        StageLog.log("headless: no operator window, control it over http://localhost:8080/api/")
        for delay in [0.4, 1.2, 2.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { Self.hideControlWindow() }
        }
    }

    /// Open the operator window if this run has none. Only a view can call `openWindow`, so EVERY window's
    /// root view listens for this (console, stage output, widget), each through `openOutput`, which lets one
    /// of them win. With no window at all SwiftUI opens the first WindowGroup itself, which is the console.
    /// (`newWindowForTab:` is NOT a fallback: it targets the key window's group and opened a second stage
    /// display, 2026-09-17.)
    @MainActor
    static func ensureControlWindow() {
        func hasControl() -> Bool {
            NSApplication.shared.windows.contains { w in
                w.contentView != nil && StageWindow.matching(title: w.title) == nil && w.canBecomeKey && !DisplayPlacement.isSettingsWindow(w)
            }
        }
        guard !hasControl() else { return }
        StageLog.log("no operator window: opening one")
        NSApp.activate(ignoringOtherApps: false)
        NotificationCenter.default.post(name: .openControlWindow, object: nil)
        // A console opened this late missed the placement pass: put it where it belongs.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            MainActor.assumeIsolated { ArcStageTimerApp.sharedPlacement.placeAll() }
        }
    }

    /// SwiftUI opens a WindowGroup window whatever we do; in headless it is closed as soon as it appears.
    @MainActor
    static func hideControlWindow() {
        for w in NSApplication.shared.windows where w.contentView != nil {
            guard StageWindow.matching(title: w.title) == nil else { continue }
            w.close()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !StageTimerLaunch.isHeadless      // headless has no windows by design and must not quit
    }

    /// Quitting in OPERATE would leave the console ordered out, and an ordered-out window is not restored:
    /// the next launch had a widget and no console (2026-09-17). Back to PROGRAM first.
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            if ConsoleModeController.shared.mode == .operate { ConsoleModeController.shared.set(.program) }
        }
    }
}
#endif

#if os(macOS)
extension Notification.Name {
    /// GO LIVE / OFF AIR from the menu shortcut or the API. userInfo["on"]: Bool, absent = toggle. The console's
    /// root view carries it out, because only a view can open a window.
    static let goLive = Notification.Name("ARCStageTimerGoLive")
    /// Asks the scene layer to open the operator window (the delegate cannot call `openWindow` itself).
    static let openControlWindow = Notification.Name("ARCStageTimerOpenControlWindow")
}
#endif

import SwiftUI

extension OpenWindowAction {
    /// Open one of the timer's OUTPUT windows. EVERY call site goes through here rather than calling
    /// `openWindow(id:)` itself, because opening an output twice left two windows stacked on the stage
    /// display (see `DisplayPlacement.openOutput`, which is where the macOS rule lives).
    @MainActor
    func output(_ sceneID: String) {
        #if os(macOS)
        DisplayPlacement.openOutput(sceneID, using: self)
        #else
        self(id: sceneID)
        #endif
    }
}

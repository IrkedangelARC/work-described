//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI
import AppKit

@MainActor
@Observable
final class DisplayManager {
    var statusMessage: String?

    // Screen inventory
    private(set) var availableScreens: [ScreenIdentity] = []

    /// The outputs that live on a display. `.operatorView` is deliberately NOT one: it has no screen
    /// assignment and is always "connected", so it must never fall into a lookup whose nil reads as
    /// "not connected". Everything per-output is keyed by this, which is what makes another output
    /// kind a case in an enum rather than four more stored properties and a new arm in every switch.
    static let displayOutputs: [OutputType] = [.program, .confidence]

    // Per-output state, keyed. The named properties below are the same API as before, over this.
    private var screenIDs: [OutputType: CGDirectDisplayID] = [:]
    private var connectedOutputs: Set<OutputType> = []

    var programScreenID: CGDirectDisplayID? {
        get { screenIDs[.program] }
        set { screenIDs[.program] = newValue }
    }
    var confidenceScreenID: CGDirectDisplayID? {
        get { screenIDs[.confidence] }
        set { screenIDs[.confidence] = newValue }
    }
    var isProgramConnected: Bool { connectedOutputs.contains(.program) }
    var isConfidenceConnected: Bool { connectedOutputs.contains(.confidence) }

    // Pointer lock (Spotlight remote -> output screen)
    var isPointerLocked = false
    private var pointerTap: CFMachPort?
    private var pointerRunLoopSource: CFRunLoopSource?

    // Reconnection state, across a sleep.
    private var wasConnectedBeforeSleep: Set<OutputType> = []
    private var idsBeforeSleep: [OutputType: CGDirectDisplayID] = [:]

    private var escapeMonitor: Any?
    private var flashWindows: [NSWindow] = []

    // MARK: - Computed

    var hasExternalScreen: Bool {
        availableScreens.contains { !$0.isBuiltIn }
    }

    var externalScreens: [ScreenIdentity] {
        availableScreens.filter { !$0.isBuiltIn }
    }

    var hasActiveOutput: Bool {
        !connectedOutputs.isEmpty
    }

    var programScreen: ScreenIdentity? { screenFor(.program) }

    var confidenceScreen: ScreenIdentity? { screenFor(.confidence) }

    /// Largest assigned screen size, used for page cache rendering target
    var externalScreenSize: CGSize? {
        let sizes = [programScreen?.frame.size, confidenceScreen?.frame.size].compactMap { $0 }
        return sizes.max { ($0.width * $0.height) < ($1.width * $1.height) }
            ?? externalScreens.first?.frame.size
    }

    /// CGRect of the program output screen in global display coordinates
    var programScreenFrame: CGRect? {
        guard let id = programScreenID else { return nil }
        return availableScreens.first { $0.id == id }?.frame
    }

    func screenFor(_ output: OutputType) -> ScreenIdentity? {
        guard let id = screenIDs[output] else { return nil }
        return availableScreens.first { $0.id == id }
    }

    /// `.operatorView` is always connected: it is the app's own window, not a display output. That is an
    /// asymmetry, not an oversight, and it is stated here rather than left to a missing dictionary entry.
    func isConnected(_ output: OutputType) -> Bool {
        output == .operatorView ? true : connectedOutputs.contains(output)
    }

    // MARK: - Init

    init() {
        detectScreens()
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensDidChange),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(systemWillSleep),
            name: NSWorkspace.willSleepNotification, object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification, object: nil
        )
    }

    nonisolated deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    // MARK: - Screen Detection

    func detectScreens() {
        availableScreens = NSScreen.screens.enumerated().compactMap { index, screen in
            ScreenIdentity.from(screen, index: index)
        }
    }

    // MARK: - Assignment

    func assign(screen: ScreenIdentity, to output: OutputType) {
        guard Self.displayOutputs.contains(output) else { return }
        // One display cannot carry two outputs, so take it off whoever else holds it. A loop rather than
        // an `if` per pair: with two outputs that was one line, with three it would have been two per
        // output and the kind of thing that is right in review and wrong on the day.
        for other in Self.displayOutputs where other != output && screenIDs[other] == screen.id {
            screenIDs[other] = nil
        }
        screenIDs[output] = screen.id
    }

    func unassign(_ output: OutputType) {
        guard Self.displayOutputs.contains(output) else { return }
        if isConnected(output) { closeOutput(output) }
        screenIDs[output] = nil
    }

    /// Screen by UUID, name, or 1-based index (control API routing).
    func screen(matching key: String) -> ScreenIdentity? {
        availableScreens.first { $0.matches(key) }
    }

    /// Machine-readable inventory for the control API.
    var displaysJSON: String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        }
        let rows = availableScreens.map { s in
            "{\"index\":\(s.index + 1),\"name\":\"\(esc(s.localizedName))\",\"uuid\":\"\(s.uuid)\",\"resolution\":\"\(s.resolution)\",\"builtIn\":\(s.isBuiltIn),\"program\":\(s.id == programScreenID),\"confidence\":\(s.id == confidenceScreenID)}"
        }
        return "{\"displays\":[\(rows.joined(separator: ","))],\"programOpen\":\(isProgramConnected),\"confidenceOpen\":\(isConfidenceConnected)}"
    }

    /// Auto-assign externals: first external -> program, second -> confidence
    func autoAssign() {
        let externals = externalScreens
        if externals.count >= 1 {
            programScreenID = externals[0].id
        }
        if externals.count >= 2 {
            confidenceScreenID = externals[1].id
        }
    }

    // MARK: - Output Control

    @discardableResult
    /// Open the output on its assigned display. The SwiftUI window scene may
    /// not exist yet (a cold launch restoring outputs, or the first GO LIVE):
    /// ask the scene to open, then place the window as soon as it appears.
    /// `isProgramConnected` / `isConfidenceConnected` turn true ONLY once the
    /// window is actually on its display. Before 2026-09-16 the flag was set
    /// after a fixed 0.3 s whether or not a window existed, and a restore at
    /// launch reported PGM open while the window sat on the operator's screen
    /// at normal level (drill D1).
    func openOutput(_ output: OutputType) -> Bool {
        guard let target = resolveTarget(for: output) else { return false }
        Task { @MainActor [weak self] in await self?.openAndPlace(output, on: target) }
        return true
    }

    private func windowExists(_ output: OutputType) -> Bool {
        NSApplication.shared.windows.contains { $0.title == output.windowTitle }
    }

    private func openAndPlace(_ output: OutputType, on target: ScreenIdentity) async {
        for attempt in 0..<25 {                       // up to 5 s
            if attempt % 5 == 0, !windowExists(output) {
                NotificationCenter.default.post(name: .openOutputWindow, object: nil, userInfo: ["output": output.rawValue])
            }
            try? await Task.sleep(for: .milliseconds(200))
            if moveWindow(titled: output.windowTitle, to: target) {
                ShowLog.log("\(output.shortLabel) open on \(target.localizedName) \(target.resolution)")
                if output == .program {
                    SlideTrackRecorder.writer?.updateHeader { $0.display = target.localizedName }
                    SlideTrackRecorder.record(.output) { $0.note = "PROGRAM open on \(target.localizedName) \(target.resolution)" }
                }
                setConnected(true, for: output)
                installEscapeMonitor()
                refocusOperatorWindow()
                if isPointerLocked { updatePointerLockFrames() }
                NotificationCenter.default.post(name: .operatorWindowRefit, object: nil)
                return
            }
        }
        statusMessage = "\(output.shortLabel) window did not open"
        ShowLog.error("openOutput \(output.shortLabel): the window never appeared")
    }

    /// True once the output's window is on its display (bounded wait).
    func waitForOutput(_ output: OutputType, seconds: Double = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if isConnected(output) { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    func closeOutput(_ output: OutputType) {
        if Self.displayOutputs.contains(output), isConnected(output) {
            ShowLog.log("\(output.shortLabel) closed")
            if output == .program { SlideTrackRecorder.record(.output) { $0.note = "PROGRAM closed" } }
        }
        let title = output.windowTitle
        for window in NSApplication.shared.windows where window.title == title {
            window.level = .normal
            window.orderOut(nil)
        }
        setConnected(false, for: output)
        NotificationCenter.default.post(name: .operatorWindowRefit, object: nil)

        if !hasActiveOutput {
            NSApp.presentationOptions = []
            removeEscapeMonitor()
            if isPointerLocked {
                isPointerLocked = false
                stopPointerTap()
            }
        }
    }

    func closeAllOutputs() {
        for output in Self.displayOutputs { closeOutput(output) }
    }

    func openAllAssigned() {
        for output in Self.displayOutputs where screenIDs[output] != nil { openOutput(output) }
    }

    // MARK: - Screen Flash Identification

    func flashAllScreens() {
        dismissFlash()
        for screen in availableScreens {
            flashSingleScreen(screen)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.dismissFlash()
        }
    }

    func flashScreen(_ screen: ScreenIdentity) {
        dismissFlash()
        flashSingleScreen(screen)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.dismissFlash()
        }
    }

    private func flashSingleScreen(_ screen: ScreenIdentity) {
        let nsScreen = NSScreen.screens.first { nsScreen in
            guard let displayID = nsScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
                return false
            }
            return displayID == screen.id
        }
        guard let nsScreen else { return }

        var label = "OUTPUT \(screen.index + 1)\n\(screen.localizedName)\n\(screen.resolution)"
        if programScreenID == screen.id { label += "\n[PROGRAM]" }
        if confidenceScreenID == screen.id { label += "\n[CONFIDENCE]" }

        let window = NSWindow(
            contentRect: nsScreen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces]
        window.backgroundColor = NSColor.black.withAlphaComponent(0.85)
        window.isOpaque = false
        window.setFrame(nsScreen.frame, display: true)

        let textField = NSTextField(labelWithString: label)
        textField.font = NSFont.monospacedSystemFont(ofSize: 64, weight: .bold)
        textField.textColor = .white
        textField.alignment = .center
        textField.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: nsScreen.frame)
        container.addSubview(textField)
        NSLayoutConstraint.activate([
            textField.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            textField.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        window.contentView = container
        window.orderFrontRegardless()
        flashWindows.append(window)
    }

    func dismissFlash() {
        for window in flashWindows {
            window.orderOut(nil)
        }
        flashWindows.removeAll()
    }

    // MARK: - Private Helpers

    private func resolveTarget(for output: OutputType) -> ScreenIdentity? {
        switch output {
        case .program:
            if let id = programScreenID { return availableScreens.first { $0.id == id } }
            return externalScreens.first
        case .confidence:
            if let id = confidenceScreenID { return availableScreens.first { $0.id == id } }
            let externals = externalScreens
            if externals.count >= 2 { return externals[1] }
            if programScreenID == nil, let first = externals.first { return first }
            return nil
        case .operatorView:
            return nil
        }
    }

    private func configureOutputWindow(_ window: NSWindow, on screen: NSScreen) {
        window.styleMask = [.borderless]
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = false
        window.level = NSWindow.Level(Int(CGShieldingWindowLevel()))
        window.collectionBehavior = [.stationary, .canJoinAllSpaces, .ignoresCycle]
        window.setFrame(screen.frame, display: true)
        window.orderFrontRegardless()
    }

    /// True when a window with that title existed and was placed.
    @discardableResult
    private func moveWindow(titled title: String, to target: ScreenIdentity) -> Bool {
        let nsScreen = NSScreen.screens.first { nsScreen in
            guard let displayID = nsScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
                return false
            }
            return displayID == target.id
        }
        guard let nsScreen else { return false }

        for window in NSApplication.shared.windows where window.title == title {
            configureOutputWindow(window, on: nsScreen)
            var options: NSApplication.PresentationOptions = [.autoHideMenuBar, .autoHideDock]
            // macOS 27: keep a stray mouse from firing a Hot Corner mid-show.
            // Only honoured while Presenter is frontmost and the Dock is auto-hidden.
            if #available(macOS 27, *) { options.insert(.disableScreenCornerInteractions) }
            NSApp.presentationOptions = options
            return true
        }
        return false
    }

    private func setConnected(_ connected: Bool, for output: OutputType) {
        guard Self.displayOutputs.contains(output) else { return }
        if connected { connectedOutputs.insert(output) } else { connectedOutputs.remove(output) }
    }

    private func refocusOperatorWindow() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            for window in NSApplication.shared.windows {
                let title = window.title
                if window.isVisible
                    && title != OutputType.program.windowTitle
                    && title != OutputType.confidence.windowTitle
                    && window.contentView != nil
                {
                    window.makeKeyAndOrderFront(nil)
                    break
                }
            }
        }
    }

    // MARK: - Escape Monitor

    private func installEscapeMonitor() {
        removeEscapeMonitor()
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            // Cmd-Esc closes the outputs. Plain Esc used to close every output,
            // SDI included, from any first responder (a text field's Esc could
            // black the room; stability audit 2026-09-16). It now passes through.
            if event.modifierFlags.contains(.command) {
                self?.closeAllOutputs()
                return nil
            }
            self?.statusMessage = "⌘ Esc closes the outputs"
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                if self?.statusMessage == "⌘ Esc closes the outputs" { self?.statusMessage = nil }
            }
            return event
        }
    }

    private func removeEscapeMonitor() {
        if let monitor = escapeMonitor {
            NSEvent.removeMonitor(monitor)
            escapeMonitor = nil
        }
    }

    // MARK: - Pointer Lock (Spotlight Remote)

    /// The operator hit PTR and lost the mouse (2026-09-16): the lock's only
    /// release was a shortcut nobody had told him. Now: the status line names
    /// the releases while locked, Esc three times releases from any focus,
    /// and `POST /pointer?on=0` releases from a terminal.
    static let pointerLockHint = "Pointer locked to PROGRAM. ⌘⇧P or Esc Esc Esc releases it"

    func setPointerLock(_ on: Bool) {
        guard on != isPointerLocked else { return }
        togglePointerLock()
    }

    func togglePointerLock() {
        guard isProgramConnected else { return }
        isPointerLocked.toggle()
        ShowLog.log(isPointerLocked ? "pointer LOCKED to PROGRAM" : "pointer released")
        if isPointerLocked {
            statusMessage = Self.pointerLockHint
            startPointerTap()
        } else {
            if statusMessage == Self.pointerLockHint { statusMessage = nil }
            stopPointerTap()
            // Disconnect mouse deltas so Logi software can't bounce the cursor back
            CGAssociateMouseAndMouseCursorPosition(0)
            let controlScreen = NSScreen.screens.first { screen in
                guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
                    return false
                }
                return displayID != programScreenID
            }
            if let frame = controlScreen?.frame {
                CGWarpMouseCursorPosition(CGPoint(x: frame.midX, y: frame.midY))
            }
            // Reconnect after Logi software settles
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                CGAssociateMouseAndMouseCursorPosition(1)
            }
        }
    }

    private func startPointerTap() {
        let eventMask: CGEventMask =
            (1 << CGEventType.mouseMoved.rawValue)
            | (1 << CGEventType.leftMouseDragged.rawValue)
            | (1 << CGEventType.otherMouseDragged.rawValue)

        // Static storage for the output frame so the C callback can access it
        PointerLockState.shared.isActive = true

        let callback: CGEventTapCallBack = { _, type, event, _ in
            guard PointerLockState.shared.isActive,
                  let outputFrame = PointerLockState.shared.outputFrame else {
                return Unmanaged.passUnretained(event)
            }

            let pos = event.location
            // Only remap if cursor is NOT already on the output screen
            if outputFrame.contains(pos) {
                return Unmanaged.passUnretained(event)
            }

            // Get the control screen (where cursor currently is)
            guard let controlFrame = PointerLockState.shared.controlFrame else {
                return Unmanaged.passUnretained(event)
            }

            // Map proportional position from control screen to output screen
            let relX = (pos.x - controlFrame.minX) / controlFrame.width
            let relY = (pos.y - controlFrame.minY) / controlFrame.height

            let newX = outputFrame.minX + relX * outputFrame.width
            let newY = outputFrame.minY + relY * outputFrame.height

            CGWarpMouseCursorPosition(CGPoint(x: newX, y: newY))
            CGAssociateMouseAndMouseCursorPosition(1)

            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: callback,
            userInfo: nil
        ) else {
            NSLog("ARC Presenter: Failed to create pointer tap. Accessibility access required.")
            isPointerLocked = false
            return
        }

        pointerTap = tap
        pointerRunLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), pointerRunLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        // Warp cursor to center of output screen immediately
        updatePointerLockFrames()
        if let frame = programScreenFrame {
            CGWarpMouseCursorPosition(CGPoint(x: frame.midX, y: frame.midY))
        }
    }

    private func stopPointerTap() {
        PointerLockState.shared.isActive = false
        if let tap = pointerTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = pointerRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        pointerTap = nil
        pointerRunLoopSource = nil
    }

    /// Update the frames used by the pointer lock CGEvent callback
    func updatePointerLockFrames() {
        PointerLockState.shared.outputFrame = programScreenFrame
        // Control screen: the screen that is NOT the program output
        let controlScreen = NSScreen.screens.first { screen in
            guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
                return false
            }
            return displayID != programScreenID
        }
        PointerLockState.shared.controlFrame = controlScreen?.frame
    }

    // MARK: - Sleep / Wake

    @objc private func systemWillSleep(_ note: Notification) {
        wasConnectedBeforeSleep = connectedOutputs
        idsBeforeSleep = screenIDs

        if isPointerLocked {
            isPointerLocked = false
            stopPointerTap()
        }

        statusMessage = "System sleeping, outputs paused"
    }

    @objc private func systemDidWake(_ note: Notification) {
        // Delay screen re-detection: macOS needs time to re-initialize displays
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self else { return }
            self.detectScreens()

            // Attempt to restore outputs
            for output in Self.displayOutputs where self.wasConnectedBeforeSleep.contains(output) {
                guard let prevID = self.idsBeforeSleep[output],
                      self.availableScreens.contains(where: { $0.id == prevID }) else { continue }
                self.screenIDs[output] = prevID
                self.openOutput(output)
            }

            if !self.wasConnectedBeforeSleep.isEmpty {
                self.statusMessage = "System woke, restoring outputs"
            } else {
                self.statusMessage = nil
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                self?.statusMessage = nil
            }
        }
    }

    // MARK: - Screen Changes

    /// Outputs whose display vanished and should come back when it does.
    /// Separate from the sleep fields: `didChangeScreenParameters` fires twice
    /// on a wake (displays gone, displays back) and sharing the fields let the
    /// second pass erase what the first had recorded (audit 2026-09-16, R5).
    private var pendingIDs: [OutputType: CGDirectDisplayID] = [:]

    /// The operator-facing name in the display-lost and display-back lines. Kept as its own mapping so the
    /// existing wording ("PROGRAM", "MON") does not change, and a later output kind falls back sensibly.
    private static func lostLabel(_ output: OutputType) -> String {
        switch output {
        case .program: "PROGRAM"
        case .confidence: "MON"
        default: output.shortLabel
        }
    }

    @objc private func screensDidChange(_ note: Notification) {
        detectScreens()

        var lost: [String] = []
        for output in Self.displayOutputs {
            guard let id = screenIDs[output], !availableScreens.contains(where: { $0.id == id }) else { continue }
            if isConnected(output) { pendingIDs[output] = id; lost.append(Self.lostLabel(output)) }
            screenIDs[output] = nil
            setConnected(false, for: output)
            hideOutputWindow(output)
        }
        if !lost.isEmpty {
            ShowLog.log("display lost for \(lost.joined(separator: ", ")); will restore when it returns")
            statusMessage = "\(lost.joined(separator: " and ")) display disconnected"
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                if self?.statusMessage?.hasSuffix("display disconnected") == true { self?.statusMessage = nil }
            }
        }

        var restored: [OutputType] = []
        for output in Self.displayOutputs {
            guard let id = pendingIDs[output], availableScreens.contains(where: { $0.id == id }) else { continue }
            screenIDs[output] = id
            pendingIDs[output] = nil
            restored.append(output)
        }
        guard !restored.isEmpty else { return }
        statusMessage = "Displays reconnected, restoring outputs"
        ShowLog.log("display back, restoring \(restored.map { Self.lostLabel($0) }.joined(separator: ", "))")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            for output in restored { self?.openOutput(output) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            self?.statusMessage = nil
        }
    }

    /// A shield whose display vanished gets relocated by AppKit onto a
    /// remaining screen, black over the operator's monitor at the shielding
    /// level. Order it out until its display is back.
    private func hideOutputWindow(_ output: OutputType) {
        for window in NSApplication.shared.windows where window.title == output.windowTitle {
            window.level = .normal
            window.orderOut(nil)
        }
        if !hasActiveOutput {
            NSApp.presentationOptions = []
            removeEscapeMonitor()
        }
    }
}

extension Notification.Name {
    /// An output window was placed or closed: the operator window must be re-fitted to its own
    /// screen (AppDelegate.fitOperatorWindowToScreen). Field, 2026-09-18: assigning PGM/MON
    /// shifted the console and clipped its right rail, and nothing re-fitted it after launch.
    static let operatorWindowRefit = Notification.Name("com.example.arc.operatorWindowRefit")
    /// DisplayManager asks the SwiftUI scene layer to open an output window it
    /// wants to place (userInfo "output" = OutputType rawValue). ContentView
    /// answers with openWindow(id:), on the load screen or the operator view.
    static let openOutputWindow = Notification.Name("ARCPresenter.openOutputWindow")
}

//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import AppKit

/// Duplicated from ARC Presenter's DisplayManager (2026-09-20, the operator: "duplicate the code that allows
/// ARC Presenter to control external screens"). Same rules, same words:
///   - PGM and MON are assigned to external displays; one display carries one output.
///   - GO LIVE moves the output's window onto its display at the SHIELDING level, borderless, with the
///     menu bar and Dock hidden. The flag turns true only once the window is really there.
///   - Cmd-Esc closes the outputs (plain Esc passes through, so a text field can never black the room).
///   - IDENTIFY flashes every screen with its number, name and role.
///   - A display that vanishes takes its output down and brings it back when it returns; sleep and wake
///     do the same.
/// Left out on purpose: the pointer lock (a Spotlight-remote convenience Presenter needs and this app
/// does not), and the SwiftUI-scene dance, because this app's output windows are AppKit windows the
/// Sidecar owns; `ensureWindow` asks it to open one.
///
/// Together with Presenter: a window on an output is at the shielding level, which Presenter's picker
/// does not list. Close the output (window back to ordinary level on the operator's screen) before
/// Presenter attaches it. Both at once is the next step, not this one.
@MainActor
@Observable
final class DisplayManager {
    var statusMessage: String?
    private(set) var availableScreens: [ScreenIdentity] = []
    static let displayOutputs: [OutputType] = [.program, .confidence]

    private var screenIDs: [OutputType: CGDirectDisplayID] = [:]
    private var connectedOutputs: Set<OutputType> = []
    private var wasConnectedBeforeSleep: Set<OutputType> = []
    private var idsBeforeSleep: [OutputType: CGDirectDisplayID] = [:]
    private var pendingIDs: [OutputType: CGDirectDisplayID] = [:]
    private var escapeMonitor: Any?
    private var flashWindows: [NSWindow] = []

    /// The Sidecar opens the output's window (it owns them); this only places it.
    @ObservationIgnored var ensureWindow: ((OutputType) -> Void)?
    /// Called when an output closes, so the Sidecar's own idea of open windows follows.
    @ObservationIgnored var didClose: ((OutputType) -> Void)?

    var programScreenID: CGDirectDisplayID? { get { screenIDs[.program] } set { screenIDs[.program] = newValue } }
    var confidenceScreenID: CGDirectDisplayID? { get { screenIDs[.confidence] } set { screenIDs[.confidence] = newValue } }
    var isProgramConnected: Bool { connectedOutputs.contains(.program) }
    var isConfidenceConnected: Bool { connectedOutputs.contains(.confidence) }
    var hasExternalScreen: Bool { availableScreens.contains { !$0.isBuiltIn } }
    var externalScreens: [ScreenIdentity] { availableScreens.filter { !$0.isBuiltIn } }
    var hasActiveOutput: Bool { !connectedOutputs.isEmpty }
    var programScreen: ScreenIdentity? { screenFor(.program) }
    var confidenceScreen: ScreenIdentity? { screenFor(.confidence) }
    var programScreenFrame: CGRect? { programScreenID.flatMap { id in availableScreens.first { $0.id == id }?.frame } }

    func screenFor(_ output: OutputType) -> ScreenIdentity? {
        guard let id = screenIDs[output] else { return nil }
        return availableScreens.first { $0.id == id }
    }
    func screenID(for output: OutputType) -> CGDirectDisplayID? { screenIDs[output] }
    func isConnected(_ output: OutputType) -> Bool { output == .operatorView ? true : connectedOutputs.contains(output) }

    init() {
        detectScreens()
        restoreAssignments()
        NotificationCenter.default.addObserver(self, selector: #selector(screensDidChange), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(systemWillSleep), name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(systemDidWake), name: NSWorkspace.didWakeNotification, object: nil)
    }

    nonisolated deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    // MARK: - Screens

    func detectScreens() {
        availableScreens = NSScreen.screens.enumerated().compactMap { ScreenIdentity.from($1, index: $0) }
    }

    func assign(screen: ScreenIdentity, to output: OutputType) {
        guard Self.displayOutputs.contains(output) else { return }
        for other in Self.displayOutputs where other != output && screenIDs[other] == screen.id { screenIDs[other] = nil; OperatorPrefs.set("display." + other.shortLabel, nil) }
        screenIDs[output] = screen.id
        OperatorPrefs.set("display." + output.shortLabel, screen.uuid)
    }

    func unassign(_ output: OutputType) {
        guard Self.displayOutputs.contains(output) else { return }
        if isConnected(output) { closeOutput(output) }
        screenIDs[output] = nil
        OperatorPrefs.set("display." + output.shortLabel, nil)
    }

    /// The assignments from the last run, for the displays that are present now. Assign only: GO LIVE
    /// stays the operator's (a relaunch mid-show must never surprise the room).
    func restoreAssignments() {
        var restored: [String] = []
        for output in Self.displayOutputs where screenIDs[output] == nil {
            guard let uuid = OperatorPrefs.string("display." + output.shortLabel), let screen = availableScreens.first(where: { $0.uuid == uuid }) else { continue }
            screenIDs[output] = screen.id
            restored.append("\(output.shortLabel) = \(screen.localizedName)")
        }
        if !restored.isEmpty { ShowLog.log("displays restored: \(restored.joined(separator: ", "))") }
    }

    func screen(matching key: String) -> ScreenIdentity? { availableScreens.first { $0.matches(key) } }

    /// First external → PGM, second → MON.
    func autoAssign() {
        let externals = externalScreens
        if externals.count >= 1 { programScreenID = externals[0].id }
        if externals.count >= 2 { confidenceScreenID = externals[1].id }
    }

    var displaysJSON: String {
        let rows = availableScreens.map { s in
            "{\"index\":\(s.index + 1),\"name\":\"\(jsonEscape(s.localizedName))\",\"uuid\":\"\(s.uuid)\",\"resolution\":\"\(s.resolution)\",\"builtIn\":\(s.isBuiltIn),\"program\":\(s.id == programScreenID),\"confidence\":\(s.id == confidenceScreenID)}"
        }
        return "{\"displays\":[\(rows.joined(separator: ","))],\"programOpen\":\(isProgramConnected),\"confidenceOpen\":\(isConfidenceConnected)}"
    }

    // MARK: - Outputs

    @discardableResult
    func openOutput(_ output: OutputType) -> Bool {
        defer { NotificationCenter.default.post(name: .arcOutputsChanged, object: nil) }
        guard let target = resolveTarget(for: output) else {
            statusMessage = "\(output.shortLabel): no external display to go to"
            return false
        }
        Task { @MainActor [weak self] in await self?.openAndPlace(output, on: target) }
        return true
    }

    private func windowExists(_ output: OutputType) -> Bool {
        NSApplication.shared.windows.contains { $0.title == output.windowTitle }
    }

    private func openAndPlace(_ output: OutputType, on target: ScreenIdentity) async {
        for attempt in 0..<25 {
            if attempt % 5 == 0, !windowExists(output) { ensureWindow?(output) }
            try? await Task.sleep(for: .milliseconds(200))
            if moveWindow(titled: output.windowTitle, to: target) {
                ShowLog.log("\(output.shortLabel) open on \(target.localizedName) \(target.resolution)")
                setConnected(true, for: output)
                installEscapeMonitor()
                refocusOperatorWindow()
                return
            }
        }
        statusMessage = "\(output.shortLabel) window did not open"
        ShowLog.error("openOutput \(output.shortLabel): the window never appeared")
    }

    func waitForOutput(_ output: OutputType, seconds: Double = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if isConnected(output) { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    /// Back to an ordinary window on the operator's screen (where Presenter can take it), not gone.
    func closeOutput(_ output: OutputType) {
        defer { NotificationCenter.default.post(name: .arcOutputsChanged, object: nil) }
        // ROOM-VISIBLE: releasing the shield shows that display's desktop until something else is put there.
        if Self.displayOutputs.contains(output), isConnected(output) { ShowLog.log("\(output.shortLabel) closed: its display now shows the desktop (room-visible)") }
        let title = output.windowTitle
        let home = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)
        for window in NSApplication.shared.windows where window.title == title {
            window.level = .normal
            window.styleMask = [.borderless, .resizable]
            let size = output.layoutKind?.defaultSize ?? CGSize(width: 1280, height: 720)
            window.setFrame(NSRect(x: home.minX + 24, y: home.minY + 24, width: size.width, height: size.height), display: true)
            window.orderBack(nil)
        }
        setConnected(false, for: output)
        if !hasActiveOutput {
            NSApp.presentationOptions = []
            removeEscapeMonitor()
        }
    }

    func closeAllOutputs() { for output in Self.displayOutputs { closeOutput(output) } }
    func openAllAssigned() { for output in Self.displayOutputs where screenIDs[output] != nil { openOutput(output) } }

    // MARK: - Identify

    func flashAllScreens() {
        dismissFlash()
        for screen in availableScreens { flashSingleScreen(screen) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in self?.dismissFlash() }
    }

    func flashScreen(_ screen: ScreenIdentity) {
        dismissFlash()
        flashSingleScreen(screen)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in self?.dismissFlash() }
    }

    private func flashSingleScreen(_ screen: ScreenIdentity) {
        guard let nsScreen = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == screen.id }) else { return }
        var label = "OUTPUT \(screen.index + 1)\n\(screen.localizedName)\n\(screen.resolution)"
        if programScreenID == screen.id { label += "\n[PROGRAM]" }
        if confidenceScreenID == screen.id { label += "\n[GALLERY MON]" }
        let window = NSWindow(contentRect: nsScreen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
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
        NSLayoutConstraint.activate([textField.centerXAnchor.constraint(equalTo: container.centerXAnchor), textField.centerYAnchor.constraint(equalTo: container.centerYAnchor)])
        window.contentView = container
        window.orderFrontRegardless()
        flashWindows.append(window)
    }

    func dismissFlash() {
        for window in flashWindows { window.orderOut(nil) }
        flashWindows.removeAll()
    }

    // MARK: - Placement

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
        case .operatorView: return nil
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

    @discardableResult
    private func moveWindow(titled title: String, to target: ScreenIdentity) -> Bool {
        guard let nsScreen = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == target.id }) else { return false }
        for window in NSApplication.shared.windows where window.title == title {
            configureOutputWindow(window, on: nsScreen)
            var options: NSApplication.PresentationOptions = [.autoHideMenuBar, .autoHideDock]
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
            for window in NSApplication.shared.windows where window.isVisible && window.title == OutputType.operatorView.windowTitle {
                window.makeKeyAndOrderFront(nil)
                break
            }
        }
    }

    // MARK: - Escape

    private func installEscapeMonitor() {
        removeEscapeMonitor()
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            if event.modifierFlags.contains(.command) { self?.closeAllOutputs(); return nil }
            self?.statusMessage = "⌘ Esc closes the outputs"
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                if self?.statusMessage == "⌘ Esc closes the outputs" { self?.statusMessage = nil }
            }
            return event
        }
    }

    private func removeEscapeMonitor() {
        if let monitor = escapeMonitor { NSEvent.removeMonitor(monitor); escapeMonitor = nil }
    }

    // MARK: - Sleep, wake, displays coming and going

    @objc private func systemWillSleep(_ note: Notification) {
        wasConnectedBeforeSleep = connectedOutputs
        idsBeforeSleep = screenIDs
        statusMessage = "System sleeping, outputs paused"
    }

    @objc private func systemDidWake(_ note: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self else { return }
            self.detectScreens()
            for output in Self.displayOutputs where self.wasConnectedBeforeSleep.contains(output) {
                guard let prevID = self.idsBeforeSleep[output], self.availableScreens.contains(where: { $0.id == prevID }) else { continue }
                self.screenIDs[output] = prevID
                self.openOutput(output)
            }
            self.statusMessage = self.wasConnectedBeforeSleep.isEmpty ? nil : "System woke, restoring outputs"
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.statusMessage = nil }
        }
    }

    @objc private func screensDidChange(_ note: Notification) {
        detectScreens()
        var lost: [String] = []
        for output in Self.displayOutputs {
            guard let id = screenIDs[output], !availableScreens.contains(where: { $0.id == id }) else { continue }
            if isConnected(output) { pendingIDs[output] = id; lost.append(output.shortLabel) }
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
        ShowLog.log("display back, restoring \(restored.map(\.shortLabel).joined(separator: ", "))")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in for output in restored { self?.openOutput(output) } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.statusMessage = nil }
    }

    /// A shield whose display vanished gets relocated by AppKit onto a remaining screen, black over the
    /// operator's monitor. Order it out until its display is back.
    private func hideOutputWindow(_ output: OutputType) {
        for window in NSApplication.shared.windows where window.title == output.windowTitle {
            window.level = .normal
            window.orderOut(nil)
        }
        didClose?(output)
        if !hasActiveOutput { NSApp.presentationOptions = []; removeEscapeMonitor() }
    }
}

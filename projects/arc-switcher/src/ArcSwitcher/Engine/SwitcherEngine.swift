//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import AppKit
import Combine

/// Core state machine: manages sources, OBS scene switching, and app commands.
///
/// v2 Architecture: ARC Switcher is a control surface; OBS is the video engine.
/// - Each registered source maps to an OBS scene with a window capture input.
/// - Switching calls OBS SetCurrentProgramScene (instant, with transitions).
/// - Show mode opens an OBS fullscreen projector on the output display.
/// - Cut to black switches to a dedicated "ARC Black" scene.
/// - Slide navigation still uses per-app AppleScript/CGEvent via profiles.
@Observable
final class SwitcherEngine {

    // MARK: - State

    private(set) var sources: [Source] = []
    private(set) var activeSourceId: String?
    private(set) var isBlack = false
    var errorMessage: String?

    let obs = OBSWebSocketClient()
    let windowManager = WindowManager()

    /// Output monitor index for OBS fullscreen projector (0-based).
    var outputMonitorIndex: Int? {
        didSet { UserDefaults.standard.set(outputMonitorIndex ?? -1, forKey: "OutputMonitorIndex") }
    }

    private(set) var isInShowMode = false
    private var sleepActivity: NSObjectProtocol?
    private var appObservers: [AnyCancellable] = []

    /// OBS scene name prefix to avoid collisions with user scenes.
    private let scenePrefix = "ARC_"
    private let blackSceneName = "ARC_Black"

    // MARK: - Computed

    var activeSource: Source? {
        sources.first { $0.id == activeSourceId }
    }

    var activeProfile: (any AppProfile)? {
        guard let source = activeSource else { return nil }
        return ProfileRegistry.profile(for: source.bundleIdentifier)
    }

    // MARK: - Init

    init() {
        let saved = UserDefaults.standard.integer(forKey: "OutputMonitorIndex")
        outputMonitorIndex = saved >= 0 ? saved : nil

        observeAppLifecycle()
        loadPersistedSources()
        setupOBSEventHandlers()
    }

    // MARK: - OBS Connection

    func connectOBS() {
        obs.connect()
    }

    func disconnectOBS() {
        if isInShowMode { exitShowMode() }
        obs.disconnect()
    }

    /// Initialize OBS scenes after connection — create Black scene and sync sources.
    func initializeOBS() async {
        guard obs.isConnected else { return }
        do {
            // Ensure the black scene exists
            try await ensureBlackScene()

            // Set default transition to Cut (instant switching)
            try await obs.setCurrentTransition("Cut")

            // Create scenes for existing sources
            for source in sources where source.isAvailable {
                try await createOBSScene(for: source)
            }

            // Open fullscreen projector if output is configured
            if let monitorIndex = outputMonitorIndex {
                try await obs.openFullscreenProjector(monitorIndex: monitorIndex)
            }
        } catch {
            errorMessage = "OBS init: \(error.localizedDescription)"
        }
    }

    private func setupOBSEventHandlers() {
        obs.onEvent = { [weak self] event in
            guard let self else { return }
            switch event.type {
            case "CurrentProgramSceneChanged":
                if let sceneName = event.data?["sceneName"] as? String {
                    self.handleSceneChanged(sceneName)
                }
            case "ExitStarted":
                self.disconnectOBS()
            default:
                break
            }
        }
    }

    private func handleSceneChanged(_ sceneName: String) {
        if sceneName == blackSceneName {
            isBlack = true
            activeSourceId = nil
        } else if sceneName.hasPrefix(scenePrefix) {
            isBlack = false
            // Find the source matching this scene
            let sourceSceneName = sceneName
            if let source = sources.first(where: { obsSceneName(for: $0) == sourceSceneName }) {
                activeSourceId = source.id
            }
        }
    }

    // MARK: - OBS Scene Management

    /// OBS scene name for a source (deterministic, prefix-namespaced).
    func obsSceneName(for source: Source) -> String {
        "\(scenePrefix)\(source.friendlyName)"
    }

    private func ensureBlackScene() async throws {
        let scenes = try await obs.getSceneList()
        let sceneNames = scenes.compactMap { $0["sceneName"] as? String }
        if !sceneNames.contains(blackSceneName) {
            try await obs.createScene(blackSceneName)
            // Black scene has no inputs — OBS renders it as solid black by default
        }
    }

    private func createOBSScene(for source: Source) async throws {
        let sceneName = obsSceneName(for: source)
        let scenes = try await obs.getSceneList()
        let sceneNames = scenes.compactMap { $0["sceneName"] as? String }

        if !sceneNames.contains(sceneName) {
            try await obs.createScene(sceneName)
        }

        // Get display UUID for capture scope — use main display (where apps render)
        guard let displayUUID = mainDisplayUUID() else {
            print("[Engine] No display UUID available for app capture")
            return
        }

        // Add ScreenCaptureKit application capture — captures all windows of the app
        let inputName = "\(sceneName)_capture"
        let captureSettings: [String: Any] = [
            "type": 2,
            "application": source.bundleIdentifier,
            "display_uuid": displayUUID,
            "show_cursor": false,
            "show_hidden_windows": false,
            "show_empty_names": false
        ]
        do {
            try await obs.createAppCapture(
                sceneName: sceneName,
                inputName: inputName,
                bundleID: source.bundleIdentifier,
                displayUUID: displayUUID
            )
        } catch {
            // Input already exists — update settings to ensure display_uuid is correct
            try? await obs.setInputSettings(inputName, settings: captureSettings)
            print("[Engine] Updated existing capture: \(inputName)")
        }
    }

    /// Get display UUID for the main screen (where apps render, not control screen).
    private func mainDisplayUUID() -> String? {
        // Prefer the main display (menu bar screen)
        if let uuid = NSScreen.main?.displayUUID {
            return uuid
        }
        // Fallback: first non-control display
        let controlID = windowManager.controlDisplayID
        for screen in NSScreen.screens where screen.displayID != controlID {
            if let uuid = screen.displayUUID {
                return uuid
            }
        }
        // Last resort: any display
        return NSScreen.screens.first?.displayUUID
    }

    private func removeOBSScene(for source: Source) async {
        let sceneName = obsSceneName(for: source)
        try? await obs.removeInput("\(sceneName)_capture")
        try? await obs.removeScene(sceneName)
    }

    // MARK: - Source Management

    /// List running apps available for registration.
    func availableApps() -> [NSRunningApplication] {
        let registeredBundles = Set(sources.map(\.bundleIdentifier))
        return NSWorkspace.shared.runningApplications.filter { app in
            app.activationPolicy == .regular
                && app.bundleIdentifier != Bundle.main.bundleIdentifier
                && !registeredBundles.contains(app.bundleIdentifier ?? "")
        }
    }

    /// Register a running app as a switchable source.
    func registerSource(app: NSRunningApplication, friendlyName: String) {
        guard let bundleId = app.bundleIdentifier else { return }
        let source = Source(
            friendlyName: friendlyName,
            bundleIdentifier: bundleId,
            pid: app.processIdentifier
        )
        sources.append(source)
        persistSources()

        // Create OBS scene asynchronously
        if obs.isConnected {
            Task { try? await createOBSScene(for: source) }
        }
    }

    /// Remove a source by ID.
    func unregisterSource(id: String) {
        if let source = sources.first(where: { $0.id == id }), obs.isConnected {
            Task { await removeOBSScene(for: source) }
        }
        sources.removeAll { $0.id == id }
        if activeSourceId == id { activeSourceId = nil }
        persistSources()
    }

    /// Reorder sources.
    func moveSources(from: IndexSet, to: Int) {
        sources.move(fromOffsets: from, toOffset: to)
        persistSources()
    }

    // MARK: - Show Mode

    /// Enter show mode: opens OBS fullscreen projector on output display.
    func enterShowMode() {
        guard !isInShowMode else { return }
        isInShowMode = true

        var options: NSApplication.PresentationOptions = [.autoHideDock, .autoHideMenuBar]
        // macOS 27: keep a stray mouse from firing a Hot Corner mid-show.
        // Only honoured while Switcher is frontmost and the Dock is auto-hidden.
        if #available(macOS 27, *) { options.insert(.disableScreenCornerInteractions) }
        NSApp.presentationOptions = options
        disableSleep()

        if obs.isConnected, let monitorIndex = outputMonitorIndex {
            Task {
                try? await obs.openFullscreenProjector(monitorIndex: monitorIndex)
                // Start on black
                try? await obs.setCurrentProgramScene(blackSceneName)
            }
        }
    }

    /// Exit show mode: close projector, restore desktop.
    func exitShowMode() {
        guard isInShowMode else { return }
        isInShowMode = false
        isBlack = false

        NSApp.presentationOptions = []
        enableSleep()
    }

    // MARK: - Switching

    /// Switch to a source by ID — tells OBS to transition to that source's scene.
    func switchTo(sourceId: String) {
        guard let source = sources.first(where: { $0.id == sourceId }),
              source.isAvailable else {
            errorMessage = "Source not available"
            return
        }

        // Stop previous source's presentation
        if let prevId = activeSourceId, prevId != sourceId,
           let prevSource = sources.first(where: { $0.id == prevId }),
           let prevApp = prevSource.runningApp {
            let prevProfile = ProfileRegistry.profile(for: prevSource.bundleIdentifier)
            if prevProfile.supportedCommands.contains(.stopPresentation) {
                try? prevProfile.execute(.stopPresentation, on: prevApp)
            }
        }

        activeSourceId = sourceId
        isBlack = false
        disableSleep()

        if obs.isConnected {
            let sceneName = obsSceneName(for: source)
            Task { try? await obs.setCurrentProgramScene(sceneName) }
        }

        // In show mode, auto-start presentation after scene switch.
        // Capture control screen first so the app can't put presenter view there.
        if isInShowMode, let app = source.runningApp {
            let profile = ProfileRegistry.profile(for: source.bundleIdentifier)
            if profile.supportedCommands.contains(.startPresentation) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
                    windowManager.withControlScreenCaptured {
                        try? profile.execute(.startPresentation, on: app)
                    }
                }
            }
        }
    }

    /// Switch to a source by 1-based index.
    func switchToIndex(_ index: Int) {
        guard index >= 1, index <= sources.count else { return }
        switchTo(sourceId: sources[index - 1].id)
    }

    /// Cut to black — switch OBS to the black scene.
    func cutToBlack() {
        isBlack = true
        if obs.isConnected {
            Task { try? await obs.setCurrentProgramScene(blackSceneName) }
        }
    }

    /// Cut from black — switch back to the active source's scene.
    func cutFromBlack() {
        isBlack = false
        if let source = activeSource, obs.isConnected {
            let sceneName = obsSceneName(for: source)
            Task { try? await obs.setCurrentProgramScene(sceneName) }
        }
    }

    // MARK: - Transitions

    /// Set OBS transition type. Common: "Cut", "Fade", "Slide", "Stinger".
    func setTransition(_ name: String, duration: Int? = nil) {
        guard obs.isConnected else { return }
        Task {
            try? await obs.setCurrentTransition(name, duration: duration)
        }
    }

    // MARK: - App Commands

    /// Send a command to the active source's app (slide nav, transport, volume).
    func sendCommand(_ command: AppCommand, toSourceId sourceId: String? = nil) {
        let targetId = sourceId ?? activeSourceId
        guard let id = targetId,
              let source = sources.first(where: { $0.id == id }),
              let app = source.runningApp else {
            errorMessage = "No target source"
            return
        }

        let profile = ProfileRegistry.profile(for: source.bundleIdentifier)
        guard profile.supportedCommands.contains(command) else {
            errorMessage = "\(profile.displayName) does not support \(command.displayName)"
            return
        }

        do {
            try profile.execute(command, on: app)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Supported commands for a source.
    func supportedCommands(for sourceId: String) -> Set<AppCommand> {
        guard let source = sources.first(where: { $0.id == sourceId }) else { return [] }
        return ProfileRegistry.profile(for: source.bundleIdentifier).supportedCommands
    }

    // MARK: - App Lifecycle Monitoring

    private func observeAppLifecycle() {
        let center = NSWorkspace.shared.notificationCenter

        center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bundleId = app.bundleIdentifier else { return }
            self?.markAvailability(bundleId: bundleId, available: false)
        }

        center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bundleId = app.bundleIdentifier else { return }
            self?.markAvailability(bundleId: bundleId, available: true, pid: app.processIdentifier)
        }
    }

    private func markAvailability(bundleId: String, available: Bool, pid: pid_t? = nil) {
        for i in sources.indices where sources[i].bundleIdentifier == bundleId {
            sources[i].isAvailable = available
            sources[i].pid = pid
            if !available && sources[i].id == activeSourceId {
                activeSourceId = nil
            }
        }
    }

    // MARK: - Persistence

    private static let sourcesKey = "RegisteredSources"

    private func persistSources() {
        if let data = try? JSONEncoder().encode(sources) {
            UserDefaults.standard.set(data, forKey: Self.sourcesKey)
        }
    }

    private func loadPersistedSources() {
        guard let data = UserDefaults.standard.data(forKey: Self.sourcesKey),
              let saved = try? JSONDecoder().decode([Source].self, from: data) else { return }

        let running = NSWorkspace.shared.runningApplications
        sources = saved.map { source in
            var s = source
            if let app = running.first(where: { $0.bundleIdentifier == source.bundleIdentifier && $0.activationPolicy == .regular }) {
                s.pid = app.processIdentifier
                s.isAvailable = true
            }
            return s
        }
    }

    // MARK: - Sleep Prevention

    private func disableSleep() {
        guard sleepActivity == nil else { return }
        sleepActivity = ProcessInfo.processInfo.beginActivity(
            options: [.idleDisplaySleepDisabled, .idleSystemSleepDisabled],
            reason: "ARC Switcher active show"
        )
    }

    func enableSleep() {
        if let activity = sleepActivity {
            ProcessInfo.processInfo.endActivity(activity)
            sleepActivity = nil
        }
    }

    // MARK: - Status for HTTP API

    func statusJSON() -> [String: Any] {
        [
            "activeSource": activeSourceId ?? NSNull(),
            "isBlack": isBlack,
            "isShowMode": isInShowMode,
            "obsConnected": obs.isConnected,
            "outputMonitor": outputMonitorIndex ?? NSNull(),
            "sources": sources.map { source in
                [
                    "id": source.id,
                    "name": source.friendlyName,
                    "bundleId": source.bundleIdentifier,
                    "available": source.isAvailable,
                    "isActive": source.id == activeSourceId,
                    "obsScene": obsSceneName(for: source),
                    "commands": Array(ProfileRegistry.profile(for: source.bundleIdentifier).supportedCommands.map(\.rawValue))
                ] as [String: Any]
            }
        ]
    }
}

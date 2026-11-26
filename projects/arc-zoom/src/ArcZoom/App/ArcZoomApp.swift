//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI
import ZoomSDK
import ARCStyle

@main
struct ArcZoomApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    /// The fake engine until Phase 0 lands the SDK one. `SDKZoomEngine.available` decides, so the day
    /// the SDK is linked this picks it up with no other change.
    /// Start on the FAKE engine even when the SDK is available. A show is set up and rehearsed on the
    /// fake, and the operator asks for the real meeting deliberately (`POST /engine?use=sdk`, or the
    /// operator page). Launching straight into a Zoom connection would be a surprise on a show day.
    static let sharedSidecar = Sidecar(engine: FakeZoomEngine())
    /// The ARC Tech ACCOUNT settings behind the PORTAL window. Not part of the 1 Hz sampler: they are
    /// not in the meeting, they come over REST, and they apply to NEW meetings only.
    static let sharedPortal = PortalStore()
    /// External screens, Presenter's way (DisplayManager.swift). The Sidecar opens the windows; this places them.
    static let sharedDisplays: DisplayManager = {
        let d = DisplayManager()
        d.ensureWindow = { output in if let k = output.layoutKind { ArcZoomApp.sharedSidecar.open(k) } }
        d.didClose = { output in if let k = output.layoutKind { ArcZoomApp.sharedSidecar.displayLost(k) } }
        return d
    }()

    var body: some Scene {
        Window("ARC Zoom", id: "operator") {
            Group {
                if AppLogin.shared.unlocked { OperatorView() } else { LoginGateView() }
            }
                .environment(Self.sharedSidecar)
                .environment(Self.sharedDisplays)
                .preferredColorScheme(.dark)
                .tint(ARCTheme.arcRed)
        }
        // A MacBook Pro's default 1512 pt width (2026-09-23); the console's minimum is 1440 x 720 of content.
        .defaultSize(width: 1512, height: 860)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Meeting") {
                Button("Join…") { NotificationCenter.default.post(name: .focusJoin, object: nil) }
                    .keyboardShortcut("j", modifiers: [.command])
                // END, never leave: leaving keeps the PMI alive with whoever stays and a cloud recording
                // running, which blocks raw video on the next start (the dark-tiles trap).
                Button("End Meeting for Everyone") { Task { await ArcZoomApp.sharedSidecar.endMeeting() } }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                Button("Lock Operator Window") { AppLogin.shared.lock() }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                    .disabled(!AppLogin.shared.unlocked)
                Divider()
                ForEach(LayoutWindow.Kind.allCases, id: \.self) { kind in
                    Button("\(kind.title) (Open / Close)") {
                        let s = ArcZoomApp.sharedSidecar
                        if s.windows[kind]?.isOpen == true { s.close(kind) } else { s.open(kind) }
                    }
                }
            }
        }

        Window("Settings", id: "settings") {
            SettingsWindowView()
                .environment(Self.sharedSidecar)
                .environment(Self.sharedDisplays)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 820, height: 680)
        .windowResizability(.contentMinSize)

        Window("Portal", id: "portal") {
            PortalWindowView()
                .environment(Self.sharedPortal)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1180, height: 820)
        .windowResizability(.contentMinSize)

        Window("Log", id: "log") {
            LogWindowView()
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 980, height: 620)
        .windowResizability(.contentMinSize)

        Window("Chat", id: "chat") {
            ChatWindowView()
                .environment(Self.sharedSidecar)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 560, height: 520)
        .windowResizability(.contentMinSize)

        Window("Captions", id: "captions") {
            CaptionsWindowView()
                .environment(Self.sharedSidecar)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 640, height: 520)
        .windowResizability(.contentMinSize)

        Window("Participants", id: "participants") {
            ParticipantsWindowView()
                .environment(Self.sharedSidecar)
                .environment(Self.sharedDisplays)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 820, height: 480)
        .windowResizability(.contentMinSize)

    }
}

extension Notification.Name {
    static let focusJoin = Notification.Name("com.example.arc.arczoom.focusJoin")
    /// object = the window id ("settings", "participants", "chat", "captions", "portal", "log"); the operator view toggles it.
    static let toggleWindow = Notification.Name("com.example.arc.arczoom.toggleWindow")
    /// An output window opened or closed on a display: the operator window re-fits itself.
    static let arcOutputsChanged = Notification.Name("com.example.arc.arczoom.outputsChanged")
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var server: ControlServer?

    private var refitWork: DispatchWorkItem?

    /// The operator window ALWAYS stays fully on its own screen, never on a display holding PGM or MON
    /// (Presenter's PLAN_control-window-resolution-fit, 2026-09-18): at launch, on every screen-parameter
    /// change (debounced: they arrive in bursts as displays enumerate) and after any output opens or closes.
    static func operatorWindow() -> NSWindow? { NSApplication.shared.windows.first { $0.title == "ARC Zoom" && $0.isVisible } }
    static func fitOperatorWindowToScreen() {
        guard let w = operatorWindow() else { return }
        let d = ArcZoomApp.sharedDisplays
        var outputIDs = Set<CGDirectDisplayID>()
        for out in [OutputType.program, OutputType.confidence] where d.isConnected(out) {
            if let id = d.screenFor(out)?.id { outputIDs.insert(id) }
        }
        func displayID(_ screen: NSScreen) -> CGDirectDisplayID? {
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
        }
        let candidates = NSScreen.screens.filter { screen in
            guard let id = displayID(screen) else { return true }
            return !outputIDs.contains(id)
        }
        var target: NSScreen? = nil
        if let current = w.screen, candidates.contains(current) { target = current }
        if target == nil { target = candidates.first { $0 == NSScreen.main } }
        if target == nil { target = candidates.first }
        if target == nil { target = NSScreen.main }
        guard let target else { return }
        // WindowFit (2026-09-23): shrink onto the visible frame, but never below the window's minimum; on a screen
        // smaller than that the TITLE BAR stays on screen (the old clamp could push it above the top edge).
        let minimum = w.frameRect(forContentRect: CGRect(origin: .zero, size: w.contentMinSize)).size
        let f = WindowFit.fit(w.frame, minimum: minimum, in: target.visibleFrame)
        if f != w.frame {
            w.setFrame(f, display: true, animate: false)
            ShowLog.log("operator window fitted to \(target.localizedName): \(Int(f.width))x\(Int(f.height))")
        }
    }
    func scheduleOperatorRefit() {
        refitWork?.cancel()
        let work = DispatchWorkItem { Self.fitOperatorWindowToScreen() }
        refitWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }
    /// `GET /window`: the oracle a fit test reads.
    static var operatorWindowJSON: String {
        guard let w = operatorWindow() else { return "{\"window\":null}" }
        let screen = w.screen
        let v = screen?.visibleFrame ?? .zero
        let fits = screen != nil && v.contains(w.frame)
        return "{\"frame\":{\"x\":\(Int(w.frame.minX)),\"y\":\(Int(w.frame.minY)),\"w\":\(Int(w.frame.width)),\"h\":\(Int(w.frame.height))},\"screen\":\"\(jsonEscape(screen?.localizedName ?? "?"))\",\"visible\":{\"x\":\(Int(v.minX)),\"y\":\(Int(v.minY)),\"w\":\(Int(v.width)),\"h\":\(Int(v.height))},\"fits\":\(fits),\"uiScale\":\(jsonNumber(Double(ARCTheme.uiScale)))}"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        ShowLog.start()
        // Every keychain item read on a background thread now; nothing on the main thread waits on macOS.
        Keychain.preload()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.scheduleOperatorRefit() }
        NotificationCenter.default.addObserver(forName: .arcOutputsChanged, object: nil, queue: .main) { [weak self] _ in self?.scheduleOperatorRefit() }
        // The control windows (Settings, Portal, Log, Chat, Captions, Participants) stay on screen too.
        WindowPlacement.install()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { Self.fitOperatorWindowToScreen() }
        // One instance per Mac: two copies (a Debug build beside the installed Release) would fight for
        // port 8766, the camera and the account's single meeting (audit P1).
        let me = ProcessInfo.processInfo.processIdentifier
        let underTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        if !underTest, let other = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "com.example.arc.ArcZoom").first(where: { $0.processIdentifier != me }) {
            ShowLog.log("another ARC Zoom is already running (pid \(other.processIdentifier)); this copy quits")
            other.activate()
            NSApp.terminate(nil)
            return
        }
        let info = Bundle.main.infoDictionary ?? [:]
        ShowLog.log("ARC Zoom \(info["CFBundleShortVersionString"] as? String ?? "?") build \(info["CFBundleVersion"] as? String ?? "?") \(info["ARCGitHash"] as? String ?? "") starting, engine = \(ArcZoomApp.sharedSidecar.engineKind)")
        let server = ControlServer(port: 8766) { method, path, query in
            await Self.handle(method: method, path: path, query: query)
        }
        server.start()
        self.server = server
        // The SDK engine at launch, with no meeting: the SOUND module's device menus, the pre-flight
        // checks and CREATE MEETING all sit on it, and the operator configures BEFORE connecting (
        // 2026-09-21). The fake engine is the rehearsal rig and stays one POST /engine?use=fake away.
        // `available` reads the Marketplace pair, so it is asked AFTER the keychain preload: asked first, on
        // the main thread, it answered "no pair yet" and the SDK never started (2026-09-24).
        if !underTest {
            Task { @MainActor in
                await Keychain.waitForPreload()   // the SDK's JWT needs the Marketplace pair
                guard SDKZoomEngine.available else { ShowLog.log("SDK engine not started: \(SDKZoomEngine.unavailableReason)"); return }
                if await ArcZoomApp.sharedSidecar.ensureSDK() != nil { ShowLog.log("SDK engine ready before any meeting; devices and pre-flight are live") }
                else { ShowLog.error("SDK engine not ready at launch: \(ArcZoomApp.sharedSidecar.lastError ?? "?"); still on the fake") }
            }
        }
    }

    /// Quitting mid-show is the dark-tiles trap: LEAVING keeps the personal meeting alive with whoever
    /// stays and a cloud recording running, and the next start gets no raw video. So a quit while in a
    /// meeting or live on a display asks, then ENDS for everyone before the SDK shuts down.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let s = ArcZoomApp.sharedSidecar
        let inMeeting = s.state == .inMeeting || s.state == .joining || s.state == .reconnecting
        guard inMeeting || ArcZoomApp.sharedDisplays.hasActiveOutput else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = inMeeting ? "End the meeting for everyone and quit?" : "Close the live outputs and quit?"
        alert.informativeText = inMeeting
            ? "ARC Zoom is hosting a meeting. Quitting ends it for every participant and stops any cloud recording. The room displays go dark."
            : "PGM or MON is live on a room display. Quitting releases the display to the desktop."
        alert.alertStyle = .critical
        alert.addButton(withTitle: inMeeting ? "End Meeting and Quit" : "Quit")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        Task { @MainActor in
            if inMeeting { await s.endMeeting() }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        server?.stop()
        // The Zoom SDK must be shut down before the process exits, or its static destructors segfault
        // from exit() (2026-09-20: every quit produced a crash report).
        (ArcZoomApp.sharedSidecar.engine as? SDKZoomEngine)?.shutdownSynchronously()
        ShowLog.log("ARC Zoom quitting")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: - Control API (curl on 127.0.0.1:8766)

    static func handle(method: String, path: String, query: [String: String]) async -> (Int, String) {
        await Routes.dispatch(method: method, path: path, query: query)
    }
}

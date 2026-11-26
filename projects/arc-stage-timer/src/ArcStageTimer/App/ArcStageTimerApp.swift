//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI
import SwiftData

@main
struct ArcStageTimerApp: App {
    let container: ModelContainer
    @State private var importedShow: Show?

    // Shared instances — accessible by both WindowGroups and UIScreen fallback
    static let sharedEngine = TimerEngine()
    static let sharedDisplayManager = ExternalDisplayManager()
    static let sharedStageDirector = StageDirector()
    static let sharedHTTPServer = HTTPRemoteServer()
    static let sharedDisplayState = StageDisplayState()
    static let sharedConfidenceState = ConfidenceMonitorState()
    #if os(macOS)
    static let sharedRoutingManager = OutputRoutingManager()
    static let sharedDeckLinkManager = DeckLinkOutputManager()
    /// Where the control window and the outputs sit (DisplayPlacement.swift).
    static let sharedPlacement = DisplayPlacement()
    @NSApplicationDelegateAdaptor(StageAppDelegate.self) private var appDelegate
    #endif

    // Client mode (iPad as remote display)
    static let sharedBonjourBrowser = BonjourBrowser()
    static let sharedRemoteState = RemoteTimerState()

    private var bridgeTimer: DispatchSourceTimer?

    /// Bump this when @Model schemas change or sample data changes.
    private static let schemaVersion = 2  // v2: simplified 3-cue test show

    init() {
        #if os(macOS)
        // A headless run closes the operator window, and macOS remembers that: the NEXT ordinary launch then
        // opened with no control window at all and nothing to click (2026-09-17). A headless run leaves no
        // window state behind.
        if StageTimerLaunch.isHeadless {
            var args = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
            args["ApplePersistenceIgnoreState"] = true
            args["NSQuitAlwaysKeepsWindows"] = false
            UserDefaults.standard.setVolatileDomain(args, forName: UserDefaults.argumentDomain)
        }
        #endif

        // Detect stale schema and wipe the store so SwiftData rebuilds cleanly.
        let defaults = UserDefaults.standard
        if defaults.integer(forKey: "schemaVersion") < Self.schemaVersion {
            let fileManager = FileManager.default
            if let supportDir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
                for suffix in ["", "-shm", "-wal"] {
                    let url = supportDir.appendingPathComponent("default.store\(suffix)")
                    try? fileManager.removeItem(at: url)
                }
            }
            defaults.set(Self.schemaVersion, forKey: "schemaVersion")
        }

        let schema = Schema([Show.self, Cue.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: false)
        do {
            container = try ModelContainer(for: schema, configurations: [config])
        } catch {
            // Store corrupted — wipe and retry
            if let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
                for suffix in ["", "-shm", "-wal"] {
                    try? FileManager.default.removeItem(at: supportDir.appendingPathComponent("default.store\(suffix)"))
                }
            }
            do {
                container = try ModelContainer(for: schema, configurations: [config])
            } catch {
                container = try! ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
            }
        }
        SampleData.createIfNeeded(context: container.mainContext)

        // Wire display state to HTTP server
        Self.sharedHTTPServer.displayState = Self.sharedDisplayState
        Self.sharedDisplayManager.displayState = Self.sharedDisplayState

        // Start HTTP server + Bonjour advertisement immediately (Mac only)
        #if os(macOS)
        Self.sharedHTTPServer.engine = Self.sharedEngine
        Self.sharedHTTPServer.stageDirector = Self.sharedStageDirector
        Self.sharedHTTPServer.start()

        // Wire DeckLink fill+key output to the shared display state
        Self.sharedDeckLinkManager.displayState = Self.sharedDisplayState
        Self.sharedDeckLinkManager.confidenceState = Self.sharedConfidenceState
        Self.sharedHTTPServer.placement = Self.sharedPlacement
        #endif
    }

    var body: some Scene {
        // Named so the operator window can be opened and placed by id.
        WindowGroup("ARC Stage Timer", id: StageWindowID.control) {
            ContentView()
                .environment(\.importedShowBinding, $importedShow)
                .environment(Self.sharedEngine)
                .environment(Self.sharedDisplayManager)
                .environment(Self.sharedStageDirector)
                .environment(Self.sharedHTTPServer)
                .environment(Self.sharedDisplayState)
                .environment(Self.sharedConfidenceState)
                .environment(Self.sharedBonjourBrowser)
                .environment(Self.sharedRemoteState)
                .injectRoutingManager()
                .onAppear {
                    #if os(macOS)
                    Self.sharedPlacement.applyLaunchArguments()
                    #endif
                    Self.sharedDisplayManager.stageDirector = Self.sharedStageDirector
                    Self.sharedDisplayManager.engine = Self.sharedEngine
                    Self.sharedHTTPServer.engine = Self.sharedEngine
                    Self.sharedHTTPServer.stageDirector = Self.sharedStageDirector
                    startLocalBridge()
                    // Bonjour browsing starts from ShowListView connection section
                }
                .onOpenURL { url in
                    handleOpenURL(url)
                }
                .preferredColorScheme(.dark)
        }
        .modelContainer(container)
        #if os(macOS)
        .defaultSize(width: 1200, height: 800)
        // contentSize pinned the window to whatever the layout wanted; the console should fill the display it is put on.
        .windowResizability(.contentMinSize)
        .commands {
            CommandMenu("Show") {
                Button("Undo \(Self.sharedEngine.undoActionName ?? "")") {
                    Self.sharedEngine.undo()
                }
                .keyboardShortcut("z", modifiers: .command)

                Button("Operate Widget / Program Console") {
                    ConsoleModeController.shared.toggle()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(!Self.sharedEngine.canUndo)

                // MESSAGE / ALERT / FLASH (2026-09-24).
                Button("Message…") {
                    NotificationCenter.default.post(name: .focusMessageField, object: nil)
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                Button("Flash Red for Attention") {
                    Self.sharedStageDirector.flashForAttention(color: .red)
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                Button("Clear Message, Alert and Flash") {
                    Self.sharedStageDirector.clearAll()
                }
                .keyboardShortcut("x", modifiers: [.command, .shift])

                Divider()

                // LAYOUT (also the chip in the run view's toolbar).
                Button("Layout: RUN") { UserDefaults.standard.set(RunLayout.run.rawValue, forKey: RunLayout.defaultsKey) }
                Button("Layout: DECK") { UserDefaults.standard.set(RunLayout.deck.rawValue, forKey: RunLayout.defaultsKey) }

                Divider()

                // CONFIDENCE MONITOR and KEY OVERLAY live on their displays, or off the air (header GO LIVE).
                Button("Go Live / Off Air") {
                    NotificationCenter.default.post(name: .goLive, object: nil)
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])

                Divider()

                Button("Play / Pause") {
                    BareKeyRouter.handle(.space) { Self.sharedEngine.togglePlayPause() }
                }
                .keyboardShortcut(" ", modifiers: [])

                Button("Next Cue") {
                    BareKeyRouter.handle(.right) { Self.sharedEngine.next() }
                }
                .keyboardShortcut(.rightArrow, modifiers: [])

                Button("Previous Cue") {
                    BareKeyRouter.handle(.left) { Self.sharedEngine.previous() }
                }
                .keyboardShortcut(.leftArrow, modifiers: [])

                Divider()

                Button("Reset Cue") {
                    Self.sharedEngine.reset()
                }
                .keyboardShortcut("r", modifiers: [.command])

                Button("Stop Show") {
                    BareKeyRouter.handle(.escape) { Self.sharedEngine.stop() }
                }
                .keyboardShortcut(.escape, modifiers: [])

                Divider()

                Button("Flash Red") {
                    BareKeyRouter.handle(.digit("1")) { Self.sharedStageDirector.flash(color: .red) }
                }
                .keyboardShortcut("1", modifiers: [])

                Button("Flash Yellow") {
                    BareKeyRouter.handle(.digit("2")) { Self.sharedStageDirector.flash(color: .yellow) }
                }
                .keyboardShortcut("2", modifiers: [])

                Button("Flash Green") {
                    BareKeyRouter.handle(.digit("3")) { Self.sharedStageDirector.flash(color: .green) }
                }
                .keyboardShortcut("3", modifiers: [])

                Button("Flash White") {
                    BareKeyRouter.handle(.digit("4")) { Self.sharedStageDirector.flash(color: .white) }
                }
                .keyboardShortcut("4", modifiers: [])
            }
        }
        #endif

        // Stage display window — opened via openWindow(id:) for external display
        WindowGroup(StageWindowTitle.stage, id: "stage-display") {
            StageDisplayView()
                .environment(Self.sharedDisplayState)
                .preferredColorScheme(.dark)
        }
        #if os(macOS)
        .defaultSize(width: 1920, height: 1080)
        .commands {
            CommandMenu("Show") {
                Button("Play / Pause") {
                    BareKeyRouter.handle(.space) { Self.sharedEngine.togglePlayPause() }
                }
                .keyboardShortcut(" ", modifiers: [])

                Button("Next Cue") {
                    BareKeyRouter.handle(.right) { Self.sharedEngine.next() }
                }
                .keyboardShortcut(.rightArrow, modifiers: [])

                Button("Previous Cue") {
                    BareKeyRouter.handle(.left) { Self.sharedEngine.previous() }
                }
                .keyboardShortcut(.leftArrow, modifiers: [])

                Divider()

                Button("Reset Cue") {
                    Self.sharedEngine.reset()
                }
                .keyboardShortcut("r", modifiers: [.command])

                Button("Stop Show") {
                    BareKeyRouter.handle(.escape) { Self.sharedEngine.stop() }
                }
                .keyboardShortcut(.escape, modifiers: [])

                Divider()

                Button("Flash Red") {
                    BareKeyRouter.handle(.digit("1")) { Self.sharedStageDirector.flash(color: .red) }
                }
                .keyboardShortcut("1", modifiers: [])

                Button("Flash Yellow") {
                    BareKeyRouter.handle(.digit("2")) { Self.sharedStageDirector.flash(color: .yellow) }
                }
                .keyboardShortcut("2", modifiers: [])

                Button("Flash Green") {
                    BareKeyRouter.handle(.digit("3")) { Self.sharedStageDirector.flash(color: .green) }
                }
                .keyboardShortcut("3", modifiers: [])

                Button("Flash White") {
                    BareKeyRouter.handle(.digit("4")) { Self.sharedStageDirector.flash(color: .white) }
                }
                .keyboardShortcut("4", modifiers: [])
            }
        }
        #endif

        // The OPERATE widget: one window, floating (ConsoleMode.swift configures it once it is up).
        #if os(macOS)
        Window(StageWindowTitle.widget, id: StageWindowID.widget) {
            OperateWidgetView()
                .environment(Self.sharedEngine)
                .environment(Self.sharedStageDirector)
                .environment(Self.sharedDisplayState)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: OperateWidgetView.width, height: 200)
        #endif

        // Settings (Cmd-,): the KEY OVERLAY switch (2026-09-24).
        #if os(macOS)
        Settings {
            AppSettingsView()
                .preferredColorScheme(.dark)
        }
        #endif

        // Confidence monitor — single luma key output (bright on black, ATEM luma keys the black out)
        #if os(macOS)
        WindowGroup(StageWindowTitle.keyOverlay, id: "confidence-output") {
            StageDisplayView(
                confidenceConfig: Self.sharedConfidenceState.config
            )
            .environment(Self.sharedDisplayState)
            .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 1920, height: 1080)
        #endif
    }

    // MARK: - Local Bridge (syncs TimerEngine + StageDirector → StageDisplayState)

    private func startLocalBridge() {
        // Use a display link cadence timer to keep display state in sync
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(100))
        timer.setEventHandler {
            Self.sharedDisplayState.syncFromLocal(
                engine: Self.sharedEngine,
                director: Self.sharedStageDirector
            )
        }
        timer.resume()
        Self._localBridgeTimer = timer
    }

    private static var _localBridgeTimer: DispatchSourceTimer?

    private func handleOpenURL(_ url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url),
              let show = try? ROSImporter.importShow(from: data) else { return }

        let context = container.mainContext
        context.insert(show)
        for cue in show.cues {
            cue.show = show
            context.insert(cue)
        }
        try? context.save()
        importedShow = show
    }
}

// MARK: - Environment Keys

private struct ImportedShowBindingKey: EnvironmentKey {
    static let defaultValue: Binding<Show?> = .constant(nil)
}

extension EnvironmentValues {
    var importedShowBinding: Binding<Show?> {
        get { self[ImportedShowBindingKey.self] }
        set { self[ImportedShowBindingKey.self] = newValue }
    }
}

// MARK: - Platform-Conditional Routing Manager Injection

extension View {
    @ViewBuilder
    func injectRoutingManager() -> some View {
        #if os(macOS)
        self.environment(ArcStageTimerApp.sharedRoutingManager)
            .environment(ArcStageTimerApp.sharedDeckLinkManager)
        #else
        self
        #endif
    }
}

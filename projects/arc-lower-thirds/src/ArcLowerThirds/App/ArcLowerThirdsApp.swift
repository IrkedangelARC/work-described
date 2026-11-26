//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI
import SwiftData
import AppKit

// MARK: - App Delegate (window restoration cleanup)

/// Ensures the main editor window appears on launch by closing any
/// restored Stage/Key output windows before SwiftUI creates its scenes.
class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Kill any restored output windows — they should only open via user action.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            for window in NSApplication.shared.windows {
                let title = window.title
                if title == "Stage Output" || title == "Key Output" {
                    window.close()
                }
            }
        }
    }

    /// Prevent the "restore windows?" dialog on relaunch after crash.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        true
    }
}

@main
struct ArcLowerThirdsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    let container: ModelContainer
    @State private var importedShow: Show?

    // Shared singletons — accessible by all windows
    static let sharedEngine = GraphicsEngine()
    static let sharedDisplayManager = ExternalDisplayManager()
    static let sharedHTTPServer = HTTPRemoteServer()
    static let sharedPresetManager = PresetManager()
    static let sharedDeckLink = DeckLinkOutputManager()

    /// Bump this when @Model schemas change to force a store reset.
    /// Only safe because this app's data is easily re-created (sample data + user imports).
    private static let schemaVersion = 13  // v13: simplified 3-graphic test show

    init() {
        // Disable macOS window state restoration — prevents secondary windows
        // from reopening instead of the main editor.
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")

        let schema = Schema([Show.self, Graphic.self])

        // Detect stale schema and wipe the store so SwiftData rebuilds cleanly.
        let defaults = UserDefaults.standard
        if defaults.integer(forKey: "schemaVersion") < Self.schemaVersion {
            let fileManager = FileManager.default
            if let supportDir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
                let storeName = "default"
                for suffix in ["", "-shm", "-wal"] {
                    let url = supportDir.appendingPathComponent("\(storeName).store\(suffix)")
                    try? fileManager.removeItem(at: url)
                }
            }
            defaults.set(Self.schemaVersion, forKey: "schemaVersion")
        }

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
                // Last resort: in-memory only (data won't persist but app won't crash)
                container = try! ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
            }
        }
        SampleData.createIfNeeded(context: container.mainContext)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
                .environment(\.importedShowBinding, $importedShow)
                .environment(Self.sharedEngine)
                .environment(Self.sharedDisplayManager)
                .environment(Self.sharedHTTPServer)
                .environment(Self.sharedPresetManager)
                .environment(Self.sharedDeckLink)
                .onAppear {
                    Self.sharedDisplayManager.engine = Self.sharedEngine
                    Self.sharedDisplayManager.deckLink = Self.sharedDeckLink
                    Self.sharedHTTPServer.engine = Self.sharedEngine
                }
                .onOpenURL { url in
                    handleOpenURL(url)
                }
        }
        .modelContainer(container)
        .defaultSize(width: 1200, height: 800)
        .windowResizability(.contentSize)
        .commands {
            // Show menu
            CommandMenu("Show") {
                Button("Run Show") {
                    // Handled by MainEditorView toolbar
                }
                .keyboardShortcut("r")

                Button("Stop Show") {
                    Self.sharedEngine.unloadShow()
                }
                .keyboardShortcut(".", modifiers: .command)
            }

            // Graphics menu — live control
            CommandMenu("Graphics") {
                Button("Fire") {
                    Self.sharedEngine.fire()
                }
                .keyboardShortcut(" ", modifiers: [])

                Button("Clear") {
                    Self.sharedEngine.clear()
                }
                .keyboardShortcut(.escape, modifiers: [])

                Button("Cut to Black") {
                    Self.sharedEngine.cutToBlack()
                }
                .keyboardShortcut("k")

                Divider()

                Button("Next Graphic") {
                    Self.sharedEngine.next()
                }
                .keyboardShortcut(.rightArrow, modifiers: [])

                Button("Previous Graphic") {
                    Self.sharedEngine.previous()
                }
                .keyboardShortcut(.leftArrow, modifiers: [])
            }

            // Output menu
            CommandMenu("Output") {
                Button("Open Fill Window") {
                    NotificationCenter.default.post(name: .openStageWindow, object: nil)
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])

                Button("Open Key Window") {
                    NotificationCenter.default.post(name: .openKeyWindow, object: nil)
                }
                .keyboardShortcut("o", modifiers: [.command, .shift, .option])

                Button("Open Both (Fill + Key)") {
                    NotificationCenter.default.post(name: .openStageWindow, object: nil)
                    NotificationCenter.default.post(name: .openKeyWindow, object: nil)
                }

                Divider()

                Button(Self.sharedDeckLink.isEnabled
                       ? "Stop DeckLink Fill+Key (Thunderbolt/ATEM)"
                       : "Start DeckLink Fill+Key (Thunderbolt/ATEM)") {
                    if Self.sharedDeckLink.isEnabled {
                        Self.sharedDeckLink.disable()
                    } else {
                        Self.sharedDeckLink.enable()
                    }
                }

                Divider()

                Button(Self.sharedHTTPServer.isRunning ? "Stop HTTP Server" : "Start HTTP Server") {
                    if Self.sharedHTTPServer.isRunning {
                        Self.sharedHTTPServer.stop()
                    } else {
                        Self.sharedHTTPServer.start()
                    }
                }
            }

            // Template menu — quick template switching
            CommandMenu("Template") {
                ForEach(Array(GraphicTemplate.allCases.enumerated()), id: \.element.id) { index, template in
                    Button(template.displayName) {
                        if let graphic = Self.sharedEngine.selectedGraphic {
                            graphic.template = template
                        }
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                }
            }
        }

        // Stage output — singleton window, suppressed on launch.
        // Opened explicitly via Run Show or Output menu.
        Window("Stage Output", id: "stage-output") {
            StageOutputView()
                .environment(Self.sharedEngine)
                .environment(Self.sharedDeckLink)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1920, height: 1080)
        .defaultLaunchBehavior(.suppressed)

        // Key output — singleton window, suppressed on launch.
        // Opened only in Fill + Key mode.
        Window("Key Output", id: "key-output") {
            KeyOutputView()
                .environment(Self.sharedEngine)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1920, height: 1080)
        .defaultLaunchBehavior(.suppressed)
    }

    private func handleOpenURL(_ url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url),
              let show = try? GraphicsImporter.importShow(from: data) else { return }

        let context = container.mainContext
        context.insert(show)
        for graphic in show.graphics {
            graphic.show = show
            context.insert(graphic)
        }
        try? context.save()
        importedShow = show
    }
}

// Environment key for passing imported show from app level to views
private struct ImportedShowBindingKey: EnvironmentKey {
    static let defaultValue: Binding<Show?> = .constant(nil)
}

extension EnvironmentValues {
    var importedShowBinding: Binding<Show?> {
        get { self[ImportedShowBindingKey.self] }
        set { self[ImportedShowBindingKey.self] = newValue }
    }
}

extension Notification.Name {
    static let openStageWindow = Notification.Name("com.example.arc.openStageWindow")
    static let openKeyWindow = Notification.Name("com.example.arc.openKeyWindow")
}

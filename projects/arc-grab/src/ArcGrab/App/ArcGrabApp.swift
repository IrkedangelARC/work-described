//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI
import AppKit

/// Quit guard: with jobs running, ask; on quit, kill every child process.
final class ArcGrabAppDelegate: NSObject, NSApplicationDelegate {
    weak var queue: GrabQueue?

    /// `--grab URL --into DIR`: the command-line grab for the other ARC apps (HeadlessGrab). No window, exit when done.
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard HeadlessGrab.isRequested else { return }
        NSApp.setActivationPolicy(.accessory)
        NSApp.windows.forEach { $0.orderOut(nil) }
        Task { @MainActor in
            let code = await HeadlessGrab.run()
            fflush(stdout)
            exit(code)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let queue, queue.activeCount > 0 else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "\(queue.activeCount) grab\(queue.activeCount == 1 ? "" : "s") still running"
        alert.informativeText = "Quitting cancels them. Partial files are removed."
        alert.addButton(withTitle: "Keep Running")
        alert.addButton(withTitle: "Quit and Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateCancel : .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        queue?.cancelAll()
        queue?.shutdown()
        GrabLog.log("app", "quit")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !HeadlessGrab.isRequested }
}

@main
struct ArcGrabApp: App {
    @NSApplicationDelegateAdaptor(ArcGrabAppDelegate.self) private var delegate
    // A headless launch runs its own queue (HeadlessGrab); the window's must not discover the engine too.
    @State private var queue = GrabQueue(startEngine: !HeadlessGrab.isRequested)
    @State private var settings = Settings()

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    init() {
        GrabLog.log("app", "ARC Grab \(ArcGrabApp.version) launched")
    }

    var body: some Scene {
        WindowGroup {
            ContentView(queue: queue, settings: settings)
                .preferredColorScheme(.dark)
                .navigationTitle("ARC Grab \(ArcGrabApp.version)")
                .onAppear {
                    queue.concurrency = settings.concurrency
                    delegate.queue = queue
                }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 980, height: 780)
        .commands {
            CommandGroup(after: .pasteboard) {
                Button("Add from Clipboard") {
                    if let s = NSPasteboard.general.string(forType: .string) {
                        queue.add(text: s, options: settings.options)
                    }
                }
                .keyboardShortcut("v", modifiers: [.command, .shift])
                Button("Reveal Destination") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: settings.options.destination))
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .help) {
                Button("Show Log File") {
                    NSWorkspace.shared.activateFileViewerSelecting([GrabLog.file])
                }
            }
        }
    }
}

//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI
import AppKit

/// ARC Slide Log: a menu bar app for a live session on an ARC laptop where presenters run their own
/// apps. It records three things so ARC Edit can rebuild the click-through from the deck files: a very
/// low resolution recording of the program display with the presentation's sound, every click impulse
/// with its time, and a scratch track from the laptop to line it all up with the cameras. Nothing else.
/// Plan: docs/PLAN_arc_slide_log.txt.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var session: Session?
    /// A quit while logging is almost always a slip: ask, and offer to stop first.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let s = Self.session, s.isRunning, !Launch.args.contains("--stop-after") else { return .terminateNow }
        let a = NSAlert()
        a.messageText = "ARC Slide Log is logging"
        a.informativeText = "Quitting ends the session. The files written so far stay readable."
        a.addButton(withTitle: "Keep logging")
        a.addButton(withTitle: "Stop and quit")
        NSApp.activate(ignoringOtherApps: true)
        return a.runModal() == .alertFirstButtonReturn ? .terminateCancel : .terminateNow
    }
    func applicationWillTerminate(_ notification: Notification) { Self.session?.quit() }
}

/// Launch arguments, for drills and tests: `--display main|<name part>|<id>`, `--show NAME`, `--out FOLDER`,
/// `--no-scratch`, `--start`, `--stop-after SECONDS` (stops and quits).
enum Launch {
    static let args = CommandLine.arguments
    static func value(_ flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    @MainActor static func apply(to session: Session) {
        if let d = value("--display") {
            if d == "main" { session.selectedDisplayID = CGMainDisplayID() }
            else if let id = UInt32(d) { session.selectedDisplayID = id }
            else if let m = session.displays.first(where: { $0.name.localizedCaseInsensitiveContains(d) }) { session.selectedDisplayID = m.id }
        }
        if let s = value("--show") { session.showName = s }
        if let o = value("--out") { session.outputBase = URL(fileURLWithPath: (o as NSString).expandingTildeInPath) }
        if args.contains("--no-scratch") { session.recordScratch = false }
        if args.contains("--start") { session.start() }
        if let s = value("--stop-after").flatMap(Double.init) {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(s))
                session.stop()
                try? await Task.sleep(for: .seconds(2))
                NSApp.terminate(nil)
            }
        }
    }
}

@main
struct ArcSlideLogApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var session = Session()

    init() {
        // The menu's views are built lazily (only when the menu opens), so the consents and the launch
        // arguments must run from here, not from a view task.
        let s = session
        AppDelegate.session = s
        Task { @MainActor in
            await s.prepare()
            Launch.apply(to: s)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            SessionMenu(session: session)
        } label: {
            Image(systemName: session.isRunning ? "record.circle.fill" : "record.circle")
                .symbolRenderingMode(.palette)
                .foregroundStyle(session.isRunning ? Color.red : Color.primary)
        }
        .menuBarExtraStyle(.menu)
    }
}

/// The whole operator surface: status, start/stop, the display and the input, the folder, consents.
struct SessionMenu: View {
    @Bindable var session: Session

    var body: some View {
        if session.isRunning {
            Text("LOGGING \(elapsedText) · \(session.clicks) clicks · \(session.proxyFrames) frames · \(mb(session.proxyBytes))")
            Text("scratch \(scratchText) · disk \(String(format: "%.0f", session.diskFreeGB)) GB free")
            Button("Stop logging") { session.stop() }
        } else {
            Text("Not logging · disk \(String(format: "%.0f", session.diskFreeGB)) GB free")
            Button("Start logging") { session.start() }.disabled(session.selectedDisplay == nil)
        }
        if let e = session.lastError { Text(e) }
        Divider()
        Picker("Program display", selection: $session.selectedDisplayID) {
            ForEach(session.displays) { d in Text(d.label).tag(Optional(d.id)) }
        }
        .disabled(session.isRunning)
        Picker("Scratch input", selection: $session.selectedAudioUID) {
            ForEach(session.audioDevices) { d in Text(d.name).tag(Optional(d.uid)) }
        }
        .disabled(session.isRunning)
        Toggle("Record scratch audio", isOn: $session.recordScratch).disabled(session.isRunning)
        Button("Rescan displays and inputs") { Task { await session.refreshDisplays(); session.refreshAudio() } }
        Divider()
        Text("Sessions: \(session.outputBase.path)")
        Button("Open sessions folder") { NSWorkspace.shared.open(session.folder ?? session.outputBase) }
        Button("Choose sessions folder…") { chooseFolder() }.disabled(session.isRunning)
        Toggle("Launch at login", isOn: Binding(get: { session.launchAtLogin }, set: { session.launchAtLogin = $0 }))
        if !session.consents.screen || !session.consents.input || (!session.consents.microphone && session.recordScratch) {
            Divider()
            if !session.consents.screen { Text("Screen Recording not granted: the proxy cannot record") }
            if !session.consents.input { Text("Input Monitoring not granted: clicks cannot be logged") }
            if !session.consents.microphone && session.recordScratch { Text("Microphone not granted: the scratch track will be silent") }
            Button("Open Privacy & Security") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy")!)
            }
            Button("Re-check consents") { session.recheckConsents() }
        }
        Divider()
        Text("ARC Slide Log \(Session.version)")
        Button("Quit ARC Slide Log") { NSApp.terminate(nil) }
    }

    private var elapsedText: String {
        let s = Int(session.elapsed)
        return String(format: "%02d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
    }
    private var scratchText: String {
        guard session.recordScratch else { return "off" }
        return String(format: "%.0f s at %.0f dB", session.audioSeconds, max(-60, session.audioLevelDB))
    }
    private func mb(_ bytes: Int) -> String { String(format: "%.0f MB", Double(bytes) / 1e6) }

    private func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        p.prompt = "Use this folder"
        p.message = "Sessions are written as subfolders here (a show folder's reports/slide-track works too)"
        NSApp.activate(ignoringOtherApps: true)
        if p.runModal() == .OK, let u = p.url { session.outputBase = u }
    }
}

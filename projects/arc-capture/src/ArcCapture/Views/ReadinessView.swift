//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI
import Combine
import AppKit
import ApplicationServices

/// Pre-flight the operator can read at a glance: what is ready on this Mac
/// and what to do about anything that is not. Re-checked every few seconds.
@MainActor @Observable final class Readiness {
    struct Check: Identifiable {
        let id: String; let ok: Bool; let label: String; let hint: String; let required: Bool
        /// A button on the row that fixes the thing (SIGN IN, OPEN), when there is one.
        var action: (title: String, run: @MainActor () -> Void)? = nil
    }
    var checks: [Check] = []
    var presenterRunning = false
    var googleBusy = false
    var googleMessage = ""

    func refresh() {
        let screen = CGPreflightScreenCaptureAccess()
        let ax = AXIsProcessTrusted()
        let displays = NSScreen.screens.count
        let ppt = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.Powerpoint") != nil
        let key = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Keynote") != nil
        let chrome = FileManager.default.isExecutableFile(atPath: GoogleSlidesDriver.chromeBinary)
        let profile = GoogleSlidesDriver.profileIsSignedIn
        // Built one append at a time: the closures in the action tuples push a
        // single array literal past what the type checker will resolve.
        var list: [Check] = []
        list.append(Check(id: "screen", ok: screen, label: "SCREEN RECORDING", hint: screen ? "granted" : "System Settings > Privacy & Security > Screen & System Audio Recording: switch on ARC Capture", required: true))
        list.append(Check(id: "ax", ok: ax, label: "ACCESSIBILITY", hint: ax ? "granted" : "System Settings > Privacy & Security > Accessibility: switch on ARC Capture", required: true))
        // Two displays is not enough on its own: the second one may be ARC Presenter's PROGRAM or confidence output,
        // and the show is never put on a display the room sees; it lands on THIS one (2026-09-19, the operator: "why did it
        // put the preso window in the control display?").
        let target = ShowWindowPlacement.targetScreen()
        let onConsole = displays > 1 && (target.screen == nil || target.screen == NSScreen.screens.first)
        list.append(Check(id: "display", ok: displays > 1 && !onConsole, label: "SECOND DISPLAY",
                          hint: displays <= 1 ? "one display only: the show would cover this window; add a display or an HDMI dummy plug"
                              : (onConsole ? "the second display is ARC Presenter's output, so the show will play on THIS display and cover the console: quit Presenter or set its PGM to NOT SET" : "the show plays there, this window stays here"),
                          required: false))
        // Automation: the consent PowerPoint's first Apple Event would otherwise ask for mid-capture. Asked for
        // at launch (LaunchPermissions); GRANT asks again, SETTINGS when it was refused (consent is asked once).
        for t in AutomationPermission.all where AutomationPermission.appURL(t) != nil {
            let s = AutomationPermission.current(t)
            let hint: String = switch s {
            case .granted: "granted"
            case .denied: "refused: System Settings > Privacy & Security > Automation > ARC Capture: switch on \(t.name)"
            case .notRunning: "not asked yet: GRANT opens \(t.name) hidden and asks now, not during your first capture"
            default: "not asked yet: GRANT asks now, not during your first capture"
            }
            var c = Check(id: "ae.\(t.id)", ok: s == .granted, label: "CONTROL " + t.name.replacingOccurrences(of: "Microsoft ", with: "").uppercased(), hint: hint, required: true)
            if s == .denied { c.action = ("SETTINGS", { AutomationPermission.openSettings() }) }
            else if s != .granted { c.action = ("GRANT", { [weak self] in Task { _ = await AutomationPermission.request(t); self?.refresh() } }) }
            list.append(c)
        }
        // ffmpeg and ffprobe measure and conform every movie, sound and animated image in a deck. The public
        // build bundles neither, so the row names the fix. Both must sit in the same folder (ffmpegURL).
        let ff = PPTXAnalyzer.ffmpegURL
        list.append(Check(id: "ffmpeg", ok: ff != nil, label: "FFMPEG",
                          hint: ff.map { "found at \($0.deletingLastPathComponent().path)" }
                              ?? "not found: install your own ffmpeg and ffprobe (Homebrew: brew install ffmpeg), then this row turns green",
                          required: true))
        list.append(Check(id: "ppt", ok: ppt, label: "POWERPOINT", hint: ppt ? "installed" : "not installed: .pptx decks cannot be captured on this Mac", required: false))
        list.append(Check(id: "key", ok: key, label: "KEYNOTE", hint: key ? "installed" : "not installed: .key decks cannot be captured on this Mac", required: false))
        // Google Slides needs both; neither is required for .pptx/.key/.pdf work.
        // There is no app-level Google sign-in any more: the deck is read out of
        // the present page in this profile's own browser session, so signing the
        // PROFILE in once is the whole setup.
        list.append(Check(id: "chrome", ok: chrome, label: "GOOGLE CHROME", hint: chrome ? "installed" : "not installed: Google Slides links need Chrome (google.com/chrome)", required: false))
        var pcheck = Check(id: "profile", ok: profile, label: "CHROME PROFILE",
                           hint: profile ? "signed in: Google Slides links will open" : "OPEN, then sign in once with the Google account the decks are shared to",
                           required: false)
        pcheck.action = ("OPEN", { GoogleSlidesDriver.openProfileForSignIn() })
        list.append(pcheck)
        list.append(Check(id: "presenter", ok: presenterRunning, label: "ARC PRESENTER", hint: presenterRunning ? "running, finished decks open there" : "not running: the deck is written to disk, open it in Presenter yourself", required: false))
        checks = list
        Task {
            var req = URLRequest(url: URL(string: "http://localhost:8760/state")!); req.timeoutInterval = 1
            let running = (try? await URLSession.shared.data(for: req)) != nil
            if running != presenterRunning { presenterRunning = running; refresh() }
        }
    }

    var allRequiredOK: Bool { checks.filter(\.required).allSatisfy(\.ok) }
    /// The Automation rows as one: every installed target granted.
    var automation: Check? {
        let rows = checks.filter { $0.id.hasPrefix("ae.") }
        guard !rows.isEmpty else { return nil }
        let refused = rows.contains { $0.hint.hasPrefix("refused") }
        return Check(id: "automation", ok: rows.allSatisfy(\.ok), label: "AUTOMATION",
                     hint: rows.map { "\($0.label): \($0.hint)" }.joined(separator: "\n") + (refused ? "\nREFUSED" : ""), required: true)
    }
}

struct ReadinessView: View {
    @Bindable var readiness: Readiness
    private let ticker = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(readiness.checks) { c in
                HStack(alignment: .top, spacing: 8) {
                    Circle().fill(c.ok ? ARCTheme.readyGreen : (c.required ? ARCTheme.liveRed : ARCTheme.warn)).frame(width: 9, height: 9).padding(.top, 3)
                    Text(c.label).font(ARCTheme.mono(11, .heavy)).foregroundStyle(ARCTheme.textPrimary).frame(width: 150, alignment: .leading)
                    Text(c.hint).font(ARCTheme.mono(11, .regular)).foregroundStyle(c.ok ? ARCTheme.textSecondary : ARCTheme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let a = c.action {
                        Spacer(minLength: 4)
                        Button(a.title) { a.run() }
                            .font(ARCTheme.mono(10, .heavy))
                            .buttonStyle(.bordered).controlSize(.small)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { readiness.refresh() }
        .onReceive(ticker) { _ in readiness.refresh() }
    }
}

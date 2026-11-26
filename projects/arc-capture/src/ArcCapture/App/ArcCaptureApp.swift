//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI
import AppKit

/// Headless launches (--headless on the command line) hand off to
/// HeadlessRunner as soon as the app has finished launching: accessory
/// policy, no window, a report and an exit code. Everything else is the
/// normal windowed app.
final class ArcCaptureAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if HeadlessRunner.isRequested {
            Task { @MainActor in HeadlessRunner.start() }
        } else {
            // Every consent and switch asked for now, while the operator is setting up, never mid-capture.
            Task { @MainActor in await LaunchPermissions.run { CaptureLaunch.readiness.refresh() } }
        }
    }
}

@main
struct ArcCaptureApp: App {
    @NSApplicationDelegateAdaptor(ArcCaptureAppDelegate.self) private var delegate
    @State private var session = CaptureSession()
    @State private var show = ShowModel()
    /// The tab you were on is the tab you come back to (a relaunch used to land on CAPTURE with a show open in SHOW).
    @AppStorage("lastTab") private var tab = 0

    init() {
        // `--audio-offset MS` on any launch: a diagnostic, default off (AVSyncCalibration). Not a command.
        if let ms = AVSyncCalibration.applyLaunchArgument() { DebugLog.log("App", "audio offset set to \(Int(ms)) ms for this machine") }
        // A headless run never restores windows. After a crash macOS asks "reopen its windows?" at the next launch,
        // a modal nobody sees in a headless run: two crashed runs wedged every later one at launch (2026-09-17).
        if HeadlessRunner.isRequested {
            var args = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
            args["ApplePersistenceIgnoreState"] = true
            args["NSQuitAlwaysKeepsWindows"] = false
            UserDefaults.standard.setVolatileDomain(args, forName: UserDefaults.argumentDomain)
        }
        // `--tab capture|show` and `--window X,Y,W,H` on a GUI launch: the screen and the frame to start on,
        // for shots and tests (a CGEvent click lands on whichever app is frontmost; this does not).
        let a = CommandLine.arguments
        if let i = a.firstIndex(of: "--tab"), i + 1 < a.count { UserDefaults.standard.set(["capture": 0, "show": 1, "review": 2][a[i + 1].lowercased()] ?? 0, forKey: "lastTab") }
        if let i = a.firstIndex(of: "--window"), i + 1 < a.count {
            let v = a[i + 1].split(separator: ",").compactMap { Double($0) }
            if v.count == 4 { CaptureWindowSizing.requestedFrame = CGRect(x: v[0], y: v[1], width: v[2], height: v[3]) }
        }
        // `--deck PATH [--begin]`: applied by the setup screen when it appears (an App struct is made more than
        // once at launch; the session touched here is not always the one the scene shows).
        if let i = a.firstIndex(of: "--deck"), i + 1 < a.count {
            CaptureLaunch.deck = URL(fileURLWithPath: (a[i + 1] as NSString).expandingTildeInPath)
            CaptureLaunch.begin = a.contains("--begin")
        }
        DebugLog.clear()
        DebugLog.log("App", "ARC Capture launched\(HeadlessRunner.isRequested ? " (headless)" : "")")
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if HeadlessRunner.isWatch, let s = HeadlessRunner.watch.session {
                    // --watch: the headless run with the monitor window.
                    CaptureMonitorView(session: s)
                } else if HeadlessRunner.isRequested {
                    // Never shown: the delegate closes it and drops to accessory
                    // policy. It exists because a SwiftUI App must have a scene.
                    Color.clear.frame(width: 1, height: 1)
                } else {
                    VStack(spacing: 0) {
                        // CAPTURE | SHOW (2026-09-12: "a folder navigator and edit tab separate from the capture tab").
                        CaptureTabStrip(tab: $tab, reviewOpen: ShowFolderStore.current?.review.open.count ?? 0)
                            .onReceive(NotificationCenter.default.publisher(for: ShowRouting.openShow)) { _ in tab = 1 }
                            .onReceive(NotificationCenter.default.publisher(for: ShowRouting.openReview)) { _ in tab = 2 }
                        ARCTheme.divider.frame(height: 1)
                        if tab == 2 {
                            ReviewTabView()
                        } else if tab == 1 {
                            // V3: the show FOLDER (versioned items, late changes); the
                            // old browse-and-stack builder lives on as BUILD STACK.
                            ShowFolderView()
                        } else {
                            switch session.state {
                            case .idle:
                                CaptureSetupView(session: session)
                            case .complete:
                                CaptureCompleteView(session: session)
                            case .error:
                                CaptureErrorView(session: session)
                            default:
                                CaptureMonitorView(session: session)
                            }
                        }
                    }
                }
            }
            .frame(minWidth: HeadlessRunner.isRequested ? nil : ARCTheme.windowMinW, minHeight: HeadlessRunner.isRequested ? nil : ARCTheme.windowMinH)
            .measuresCaptureLayout()      // compact or roomy, decided once for every screen (CaptureLayout)
            .preferredColorScheme(.dark)
            .onAppear { if !HeadlessRunner.isRequested { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { CaptureWindowSizing.enforce() } } }
            .onChange(of: tab) { _, _ in CaptureWindowSizing.enforce() }
        }
        .windowStyle(.titleBar)
        // A first launch opens roomy; CaptureWindowSizing fits it (and any restored frame) to the screen.
        .defaultSize(width: ARCTheme.roomyW, height: ARCTheme.roomyH)
        .commands {
            // The About box names the maker and the license (ARCCredit), not the stock panel alone.
            CommandGroup(replacing: .appInfo) { Button("About ARC Capture") { ARCCredit.showAbout() } }
            CommandMenu("Windows") {
                Button("Capture Options…") { toggleWindow(CaptureWindows.options) }.keyboardShortcut("o", modifiers: [.command, .option])
                Button("Readiness…") { toggleWindow(CaptureWindows.readiness) }.keyboardShortcut("r", modifiers: [.command, .option])
                Button("Ask for Permissions Again") { Task { await LaunchPermissions.run { CaptureLaunch.readiness.refresh() } } }
                Button("Capture Log…") { toggleWindow(CaptureWindows.log) }.keyboardShortcut("l", modifiers: [.command, .option])
            }
        }

        // The control windows behind the expand glyphs (docs/PLAN_capture_gui.md).
        Window(CaptureWindows.options.title, id: CaptureWindows.options.id) { OptionsWindowView(session: session).preferredColorScheme(.dark) }
            .windowResizability(.contentSize)
        Window(CaptureWindows.readiness.title, id: CaptureWindows.readiness.id) { ReadinessWindowView(readiness: CaptureLaunch.readiness).preferredColorScheme(.dark) }
            .windowResizability(.contentSize)
        Window(CaptureWindows.log.title, id: CaptureWindows.log.id) { LogWindowView().preferredColorScheme(.dark) }
    }

    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    private func toggleWindow(_ w: (id: String, title: String)) { ControlWindow.toggle(id: w.id, title: w.title, open: openWindow, dismiss: dismissWindow) }
}

// MARK: - Error View

struct CaptureErrorView: View {
    @Bindable var session: CaptureSession

    var body: some View {
        VStack(spacing: ARCTheme.paddingLarge) {
            Spacer()

            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(ARCTheme.liveRed)

            VStack(spacing: ARCTheme.paddingSmall) {
                Text("CAPTURE ERROR")
                    .font(ARCTheme.headerBar)
                    .foregroundStyle(ARCTheme.textPrimary)

                Text(session.errorMessage ?? "An unknown error occurred.")
                    .font(ARCTheme.bodyText)
                    .foregroundStyle(ARCTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, ARCTheme.paddingLarge)
            }

            Spacer()

            Button(action: {
                session.reset()
            }) {
                Text("TRY AGAIN")
                    .font(ARCTheme.statusBadge)
                    .foregroundStyle(ARCTheme.textPrimary)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(ARCTheme.accent.opacity(0.2))
                    .clipShape(RoundedRectangle(cornerRadius: ARCTheme.cornerRadius))
                    .overlay(
                        RoundedRectangle(cornerRadius: ARCTheme.cornerRadius)
                            .strokeBorder(ARCTheme.accent)
                    )
            }
            .buttonStyle(.plain)
            .padding(.bottom, ARCTheme.paddingLarge)
        }
        .frame(minWidth: 480, minHeight: 300)
        .background(ARCTheme.background)
    }
}

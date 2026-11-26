//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI
import AppKit
import IOKit.pwr_mgt

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var localMonitor: Any?
    private var sleepAssertionID: IOPMAssertionID = 0
    private var hasSleepAssertion = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            for window in NSApplication.shared.windows where window.title == "Program Output" {
                window.close()
            }
        }

        acquireSleepAssertion()
        installLocalKeyMonitor()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let monitor = localMonitor { NSEvent.removeMonitor(monitor) }
        releaseSleepAssertion()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool { true }

    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            for url in urls {
                ArcPresenterBasicApp.sharedSession.renderTargetSize =
                    ArcPresenterBasicApp.sharedDisplay.renderTargetSize ?? PageCache.maxRenderSize
                _ = ArcPresenterBasicApp.sharedSession.openPDF(url: url)
            }
        }
    }

    // MARK: - Sleep Prevention (always-on while app is running)

    private func acquireSleepAssertion() {
        guard !hasSleepAssertion else { return }
        let reason = "ARC Presenter Basic prevents display sleep during a show" as CFString
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &sleepAssertionID
        )
        if result == kIOReturnSuccess {
            hasSleepAssertion = true
            NSLog("ARC Presenter Basic: display sleep assertion acquired")
        } else {
            NSLog("ARC Presenter Basic: failed to acquire sleep assertion (result=\(result))")
        }
    }

    private func releaseSleepAssertion() {
        guard hasSleepAssertion else { return }
        IOPMAssertionRelease(sleepAssertionID)
        hasSleepAssertion = false
    }

    // MARK: - Local key monitor (resigns text fields for nav keys)

    private func installLocalKeyMonitor() {
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Tab toggles LIVE/BROWSE when not in a text field
            if event.keyCode == 48,
               event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
               !(event.window?.firstResponder is NSText)
            {
                Task { @MainActor in ArcPresenterBasicApp.sharedSession.toggleMode() }
                return nil
            }

            let navKeys: Set<UInt16> = [123, 124, 125, 126, 116, 121] // ←, →, ↓, ↑, PageUp, PageDown
            if navKeys.contains(event.keyCode),
               let responder = event.window?.firstResponder,
               responder is NSTextView || responder is NSTextField
            {
                event.window?.makeFirstResponder(nil)
            }
            return event
        }
    }
}

@main
struct ArcPresenterBasicApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    static let sharedSession = DeckSession()
    static let sharedDisplay = DisplayManager()

    init() {
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
    }

    var body: some Scene {
        WindowGroup {
            OperatorView()
                .environment(Self.sharedSession)
                .environment(Self.sharedDisplay)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1100, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open PDF…") {
                    NotificationCenter.default.post(name: .openPDF, object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)
                Divider()
            }
            CommandMenu("Presentation") {
                Button("Next Slide") { Task { @MainActor in Self.sharedSession.activeEngine.next() } }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                Button("Previous Slide") { Task { @MainActor in Self.sharedSession.activeEngine.previous() } }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                Button("Next Slide (alt)") { Task { @MainActor in Self.sharedSession.activeEngine.next() } }
                    .keyboardShortcut(.downArrow, modifiers: [])
                Button("Previous Slide (alt)") { Task { @MainActor in Self.sharedSession.activeEngine.previous() } }
                    .keyboardShortcut(.upArrow, modifiers: [])
                Button("Next Slide (PageDown)") { Task { @MainActor in Self.sharedSession.activeEngine.next() } }
                    .keyboardShortcut(.pageDown, modifiers: [])
                Button("Previous Slide (PageUp)") { Task { @MainActor in Self.sharedSession.activeEngine.previous() } }
                    .keyboardShortcut(.pageUp, modifiers: [])
            }
        }

        Window("Program Output", id: "program-output") {
            ProgramOutputView()
                .environment(Self.sharedSession)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1920, height: 1080)
        // Note: SwiftUI's .defaultLaunchBehavior(.suppressed) is macOS 15+ only.
        // We deploy to 14, so we rely on AppDelegate.applicationDidFinishLaunching
        // to close any auto-opened Program Output window 0.3s after launch.
    }
}

extension Notification.Name {
    static let openPDF = Notification.Name("com.example.arc.ArcPresenterBasic.openPDF")
}

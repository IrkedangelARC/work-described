//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI

#if os(iOS)
import UIKit

@Observable
final class ExternalDisplayManager {
    var isConnected = false

    var engine: TimerEngine? {
        didSet {
            if engine != nil, let screen = pendingScreen {
                configureExternalWindow(for: screen)
                pendingScreen = nil
            }
        }
    }

    var stageDirector: StageDirector?
    var displayState: StageDisplayState?

    private var externalWindow: UIWindow?
    private var pendingScreen: UIScreen?

    init() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenDidConnect),
            name: UIScreen.didConnectNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenDidDisconnect),
            name: UIScreen.didDisconnectNotification, object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Returns true if an external screen is currently available
    var hasExternalScreen: Bool {
        UIScreen.screens.count > 1
    }

    /// Manually open the stage display on the external screen.
    /// Call this from the control panel when user enters Extended mode.
    /// Returns true if successfully created external window.
    @discardableResult
    func openOnExternalScreen() -> Bool {
        guard engine != nil, stageDirector != nil, let displayState else { return false }

        // Find external screen (any screen that isn't the main screen)
        guard let externalScreen = UIScreen.screens.first(where: { $0 != UIScreen.main }) else {
            return false
        }

        // Tear down any existing external window first
        tearDownExternalWindow()

        // Pick highest resolution mode
        if let best = externalScreen.availableModes.max(by: {
            $0.size.width * $0.size.height < $1.size.width * $1.size.height
        }) {
            externalScreen.currentMode = best
        }

        // Try scene-based approach first (iPadOS 16+)
        if let scene = findExternalWindowScene() {
            let window = UIWindow(windowScene: scene)
            let stageView = StageDisplayView()
                .environment(displayState)
            let host = UIHostingController(rootView: stageView)
            host.view.backgroundColor = .black
            window.rootViewController = host
            window.isHidden = false
            window.makeKeyAndVisible()
            externalWindow = window
            isConnected = true
            return true
        }

        // Fallback: direct screen assignment (pre-scene approach)
        let window = UIWindow(frame: externalScreen.bounds)
        window.screen = externalScreen

        let stageView = StageDisplayView()
            .environment(displayState)
        let host = UIHostingController(rootView: stageView)
        host.view.backgroundColor = .black

        window.rootViewController = host
        window.isHidden = false

        externalWindow = window
        isConnected = true
        return true
    }

    /// Close the external display window
    func closeExternalDisplay() {
        tearDownExternalWindow()
    }

    // MARK: - Screen Notifications

    @objc private func screenDidConnect(_ note: Notification) {
        guard let screen = note.object as? UIScreen else { return }
        if engine != nil {
            configureExternalWindow(for: screen)
        } else {
            pendingScreen = screen
        }
    }

    @objc private func screenDidDisconnect(_ note: Notification) {
        tearDownExternalWindow()
    }

    // MARK: - Private

    /// Find a UIWindowScene associated with the external display
    private func findExternalWindowScene() -> UIWindowScene? {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            if windowScene.screen != UIScreen.main {
                return windowScene
            }
        }
        return nil
    }

    private func configureExternalWindow(for screen: UIScreen) {
        guard engine != nil, stageDirector != nil, let displayState else { return }

        if let best = screen.availableModes.max(by: {
            $0.size.width * $0.size.height < $1.size.width * $1.size.height
        }) {
            screen.currentMode = best
        }

        let window = UIWindow(frame: screen.bounds)
        window.screen = screen

        let stageView = StageDisplayView()
            .environment(displayState)
        let host = UIHostingController(rootView: stageView)
        host.view.backgroundColor = .black

        window.rootViewController = host
        window.isHidden = false

        externalWindow = window
        isConnected = true
    }

    private func tearDownExternalWindow() {
        externalWindow?.isHidden = true
        externalWindow = nil
        isConnected = false
    }
}

#elseif os(macOS)
import AppKit

@Observable
final class ExternalDisplayManager {
    var isConnected = false

    var engine: TimerEngine?
    var stageDirector: StageDirector?
    var displayState: StageDisplayState?

    init() {
        // Monitor screen configuration changes
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensDidChange),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
        updateConnectionStatus()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Returns true if a secondary screen is available
    var hasExternalScreen: Bool {
        NSScreen.screens.count > 1
    }

    /// Put the stage output on ITS display: the one assigned in the OUTPUTS strip or panel (remembered by
    /// display identity). None assigned: the first display that is not the console's is chosen and recorded,
    /// so the chip shows where it went. It used to be "the first external", whatever was assigned (2026-09-24).
    /// The caller has already asked for the window (`openWindow.output`).
    @discardableResult
    func openOnExternalScreen() -> Bool {
        MainActor.assumeIsolated { ArcStageTimerApp.sharedPlacement.placeWhenOpen(.stage) }
        isConnected = true
        return true
    }

    var isConfidenceActive = false

    func closeExternalDisplay() {
        isConnected = false
    }

    /// Same for the confidence output: its assigned display, never simply the first external.
    @discardableResult
    func openConfidenceOnExternalScreen() -> Bool {
        MainActor.assumeIsolated { ArcStageTimerApp.sharedPlacement.placeWhenOpen(.confidence) }
        isConfidenceActive = true
        return true
    }

    func closeConfidenceDisplay() {
        // The KEY OVERLAY window, found by the one title matcher (a bare "Confidence" would also catch a window
        // titled with the operator's new name for the stage output, CONFIDENCE MONITOR).
        MainActor.assumeIsolated { for w in DisplayPlacement.windows(for: .confidence) { w.close() } }
        isConfidenceActive = false
    }

    // MARK: - Screen Notifications

    @objc private func screensDidChange(_ note: Notification) {
        updateConnectionStatus()
    }

    private func updateConnectionStatus() {
        let hadExternal = isConnected
        let hasExternal = hasExternalScreen
        // If external was removed, mark disconnected
        if hadExternal && !hasExternal {
            isConnected = false
        }
    }
}

#endif

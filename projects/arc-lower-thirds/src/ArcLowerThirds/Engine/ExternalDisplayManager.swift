//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI
import AppKit

@Observable
final class ExternalDisplayManager {
    var isConnected = false
    var isKeyConnected = false
    var engine: GraphicsEngine?

    /// When DeckLink Fill+Key output is active, the Stage Output window must
    /// keep its transparent backdrop even while parked on an external screen.
    weak var deckLink: DeckLinkOutputManager?

    /// Number of external screens available
    var externalScreenCount: Int {
        NSScreen.screens.count - 1  // subtract main screen
    }

    init() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensDidChange),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
        updateConnectionStatus()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    var hasExternalScreen: Bool {
        NSScreen.screens.count > 1
    }

    /// Move the Stage Output (Fill) window to the first external screen
    @discardableResult
    func openOnExternalScreen() -> Bool {
        guard hasExternalScreen else {
            isConnected = false
            return false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.moveWindowToExternalScreen(title: "Stage Output", screenIndex: 0)
            self?.isConnected = true
        }
        return true
    }

    /// Move the Key Output window to the second external screen (or first if only one)
    @discardableResult
    func openKeyOnExternalScreen() -> Bool {
        guard hasExternalScreen else {
            isKeyConnected = false
            return false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            // Use second external if available, otherwise first external
            let screenIndex = self.externalScreenCount > 1 ? 1 : 0
            self.moveWindowToExternalScreen(title: "Key Output", screenIndex: screenIndex)
            self.isKeyConnected = true
        }
        return true
    }

    func closeExternalDisplay() {
        isConnected = false
        isKeyConnected = false
    }

    /// Configure a window as a borderless presentation surface on an external screen.
    /// Uses .screenSaver level to cover the menu bar on external displays.
    private func configureOutputWindow(_ window: NSWindow, on screen: NSScreen) {
        window.styleMask = [.borderless]
        // Don't repaint the fill window opaque black while DeckLink is
        // capturing it — its alpha channel is the ATEM key signal.
        let keepTransparent = deckLink?.isActive == true && window.title.contains("Stage Output")
        window.isOpaque = !keepTransparent
        window.backgroundColor = keepTransparent ? .clear : .black
        window.hasShadow = false
        // screenSaver level sits above the menu bar on external displays
        window.level = NSWindow.Level(Int(CGShieldingWindowLevel()))
        window.collectionBehavior = [.stationary, .canJoinAllSpaces, .ignoresCycle]
        window.setFrame(screen.frame, display: true)
        window.orderFrontRegardless()
    }

    /// Move a window matching the given title to an external screen.
    /// screenIndex 0 = first external, 1 = second external, etc.
    /// Does nothing if no external screen is available — output windows stay windowed.
    private func moveWindowToExternalScreen(title: String, screenIndex: Int) {
        let externals = NSScreen.screens.filter { $0 != NSScreen.main }
        guard screenIndex < externals.count else { return }
        let targetScreen = externals[screenIndex]

        for window in NSApplication.shared.windows where window.title.contains(title) {
            configureOutputWindow(window, on: targetScreen)
            return
        }
    }

    /// Track whether we were connected before a screen change (for auto-recovery)
    private var wasConnected = false
    private var wasKeyConnected = false

    /// User-facing notification message (shown as toast)
    var statusMessage: String?

    @objc private func screensDidChange(_ note: Notification) {
        let hadExternal = wasConnected
        let hadKey = wasKeyConnected
        updateConnectionStatus()

        if !hasExternalScreen && (hadExternal || hadKey) {
            // Display was removed — show stays windowed, notify operator
            statusMessage = "External display disconnected — output continues in window"
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.statusMessage = nil
            }
        } else if hasExternalScreen && !isConnected && hadExternal {
            // Display reappeared — auto-restore
            statusMessage = "External display reconnected — restoring output"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self else { return }
                self.openOnExternalScreen()
                if hadKey {
                    self.openKeyOnExternalScreen()
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                self?.statusMessage = nil
            }
        }
    }

    private func updateConnectionStatus() {
        wasConnected = isConnected
        wasKeyConnected = isKeyConnected
        let hasExternal = hasExternalScreen
        if !hasExternal {
            isConnected = false
            isKeyConnected = false
        }
    }
}

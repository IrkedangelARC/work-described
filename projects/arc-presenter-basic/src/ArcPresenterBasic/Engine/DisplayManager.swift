//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI
import AppKit
import os

private let log = OSLog(subsystem: "com.example.arc.ArcPresenterBasic", category: "display")

struct ScreenIdentity: Identifiable, Equatable, Hashable {
    let id: CGDirectDisplayID
    let index: Int
    let localizedName: String
    let frame: CGRect
    let isBuiltIn: Bool

    var resolution: String { "\(Int(frame.width)) × \(Int(frame.height))" }

    static func from(_ screen: NSScreen, index: Int) -> ScreenIdentity? {
        guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            return nil
        }
        let isBuiltIn = CGDisplayIsBuiltin(id) != 0
        return ScreenIdentity(
            id: id,
            index: index,
            localizedName: screen.localizedName,
            frame: screen.frame,
            isBuiltIn: isBuiltIn
        )
    }
}

@MainActor
@Observable
final class DisplayManager {
    static let programWindowTitle = "Program Output"

    var statusMessage: String?

    private(set) var availableScreens: [ScreenIdentity] = []
    var programScreenID: CGDirectDisplayID?
    private(set) var isProgramConnected = false

    /// Set by OperatorView so DisplayManager can ask SwiftUI to instantiate
    /// the program window scene during sleep/wake/HDMI-replug recovery.
    /// Without this, openOutput can only find an already-existing window;
    /// after macOS closes the window during sleep, it would silently fail.
    var requestProgramWindow: (() -> Void)?

    private var wasProgramConnected = false
    private var previousProgramID: CGDirectDisplayID?
    private var hasPendingRecovery = false
    private var escapeMonitor: Any?

    var hasExternalScreen: Bool { availableScreens.contains { !$0.isBuiltIn } }
    var externalScreens: [ScreenIdentity] { availableScreens.filter { !$0.isBuiltIn } }

    var programScreen: ScreenIdentity? {
        guard let id = programScreenID else { return nil }
        return availableScreens.first { $0.id == id }
    }

    var programScreenFrame: CGRect? { programScreen?.frame }

    /// Largest connected screen size, used as the page cache render target
    var renderTargetSize: CGSize? {
        if let frame = programScreenFrame { return frame.size }
        return externalScreens.first?.frame.size
    }

    init() {
        detectScreens()
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensDidChange),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(systemWillSleep),
            name: NSWorkspace.willSleepNotification, object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification, object: nil
        )
    }

    nonisolated deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func detectScreens() {
        availableScreens = NSScreen.screens.enumerated().compactMap { index, screen in
            ScreenIdentity.from(screen, index: index)
        }
        os_log("detectScreens: %d screens, %d external", log: log, type: .info,
               availableScreens.count, externalScreens.count)
    }

    func assign(_ screen: ScreenIdentity) {
        programScreenID = screen.id
    }

    func unassign() {
        if isProgramConnected { closeOutput() }
        programScreenID = nil
    }

    func autoAssignFirstExternal() {
        if programScreenID == nil, let first = externalScreens.first {
            programScreenID = first.id
        }
    }

    @discardableResult
    func openOutput() -> Bool {
        guard let target = resolveTarget() else {
            os_log("openOutput: no target screen available", log: log, type: .error)
            return false
        }
        os_log("openOutput: target=%{public}@ (%{public}@)", log: log, type: .info,
               target.localizedName, target.resolution)

        // Ask SwiftUI to instantiate the window scene if needed
        requestProgramWindow?()

        // Poll for the window — SwiftUI may not have created it yet
        Task { @MainActor in
            await positionWindowWhenReady(target: target, deadlineSeconds: 2.0)
        }
        return true
    }

    func closeOutput() {
        for window in NSApplication.shared.windows where window.title == Self.programWindowTitle {
            window.level = .normal
            window.orderOut(nil)
        }
        isProgramConnected = false
        NSApp.presentationOptions = []
        removeEscapeMonitor()
        os_log("closeOutput: window hidden", log: log, type: .info)
    }

    private func resolveTarget() -> ScreenIdentity? {
        if let id = programScreenID { return availableScreens.first { $0.id == id } }
        return externalScreens.first
    }

    private func findProgramWindow() -> NSWindow? {
        NSApplication.shared.windows.first { $0.title == Self.programWindowTitle }
    }

    /// Poll for the program window every 100ms up to `deadlineSeconds`. Once found,
    /// configure and position it on the target screen. Robust against SwiftUI
    /// being slow to materialize the scene under load or after wake.
    private func positionWindowWhenReady(target: ScreenIdentity, deadlineSeconds: Double) async {
        let interval: UInt64 = 100_000_000 // 100ms
        let maxAttempts = Int(deadlineSeconds * 10)

        for attempt in 0..<maxAttempts {
            if let window = findProgramWindow() {
                positionWindow(window, on: target)
                isProgramConnected = true
                installEscapeMonitor()
                refocusOperatorWindow()
                os_log("openOutput: window positioned on attempt %d", log: log, type: .info, attempt + 1)
                return
            }
            try? await Task.sleep(nanoseconds: interval)
        }
        os_log("openOutput: window not found after %.1fs — output may not be visible", log: log, type: .error, deadlineSeconds)
        isProgramConnected = false
    }

    private func positionWindow(_ window: NSWindow, on target: ScreenIdentity) {
        let nsScreen = NSScreen.screens.first { screen in
            guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return false }
            return displayID == target.id
        }
        guard let nsScreen else {
            os_log("positionWindow: NSScreen not found for displayID=%u", log: log, type: .error, target.id)
            return
        }
        window.styleMask = [.borderless]
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = false
        window.level = NSWindow.Level(Int(CGShieldingWindowLevel()))
        window.collectionBehavior = [.stationary, .canJoinAllSpaces, .ignoresCycle]
        window.setFrame(nsScreen.frame, display: true)
        window.orderFrontRegardless()
        NSApp.presentationOptions = [.autoHideMenuBar, .autoHideDock]
    }

    private func refocusOperatorWindow() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            for window in NSApplication.shared.windows
                where window.isVisible
                    && window.title != Self.programWindowTitle
                    && window.contentView != nil
            {
                window.makeKeyAndOrderFront(nil)
                break
            }
        }
    }

    private func installEscapeMonitor() {
        removeEscapeMonitor()
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                self?.closeOutput()
                return nil
            }
            return event
        }
    }

    private func removeEscapeMonitor() {
        if let monitor = escapeMonitor {
            NSEvent.removeMonitor(monitor)
            escapeMonitor = nil
        }
    }

    // MARK: - Sleep / Wake

    @objc private func systemWillSleep(_ note: Notification) {
        // Capture state for restore. Don't overwrite if a recovery is already
        // pending (e.g. HDMI unplug right before sleep).
        if !hasPendingRecovery {
            wasProgramConnected = isProgramConnected
            previousProgramID = programScreenID
            hasPendingRecovery = isProgramConnected
        }
        statusMessage = "System sleeping, output paused"
        os_log("systemWillSleep: wasConnected=%{public}@ pendingRecovery=%{public}@",
               log: log, type: .info,
               wasProgramConnected.description, hasPendingRecovery.description)
    }

    @objc private func systemDidWake(_ note: Notification) {
        os_log("systemDidWake: pendingRecovery=%{public}@", log: log, type: .info, hasPendingRecovery.description)
        // Delay screen detection: macOS needs ~2s to re-init external displays
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self else { return }
            self.detectScreens()
            if self.hasPendingRecovery,
               let prevID = self.previousProgramID,
               self.availableScreens.contains(where: { $0.id == prevID }) {
                self.programScreenID = prevID
                self.openOutput()
                self.statusMessage = "System woke, restoring output"
                os_log("systemDidWake: restored output on screen %u", log: log, type: .info, prevID)
            } else if self.hasPendingRecovery {
                self.statusMessage = "Display not reconnected after wake"
                os_log("systemDidWake: previous display not available", log: log, type: .error)
            } else {
                self.statusMessage = nil
            }
            self.hasPendingRecovery = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                self?.statusMessage = nil
            }
        }
    }

    // MARK: - Screen Changes

    @objc private func screensDidChange(_ note: Notification) {
        // Capture state once per recovery cycle. If multiple changes fire (e.g.
        // unplug + replug fast), keep the original wasConnected state — don't
        // let "we're disconnected right now" overwrite "output WAS active".
        if !hasPendingRecovery {
            wasProgramConnected = isProgramConnected
            previousProgramID = programScreenID
            hasPendingRecovery = isProgramConnected
        }

        detectScreens()

        // Currently-assigned screen vanished
        if let id = programScreenID, !availableScreens.contains(where: { $0.id == id }) {
            programScreenID = nil
            isProgramConnected = false
            os_log("screensDidChange: assigned screen %u disappeared", log: log, type: .info, id)
        }

        if !hasExternalScreen && wasProgramConnected {
            isProgramConnected = false
            statusMessage = "External display disconnected"
            os_log("screensDidChange: all externals gone", log: log, type: .info)
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.statusMessage = nil
            }
            // Keep hasPendingRecovery=true so a future replug restores
        } else if hasExternalScreen && wasProgramConnected {
            // Try to restore on the original screen if still attached
            if let prevID = previousProgramID, availableScreens.contains(where: { $0.id == prevID }) {
                programScreenID = prevID
                statusMessage = "Display reconnected, restoring output"
                os_log("screensDidChange: restoring on previous screen %u", log: log, type: .info, prevID)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.openOutput()
                    self?.hasPendingRecovery = false
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                    self?.statusMessage = nil
                }
            } else if let firstExternal = externalScreens.first {
                // Original screen gone but a different external is present
                programScreenID = firstExternal.id
                statusMessage = "Reattaching to \(firstExternal.localizedName)"
                os_log("screensDidChange: original screen gone, falling back to %{public}@", log: log, type: .info, firstExternal.localizedName)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.openOutput()
                    self?.hasPendingRecovery = false
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                    self?.statusMessage = nil
                }
            }
        }
    }
}

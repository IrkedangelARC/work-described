//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import AppKit
import CoreGraphics

/// v2: Display enumeration, control screen protection, and accessibility checks.
/// OBS handles video routing. WindowManager protects the control screen from
/// presentation apps that would otherwise put presenter view or slideshows on it.
@Observable
final class WindowManager {

    /// The control screen's stable display ID (the screen ARC Switcher runs on).
    /// Presentations must never appear here.
    private(set) var controlDisplayID: CGDirectDisplayID?

    /// Currently captured display IDs (for release after presentation starts).
    private var capturedDisplays: [CGDirectDisplayID] = []

    // MARK: - Control Screen

    /// Detect and lock the control screen — the display ARC Switcher's window is on.
    func detectControlScreen() {
        if let window = NSApp.mainWindow ?? NSApp.windows.first,
           let screen = window.screen {
            controlDisplayID = screen.displayID
            print("[WindowManager] Control screen: \(screen.localizedName) (displayID=\(screen.displayID))")
        } else {
            // Fallback: use the main screen
            controlDisplayID = NSScreen.main?.displayID
        }
    }

    /// Manually set the control screen.
    func setControlScreen(_ screen: NSScreen) {
        controlDisplayID = screen.displayID
    }

    var controlScreen: NSScreen? {
        guard let id = controlDisplayID else { return nil }
        return NSScreen.screens.first { $0.displayID == id }
    }

    // MARK: - Display Capture (Control Screen Protection)

    /// Capture the control screen so presentation apps can't see it.
    /// Apps will only see remaining displays (output + any others).
    /// Call this BEFORE starting a presentation, then release after it starts.
    func captureControlScreen() {
        guard let controlID = controlDisplayID else { return }
        guard !capturedDisplays.contains(controlID) else { return }

        if CGDisplayCapture(controlID) == .success {
            capturedDisplays.append(controlID)
            print("[WindowManager] Captured control display \(controlID)")
        }
    }

    /// Release all captured displays. Call ~2s after presentation starts.
    func releaseCapturedDisplays() {
        for id in capturedDisplays {
            CGDisplayRelease(id)
        }
        capturedDisplays.removeAll()
    }

    /// Capture control screen, run a closure, then release after a delay.
    /// Standard pattern for starting presentations.
    func withControlScreenCaptured(releaseDelay: TimeInterval = 2.0, action: @escaping () -> Void) {
        captureControlScreen()
        action()
        DispatchQueue.main.asyncAfter(deadline: .now() + releaseDelay) { [weak self] in
            self?.releaseCapturedDisplays()
        }
    }

    // MARK: - Display Enumeration

    /// Available screens for output assignment (maps to OBS monitor indices).
    static var availableScreens: [NSScreen] {
        NSScreen.screens
    }

    /// Get the OBS monitor index for a given screen.
    static func obsMonitorIndex(for screen: NSScreen) -> Int? {
        let screens = NSScreen.screens
        return screens.firstIndex(where: { $0.displayID == screen.displayID })
    }

    /// Get a screen by OBS monitor index.
    static func screen(forMonitorIndex index: Int) -> NSScreen? {
        let screens = NSScreen.screens
        guard index >= 0, index < screens.count else { return nil }
        return screens[index]
    }

    // MARK: - Accessibility Check

    static var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    static func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }
}

// MARK: - NSScreen Display ID

extension NSScreen {
    /// Stable CGDirectDisplayID from the screen's device description.
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) ?? 0
    }

    /// CGDisplay UUID string for OBS screen_capture sources.
    /// Format: "XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX"
    var displayUUID: String? {
        let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue()
        return uuid.flatMap { CFUUIDCreateString(nil, $0) as String? }
    }
}

extension CGDirectDisplayID {
    /// CGDisplay UUID string for this display ID.
    var displayUUID: String? {
        let uuid = CGDisplayCreateUUIDFromDisplayID(self)?.takeRetainedValue()
        return uuid.flatMap { CFUUIDCreateString(nil, $0) as String? }
    }
}

//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation
import AppKit
import CoreServices
import ScreenCaptureKit

/// Automation (Apple Events) consent, asked for at launch instead of in the middle of the first capture.
///
/// The drivers send their Apple Events through an `/usr/bin/osascript` child, but TCC charges them to
/// ARC Capture, the responsible process, so a grant asked for here is the same grant osascript needs.
/// Before 3.2.4 nothing asked: the first `tell application "Microsoft PowerPoint"` of the first run
/// raised "ARC Capture wants access to control Microsoft PowerPoint" mid-capture, after the operator
/// had gone through the whole checklist (field test 2026-09-23).
///
/// macOS only answers for a target that is running: -600 (procNotFound) says nothing about consent.
/// A grant seen once is remembered in UserDefaults so the tile stays green while PowerPoint is closed,
/// and it is re-read (and forgotten if revoked) whenever the target is running.
enum AutomationPermission {
    enum Status: Equatable {
        case granted, denied, notAsked, notRunning, notInstalled
        case other(OSStatus)
    }

    /// The Apple Event targets the drivers use. System Events moves the show window and posts clicks.
    struct Target: Identifiable {
        let id: String            // bundle identifier
        let name: String          // what the prompt calls it
        let appPath: String?      // where to launch it from when it is not a normal app lookup
    }
    static let systemEvents = Target(id: "com.apple.systemevents", name: "System Events", appPath: "/System/Library/CoreServices/System Events.app")
    static let powerPoint = Target(id: "com.microsoft.Powerpoint", name: "Microsoft PowerPoint", appPath: nil)
    static let keynote = Target(id: "com.apple.Keynote", name: "Keynote", appPath: nil)
    static let all = [systemEvents, powerPoint, keynote]

    static func appURL(_ t: Target) -> URL? {
        if let p = t.appPath { return FileManager.default.fileExists(atPath: p) ? URL(fileURLWithPath: p) : nil }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: t.id)
    }

    private static func key(_ t: Target) -> String { "automationGranted.\(t.id)" }
    static func rememberedGrant(_ t: Target) -> Bool { UserDefaults.standard.bool(forKey: key(t)) }

    /// Ask TCC. Blocks while a consent prompt is up when `ask` is true, so never call it on the main thread.
    static func determine(_ t: Target, ask: Bool) -> Status {
        guard appURL(t) != nil else { return .notInstalled }
        let desc = NSAppleEventDescriptor(bundleIdentifier: t.id)
        let err = AEDeterminePermissionToAutomateTarget(desc.aeDesc, typeWildCard, typeWildCard, ask)
        let status: Status
        switch err {
        case noErr: status = .granted
        case OSStatus(errAEEventNotPermitted): status = .denied
        case OSStatus(errAEEventWouldRequireUserConsent): status = .notAsked
        case OSStatus(procNotFound): status = .notRunning
        default: status = .other(err)
        }
        switch status {
        case .granted: UserDefaults.standard.set(true, forKey: key(t))
        case .denied, .notAsked: UserDefaults.standard.removeObject(forKey: key(t))
        default: break
        }
        return status
    }

    /// The readiness answer without a prompt: a running target is asked, a closed one falls back to the remembered grant.
    static func current(_ t: Target) -> Status {
        let s = determine(t, ask: false)
        if s == .notRunning { return rememberedGrant(t) ? .granted : .notRunning }
        return s
    }

    /// Get the prompt on screen now: launch the target hidden if it is closed, then ask.
    /// Returns once the operator has answered (or the target never came up).
    static func request(_ t: Target) async -> Status {
        guard let url = appURL(t) else { return .notInstalled }
        let first = await Task.detached { determine(t, ask: true) }.value
        guard first == .notRunning else { return first }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false; config.hides = true; config.addsToRecentItems = false
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: config)
        // PowerPoint takes seconds to answer Apple Events on a cold launch.
        for _ in 0..<60 {
            let s = await Task.detached { determine(t, ask: true) }.value
            if s != .notRunning { return s }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return .notRunning
    }

    /// The deep link for a denied grant: consent is only ever asked once, after that it is a switch.
    static func openSettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") { NSWorkspace.shared.open(u) }
    }
}

/// Everything ARC Capture needs macOS to agree to, asked for in one pass when the app opens so the first
/// capture is never stopped by a dialog. Each step only prompts when the answer is not already in.
@MainActor enum LaunchPermissions {
    private(set) static var running = false

    static func run(then refresh: @escaping @MainActor () -> Void) async {
        guard !running else { return }
        running = true; defer { running = false; refresh() }
        DebugLog.log("Permissions", "launch pass: begin")

        // 1. Automation: modal consent prompts, one per target, answered here and never again.
        //    Keynote and PowerPoint only when installed; a closed target is launched hidden to be asked.
        for t in AutomationPermission.all where AutomationPermission.appURL(t) != nil {
            let s = AutomationPermission.current(t)
            guard s != .granted else { continue }
            if s == .denied { DebugLog.log("Permissions", "\(t.name): denied earlier, switch it on in Settings"); continue }
            let answer = await AutomationPermission.request(t)
            DebugLog.log("Permissions", "\(t.name): \(answer)")
            refresh()
        }

        // 2. Folders: the output defaults to the Desktop and shows live in Documents/ARC Shows. Listing each
        //    raises its "would like to access files in" prompt now rather than at the first write.
        let fm = FileManager.default
        for dir in [FileManager.SearchPathDirectory.desktopDirectory, .documentDirectory, .downloadsDirectory] {
            if let u = fm.urls(for: dir, in: .userDomainMask).first { _ = try? fm.contentsOfDirectory(atPath: u.path) }
        }

        // 3. Screen Recording and Accessibility: both are switches in System Settings, not answers in a
        //    dialog. Ask once per version (the same rule the capture start uses) so the operator is sent
        //    there now; the READY tiles stay red until they are on.
        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
        } else {
            // Granted: touch ScreenCaptureKit once so any "bypass the private window picker" confirmation
            // comes up here, not when the first slide is being recorded.
            _ = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        }
        if !AXIsProcessTrusted() {
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
            let key = "accessibilityPromptedFor"
            if UserDefaults.standard.string(forKey: key) != version {
                UserDefaults.standard.set(version, forKey: key)
                _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
            }
        }
        DebugLog.log("Permissions", "launch pass: done")
    }
}

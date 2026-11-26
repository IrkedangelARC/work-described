//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import AppKit
import CoreGraphics

/// Defines the capabilities and control methods for a specific application.
///
/// v2: Profiles are navigation-only — no display capture, no window positioning.
/// OBS handles all video routing. Profiles handle app-specific commands
/// (slide navigation, transport, presentation start/stop) via AppleScript or CGEvent.
protocol AppProfile {
    var bundleIdentifier: String { get }
    var displayName: String { get }
    var supportedCommands: Set<AppCommand> { get }

    /// Human-readable hotkey labels for each command (e.g. "AppleScript", "Arrow Key").
    var hotkeyLabels: [AppCommand: String] { get }

    /// Execute a command on the target application.
    func execute(_ command: AppCommand, on app: NSRunningApplication) throws
}

extension AppProfile {
    var hotkeyLabels: [AppCommand: String] { [:] }
}

extension AppProfile {
    /// Send a key code to the frontmost app via CGEvent (requires Accessibility permission only).
    func sendKeyCode(_ code: Int, using modifiers: String? = nil) throws {
        var flags: CGEventFlags = []
        if let modifiers {
            let parts = modifiers.lowercased()
            if parts.contains("command") { flags.insert(.maskCommand) }
            if parts.contains("shift") { flags.insert(.maskShift) }
            if parts.contains("option") || parts.contains("alternate") { flags.insert(.maskAlternate) }
            if parts.contains("control") { flags.insert(.maskControl) }
            if parts.contains("fn") || parts.contains("function") { flags.insert(.maskSecondaryFn) }
        }

        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: false) else {
            throw ProfileError.cgEventFailed
        }

        keyDown.flags = flags
        keyUp.flags = flags
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    /// Send a keystroke (character) to the frontmost app via CGEvent.
    func sendKeystroke(_ key: String, using modifiers: String? = nil) throws {
        guard let code = Self.charToKeyCode[key.lowercased()] else {
            throw ProfileError.unknownKey(key)
        }
        try sendKeyCode(code, using: modifiers)
    }

    /// Run an AppleScript string via osascript subprocess.
    func runAppleScript(_ script: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMsg = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown error"
            throw ProfileError.appleScriptFailed(errorMsg)
        }
    }

    private static var charToKeyCode: [String: Int] {
        ["a": 0, "b": 11, "c": 8, "d": 2, "e": 14, "f": 3, "g": 5, "h": 4,
         "i": 34, "j": 38, "k": 40, "l": 37, "m": 46, "n": 45, "o": 31, "p": 35,
         "q": 12, "r": 15, "s": 1, "t": 17, "u": 32, "v": 9, "w": 13, "x": 7,
         "y": 16, "z": 6, " ": 49, "\t": 48]
    }
}

enum ProfileError: LocalizedError {
    case appleScriptFailed(String)
    case unsupportedCommand(AppCommand)
    case cgEventFailed
    case unknownKey(String)

    var errorDescription: String? {
        switch self {
        case .appleScriptFailed(let msg): "AppleScript error: \(msg)"
        case .unsupportedCommand(let cmd): "Command not supported: \(cmd.displayName)"
        case .cgEventFailed: "Failed to create keyboard event"
        case .unknownKey(let key): "Unknown key: \(key)"
        }
    }
}

//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import AppKit

struct KeynoteProfile: AppProfile {
    /// Keynote Creator Studio (v15+) uses com.apple.Keynote; legacy Keynote uses com.apple.iWork.Keynote.
    let bundleIdentifier = "com.apple.Keynote"
    static let legacyBundleIdentifier = "com.apple.iWork.Keynote"
    let displayName = "Keynote"
    let supportedCommands: Set<AppCommand> = [
        .nextSlide, .previousSlide, .startPresentation, .stopPresentation
    ]
    let hotkeyLabels: [AppCommand: String] = [
        .startPresentation: "AppleScript",
        .stopPresentation: "AppleScript",
        .nextSlide: "AppleScript",
        .previousSlide: "AppleScript"
    ]

    /// All commands use AppleScript — focus-free, ARC Switcher stays in foreground.
    /// OBS captures the slideshow window — presenter view is irrelevant.
    func execute(_ command: AppCommand, on app: NSRunningApplication) throws {
        switch command {
        case .nextSlide:
            try runAppleScript("""
                tell application "Keynote"
                    if playing then show next
                end tell
                """)
        case .previousSlide:
            try runAppleScript("""
                tell application "Keynote"
                    if playing then show previous
                end tell
                """)
        case .startPresentation:
            // Start slideshow — Keynote routes to configured display
            try runAppleScript("""
                tell application "Keynote"
                    start front document
                end tell
                """)
        case .stopPresentation:
            try runAppleScript("""
                tell application "Keynote"
                    if playing then stop the front slideshow
                end tell
                """)
        default:
            throw ProfileError.unsupportedCommand(command)
        }
    }
}

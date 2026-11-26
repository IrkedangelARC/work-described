//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import AppKit

struct PowerPointProfile: AppProfile {
    let bundleIdentifier = "com.microsoft.Powerpoint"
    let displayName = "PowerPoint"
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
    /// OBS captures the slideshow window directly — no display capture needed.
    func execute(_ command: AppCommand, on app: NSRunningApplication) throws {
        switch command {
        case .nextSlide:
            try runAppleScript("""
                tell application "Microsoft PowerPoint"
                    go to next slide of slide show view of slide show window 1
                end tell
                """)
        case .previousSlide:
            try runAppleScript("""
                tell application "Microsoft PowerPoint"
                    go to previous slide of slide show view of slide show window 1
                end tell
                """)
        case .startPresentation:
            // Speaker mode — OBS captures the slideshow window
            try runAppleScript("""
                tell application "Microsoft PowerPoint"
                    set show type of slide show settings of active presentation to slide show type speaker
                    run slide show slide show settings of active presentation
                end tell
                """)
        case .stopPresentation:
            try runAppleScript("""
                tell application "Microsoft PowerPoint"
                    exit slide show slide show view of slide show window 1
                end tell
                """)
        default:
            throw ProfileError.unsupportedCommand(command)
        }
    }
}

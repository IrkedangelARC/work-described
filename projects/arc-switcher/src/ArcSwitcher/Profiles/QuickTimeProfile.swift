//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import AppKit

struct QuickTimeProfile: AppProfile {
    let bundleIdentifier = "com.apple.QuickTimePlayerX"
    let displayName = "QuickTime"
    let supportedCommands: Set<AppCommand> = [
        .play, .pause, .stop
    ]

    func execute(_ command: AppCommand, on app: NSRunningApplication) throws {
        switch command {
        case .play:
            try runAppleScript("""
                tell application "QuickTime Player"
                    play the front document
                end tell
                """)
        case .pause:
            try runAppleScript("""
                tell application "QuickTime Player"
                    pause the front document
                end tell
                """)
        case .stop:
            try runAppleScript("""
                tell application "QuickTime Player"
                    stop the front document
                end tell
                """)
        default:
            throw ProfileError.unsupportedCommand(command)
        }
    }
}

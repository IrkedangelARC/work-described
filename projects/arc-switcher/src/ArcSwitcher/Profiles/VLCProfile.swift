//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import AppKit

struct VLCProfile: AppProfile {
    let bundleIdentifier = "org.videolan.vlc"
    let displayName = "VLC"
    let supportedCommands: Set<AppCommand> = [
        .play, .pause, .stop, .volumeUp, .volumeDown, .mute
    ]

    func execute(_ command: AppCommand, on app: NSRunningApplication) throws {
        switch command {
        case .play, .pause:
            try runAppleScript("""
                tell application "VLC" to play
                """)
        case .stop:
            try runAppleScript("""
                tell application "VLC" to stop
                """)
        case .volumeUp:
            try runAppleScript("""
                tell application "VLC"
                    set sound volume to (sound volume + 32)
                end tell
                """)
        case .volumeDown:
            try runAppleScript("""
                tell application "VLC"
                    set sound volume to (sound volume - 32)
                end tell
                """)
        case .mute:
            try runAppleScript("""
                tell application "VLC" to mute
                """)
        default:
            throw ProfileError.unsupportedCommand(command)
        }
    }
}

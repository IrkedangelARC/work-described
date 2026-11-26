//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import AppKit

/// Fallback profile for unrecognized applications. No app-specific commands.
struct GenericProfile: AppProfile {
    let bundleIdentifier: String
    let displayName: String
    let supportedCommands: Set<AppCommand> = []

    func execute(_ command: AppCommand, on app: NSRunningApplication) throws {
        throw ProfileError.unsupportedCommand(command)
    }
}

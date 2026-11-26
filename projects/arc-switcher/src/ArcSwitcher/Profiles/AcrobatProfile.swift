//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import AppKit

struct AcrobatProfile: AppProfile {
    let bundleIdentifier = "com.adobe.Acrobat.Pro"
    let displayName = "Acrobat"
    let supportedCommands: Set<AppCommand> = [
        .nextSlide, .previousSlide, .startPresentation, .stopPresentation
    ]
    let hotkeyLabels: [AppCommand: String] = [
        .startPresentation: "⌘⇧H",
        .stopPresentation: "Esc",
        .nextSlide: "↓",
        .previousSlide: "↑"
    ]

    func execute(_ command: AppCommand, on app: NSRunningApplication) throws {
        app.activate()
        switch command {
        case .nextSlide:
            try sendKeyCode(125) // Down Arrow (next page)
        case .previousSlide:
            try sendKeyCode(126) // Up Arrow (previous page)
        case .startPresentation:
            // Cmd+Shift+H enters full screen reading mode
            try sendKeyCode(4, using: "command down, shift down") // H
        case .stopPresentation:
            try sendKeyCode(53) // Escape
        default:
            throw ProfileError.unsupportedCommand(command)
        }
    }
}

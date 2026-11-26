//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import AppKit

struct PreviewProfile: AppProfile {
    let bundleIdentifier = "com.apple.Preview"
    let displayName = "Preview"
    let supportedCommands: Set<AppCommand> = [
        .nextSlide, .previousSlide, .startPresentation, .stopPresentation
    ]
    let hotkeyLabels: [AppCommand: String] = [
        .startPresentation: "⌃⌘F",
        .stopPresentation: "Esc",
        .nextSlide: "↓",
        .previousSlide: "↑"
    ]

    func execute(_ command: AppCommand, on app: NSRunningApplication) throws {
        app.activate()
        switch command {
        case .nextSlide:
            try sendKeyCode(125) // Down Arrow
        case .previousSlide:
            try sendKeyCode(126) // Up Arrow
        case .startPresentation:
            // Ctrl+Cmd+F enters native macOS fullscreen (survives app switches)
            try sendKeyCode(3, using: "command down, control down") // F
        case .stopPresentation:
            try sendKeyCode(53) // Escape
        default:
            throw ProfileError.unsupportedCommand(command)
        }
    }
}

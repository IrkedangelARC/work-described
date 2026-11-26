//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import AppKit

/// Google Slides runs in Chrome/Safari — control via synthetic keystrokes.
struct GoogleSlidesProfile: AppProfile {
    let bundleIdentifier = "com.google.Chrome"
    let displayName = "Google Slides (Chrome)"
    let supportedCommands: Set<AppCommand> = [
        .nextSlide, .previousSlide, .startPresentation, .stopPresentation
    ]
    let hotkeyLabels: [AppCommand: String] = [
        .startPresentation: "⌘⇧↩",
        .stopPresentation: "Esc",
        .nextSlide: "→",
        .previousSlide: "←"
    ]

    func execute(_ command: AppCommand, on app: NSRunningApplication) throws {
        app.activate()
        switch command {
        case .nextSlide:
            try sendKeyCode(124) // Right Arrow
        case .previousSlide:
            try sendKeyCode(123) // Left Arrow
        case .startPresentation:
            // Cmd+Shift+Enter starts slideshow in Google Slides
            try sendKeyCode(36, using: "command down, shift down") // Return
        case .stopPresentation:
            try sendKeyCode(53) // Escape
        default:
            throw ProfileError.unsupportedCommand(command)
        }
    }
}

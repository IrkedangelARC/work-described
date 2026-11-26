//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import AppKit

struct PDFExpertProfile: AppProfile {
    let bundleIdentifier = "com.readdle.PDFExpert-Mac"
    let displayName = "PDF Expert"
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
            try sendKeyCode(125) // Down Arrow (next page)
        case .previousSlide:
            try sendKeyCode(126) // Up Arrow (previous page)
        case .startPresentation:
            // fn+F (Globe+F) = macOS fullscreen toggle = Ctrl+Cmd+F
            try sendKeyCode(3, using: "command down, control down")
        case .stopPresentation:
            try sendKeyCode(53) // Escape
        default:
            throw ProfileError.unsupportedCommand(command)
        }
    }
}

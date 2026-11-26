//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation

#if os(macOS)
import AppKit

/// Represents a detected physical screen
struct ScreenIdentity: Identifiable, Hashable {
    let id: CGDirectDisplayID
    let localizedName: String
    let frame: CGRect
    let isBuiltIn: Bool
    let index: Int

    var resolution: String {
        "\(Int(frame.width))x\(Int(frame.height))"
    }

    var shortLabel: String {
        isBuiltIn ? "Built-in (\(resolution))" : "\(localizedName) (\(resolution))"
    }

    static func from(_ screen: NSScreen, index: Int) -> ScreenIdentity? {
        guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            return nil
        }
        return ScreenIdentity(
            id: displayID,
            localizedName: screen.localizedName,
            frame: screen.frame,
            isBuiltIn: CGDisplayIsBuiltin(displayID) != 0,
            index: index
        )
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: ScreenIdentity, rhs: ScreenIdentity) -> Bool {
        lhs.id == rhs.id
    }
}

/// What kind of output can be routed to a screen
enum OutputType: String, CaseIterable, Identifiable {
    case control = "control"
    case stageDisplay = "stage-display"
    case confidence = "confidence-output"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .control: "Control Panel"
        case .stageDisplay: "Confidence Monitor"
        case .confidence: "Key Overlay"
        }
    }

    var icon: String {
        switch self {
        case .control: "slider.horizontal.3"
        case .stageDisplay: "tv"
        case .confidence: "rectangle.on.rectangle"
        }
    }

    /// Maps to the SwiftUI WindowGroup id (control has no separate window)
    var windowID: String { rawValue }

    /// The window title SwiftUI assigns to this WindowGroup
    var windowTitle: String {
        switch self {
        case .control: "Shows"  // main window nav title
        case .stageDisplay: StageWindowTitle.stage
        case .confidence: StageWindowTitle.keyOverlay
        }
    }

    /// Whether this output needs openWindow(id:) to create it
    var needsWindowOpen: Bool {
        switch self {
        case .control: false  // already open as the main window
        case .stageDisplay, .confidence: true
        }
    }

    /// Whether this output should be borderless fullscreen
    var isBorderless: Bool {
        switch self {
        case .control: false  // keep title bar and controls
        case .stageDisplay, .confidence: true
        }
    }
}
#endif

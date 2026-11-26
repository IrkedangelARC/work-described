//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import AppKit

/// Duplicated from ARC Presenter (Models/OutputRoute.swift) on 2026-09-20 at the operator's request: ARC Zoom
/// drives external screens the same way Presenter does. PGM is the program window, MON is the gallery.
enum OutputType: String, CaseIterable, Identifiable {
    case operatorView = "operator"
    case program = "program-output"
    case confidence = "confidence-monitor"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .operatorView: "Operator"
        case .program: "Program Output"
        case .confidence: "Gallery Monitor"
        }
    }

    /// The window the display manager moves, by title. These are LayoutWindow's fixed titles.
    var windowTitle: String {
        switch self {
        case .operatorView: "ARC Zoom"
        case .program: LayoutWindow.Kind.program.title
        case .confidence: LayoutWindow.Kind.gallery.title
        }
    }

    var layoutKind: LayoutWindow.Kind? {
        switch self {
        case .operatorView: nil
        case .program: .program
        case .confidence: .gallery
        }
    }

    var shortLabel: String {
        switch self {
        case .operatorView: "OPR"
        case .program: "PGM"
        case .confidence: "MON"
        }
    }
}

struct ScreenIdentity: Identifiable, Hashable {
    let id: CGDirectDisplayID
    let localizedName: String
    let frame: CGRect
    let isBuiltIn: Bool
    let index: Int

    var resolution: String { "\(Int(frame.width))x\(Int(frame.height))" }

    /// Stable across reconnects and reboots (CGDirectDisplayID is not).
    var uuid: String {
        if let cf = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() {
            return CFUUIDCreateString(nil, cf) as String
        }
        return "display-\(id)"
    }

    /// Matches a UUID, a case-insensitive name, or a 1-based index.
    func matches(_ key: String) -> Bool {
        let k = key.trimmingCharacters(in: .whitespaces)
        return k.caseInsensitiveCompare(uuid) == .orderedSame
            || k.caseInsensitiveCompare(localizedName) == .orderedSame
            || Int(k) == index + 1
    }

    static func from(_ screen: NSScreen, index: Int) -> ScreenIdentity? {
        guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return nil }
        return ScreenIdentity(id: displayID, localizedName: screen.localizedName, frame: screen.frame,
                              isBuiltIn: CGDisplayIsBuiltin(displayID) != 0, index: index)
    }
}

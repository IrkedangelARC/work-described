//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation

/// Thread-safe storage for key codes accessed by CGEvent tap callbacks
final class KeyBindingsState: @unchecked Sendable {
    static let shared = KeyBindingsState()
    var globalNextKeys: Set<UInt16> = [124, 121]
    var globalPrevKeys: Set<UInt16> = [123, 116]
}

@MainActor
@Observable
final class KeyBindings {
    private static let storageKey = "keyBindings"

    struct Binding: Codable {
        var keyCode: UInt16
        var label: String
    }

    var nextSlide: [UInt16]
    var prevSlide: [UInt16]
    var toggleBlack: UInt16

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let saved = try? JSONDecoder().decode(SavedBindings.self, from: data) {
            self.nextSlide = saved.nextSlide
            self.prevSlide = saved.prevSlide
            self.toggleBlack = saved.toggleBlack
        } else {
            // Defaults
            self.nextSlide = [124, 121, 125, 49]   // Right, PageDown, Down, Space
            self.prevSlide = [123, 116, 126]        // Left, PageUp, Up
            self.toggleBlack = 11                    // B key
        }
        syncToState()
    }

    // Subset for global CGEvent tap (only arrow + page keys)
    var globalNextKeys: Set<UInt16> {
        Set(nextSlide.filter { [124, 121].contains($0) })
    }

    var globalPrevKeys: Set<UInt16> {
        Set(prevSlide.filter { [123, 116].contains($0) })
    }

    // Full set for local NSEvent monitor
    /// While a text field has focus, EVERY key belongs to the field. The one
    /// way out is Escape, which drops the focus and is swallowed; Return sends
    /// the draft and drops the focus too. Nothing navigational can fire from
    /// inside a sentence: not Space (2026-09-18, "hitting space while on
    /// that text box should not advance the slides"), and not the arrows
    /// either, which in a field are cursor movement. A first version let the
    /// arrows leave the field AND drive the show on the same press, so a Left
    /// to fix a typo would have moved the live slide back on program (the
    /// Presenter session, same evening). A dead clicker is noticed in one
    /// press and fixed by clicking anywhere; a live slide moving is not.
    static let escape: UInt16 = 53
    static func leavesTyping(_ keyCode: UInt16) -> Bool { keyCode == escape }

    var localNextKeys: Set<UInt16> {
        Set(nextSlide)
    }

    var localPrevKeys: Set<UInt16> {
        Set(prevSlide)
    }

    func save() {
        let saved = SavedBindings(
            nextSlide: nextSlide,
            prevSlide: prevSlide,
            toggleBlack: toggleBlack
        )
        if let data = try? JSONEncoder().encode(saved) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
        syncToState()
    }

    func resetToDefaults() {
        nextSlide = [124, 121, 125, 49]
        prevSlide = [123, 116, 126]
        toggleBlack = 11
        save()
    }

    private func syncToState() {
        KeyBindingsState.shared.globalNextKeys = globalNextKeys
        KeyBindingsState.shared.globalPrevKeys = globalPrevKeys
    }

    static func keyName(for code: UInt16) -> String {
        switch code {
        case 123: return "Left Arrow"
        case 124: return "Right Arrow"
        case 125: return "Down Arrow"
        case 126: return "Up Arrow"
        case 116: return "Page Up"
        case 121: return "Page Down"
        case 49:  return "Space"
        case 11:  return "B"
        case 36:  return "Return"
        case 48:  return "Tab"
        case 53:  return "Escape"
        default:  return "Key \(code)"
        }
    }
}

private struct SavedBindings: Codable {
    let nextSlide: [UInt16]
    let prevSlide: [UInt16]
    let toggleBlack: UInt16
}

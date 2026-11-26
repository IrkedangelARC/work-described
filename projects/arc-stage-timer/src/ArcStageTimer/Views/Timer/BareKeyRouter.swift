//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// The show's BARE-KEY shortcuts (Space play/pause, Left/Right cues, Esc stop, 1-4 flash) are menu key
/// equivalents, and AppKit fires a menu key equivalent BEFORE the focused text field sees the key. So typing
/// "WRAP UP" in the message field would have paused the show on the space, and a Left arrow would have moved
/// the cue (the same failure as ARC Presenter's live slide, 2026-09). Every bare-key command goes through here:
/// while a text field is being edited the key goes to the FIELD and the show is untouched; otherwise the show
/// action runs as before.
enum BareKey: Equatable {
    case space, left, right, escape
    case digit(Character)
}

enum BareKeyRoute: Equatable {
    /// Not editing: do the show action.
    case perform
    /// Editing: give the key to the field.
    case insert(String)
    case moveLeft
    case moveRight
    /// Esc while editing: leave the field (the operator gets the show keys back); never STOP SHOW.
    case endEditing
}

enum BareKeyRouter {
    /// Pure: where a bare key goes. Tested.
    static func route(_ key: BareKey, editingText: Bool) -> BareKeyRoute {
        guard editingText else { return .perform }
        switch key {
        case .space: return .insert(" ")
        case .digit(let c): return .insert(String(c))
        case .left: return .moveLeft
        case .right: return .moveRight
        case .escape: return .endEditing
        }
    }

    #if os(macOS)
    /// The text field being edited in the key window, if any (the field editor, an NSTextView, is first
    /// responder while a TextField has focus).
    @MainActor
    static var activeEditor: NSTextView? {
        NSApp.keyWindow?.firstResponder as? NSTextView
    }

    /// The one entry point for every bare-key menu command.
    @MainActor
    static func handle(_ key: BareKey, perform action: () -> Void) {
        let editor = activeEditor
        let r = route(key, editingText: editor != nil && editor!.isEditable)
        if r != .perform { StageLog.log("bare key \(key) went to the text field (\(r)), not the show") }
        switch r {
        case .perform: action()
        case .insert(let s): editor?.insertText(s, replacementRange: editor?.selectedRange() ?? NSRange(location: NSNotFound, length: 0))
        case .moveLeft: editor?.moveLeft(nil)
        case .moveRight: editor?.moveRight(nil)
        case .endEditing: editor?.window?.makeFirstResponder(nil)
        }
    }
    #else
    static func handle(_ key: BareKey, perform action: () -> Void) { action() }
    #endif
}

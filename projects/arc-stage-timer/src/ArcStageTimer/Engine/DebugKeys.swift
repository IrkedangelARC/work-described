//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

#if DEBUG && os(macOS)
import AppKit
import SwiftUI

/// DEBUG builds only: type into the running app with real NSEvents, for the bare-key test (BareKeyRouter).
@MainActor
enum DebugKeys {
    static func handle(path: String, query: [String: String]) -> [String: Any] {
        // These never activate the app or take focus: the review runs while the operator keeps working.
        let quiet = ["/api/debug/stage-shot", "/api/debug/console-shot", "/api/debug/snapshot",
                     "/api/debug/cue-editor", "/api/debug/edit-show"].contains(path)
        if !quiet { NSApp.activate(ignoringOtherApps: true) }
        if !quiet, let console = DisplayPlacement.windows(for: .control).first {
            // A sheet on the console (the CUE EDITOR) keeps the keys: that is where a keypress goes.
            if let sheet = console.attachedSheet { sheet.makeKeyAndOrderFront(nil) } else { console.makeKeyAndOrderFront(nil) }
        }
        switch path {
        case "/api/debug/cue-editor":
            let index = query["new"] != nil ? -1 : (Int(query["index"] ?? "") ?? 1)
            NotificationCenter.default.post(name: .openCueEditor, object: index)
            RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        case "/api/debug/edit-show":
            NotificationCenter.default.post(name: .openShowEditor, object: query["name"] ?? "")
            RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        case "/api/debug/stage-shot":
            // The CONFIDENCE MONITOR rendered offscreen at ?w=&h= (default 1920x1080): every layout and theme
            // can be reviewed at stage size without a window on anybody's display.
            let w = CGFloat(Double(query["w"] ?? "") ?? 1920), h = CGFloat(Double(query["h"] ?? "") ?? 1080)
            let host = NSHostingView(rootView: StageDisplayView()
                .environment(ArcStageTimerApp.sharedDisplayState)
                .preferredColorScheme(.dark)
                .frame(width: w, height: h))
            host.frame = NSRect(x: 0, y: 0, width: w, height: h)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(1.2))   // let the numeric transitions settle
            var out = field()
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                let file = query["path"] ?? "/private/tmp/arc-stage-shot.png"
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: file))
                out["snapshot"] = file
            }
            window.contentView = nil
            return out
        case "/api/debug/console-shot":
            // The console window at ?w=&h= points, title bar and toolbar included, captured by the app itself,
            // then put back: the layout is reviewed at every control-display size without touching focus.
            guard let window = DisplayPlacement.windows(for: .control).first else { return ["ok": false, "error": "no console"] }
            let before = window.frame
            if let w = Double(query["w"] ?? ""), let h = Double(query["h"] ?? "") {
                var f = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: w, height: h))
                f.origin = NSPoint(x: before.minX, y: before.maxY - f.height)
                window.setFrame(f, display: true)
            }
            RunLoop.main.run(until: Date().addingTimeInterval(1.5))
            var out = field()
            if let view = window.contentView?.superview {
                if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    let file = query["path"] ?? "/private/tmp/arc-console-shot.png"
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: file))
                    out["snapshot"] = file
                }
                out["content"] = "\(Int(window.contentLayoutRect.width))x\(Int(window.contentLayoutRect.height))"
                // What would take a keypress when the console is next made key: a text view here means the show
                // keys would type into a field.
                out["consoleFirstResponder"] = window.firstResponder.map { String(describing: type(of: $0)) } ?? "none"
                out["minSize"] = "\(Int(window.contentMinSize.width))x\(Int(window.contentMinSize.height))"
            }
            if query["keep"] == nil { window.setFrame(before, display: true) }
            return out
        case "/api/debug/snapshot":
            // The app photographs its own window (no Screen Recording grant, nobody's screen touched).
            let console = DisplayPlacement.windows(for: .control).first
            let target = console?.attachedSheet ?? NSApp.keyWindow ?? console
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            var out = field()
            if let view = target?.contentView?.superview ?? target?.contentView,
               let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                let file = query["path"] ?? "/private/tmp/arc-stage-snapshot.png"
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: file))
                out["snapshot"] = file
                out["size"] = "\(Int(view.bounds.width))x\(Int(view.bounds.height))"
            }
            return out
        case "/api/debug/focus-message":
            NotificationCenter.default.post(name: .focusMessageField, object: nil)
        case "/api/debug/key":
            if let text = query["type"]?.replacingOccurrences(of: "+", with: " ") {
                for ch in text { post(String(ch)) }
            }
            if let key = query["key"] { post(named: key) }
        default: break
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        return field()
    }

    /// The field editor's state, and what the show is doing, for the proof.
    static func field() -> [String: Any] {
        let editor = BareKeyRouter.activeEditor
        let engine = ArcStageTimerApp.sharedEngine
        return ["ok": true,
                "editing": editor != nil,
                "fieldText": editor?.string ?? "",
                "firstResponder": NSApp.keyWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "none",
                "timerState": engine.state.rawValue,
                "cueIndex": engine.currentCueIndex,
                "flashSequence": ArcStageTimerApp.sharedStageDirector.flashSequence,
                "message": ArcStageTimerApp.sharedStageDirector.message ?? "",
                "keyWindowIsSheet": NSApp.keyWindow?.sheetParent != nil,
                "sheetOpen": DisplayPlacement.windows(for: .control).first?.attachedSheet != nil,
                "appActive": NSApp.isActive,
                "keyWindowTitle": NSApp.keyWindow?.title ?? "",
                "cues": engine.cues.map { "\($0.title) \($0.durationSeconds)s" },
                "undo": engine.undoActionName ?? ""]
    }

    private static let codes: [Character: UInt16] = [
        "A": 0, "S": 1, "D": 2, "F": 3, "H": 4, "G": 5, "Z": 6, "X": 7, "C": 8, "V": 9, "B": 11, "Q": 12, "W": 13,
        "E": 14, "R": 15, "Y": 16, "T": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26,
        "8": 28, "0": 29, "O": 31, "U": 32, "I": 34, "P": 35, "L": 37, "J": 38, "K": 40, "N": 45, "M": 46, " ": 49,
    ]

    private static func post(_ chars: String) {
        let code = codes[Character(chars.uppercased())] ?? 0
        send(chars: chars, code: code)
    }

    private static func post(named key: String) {
        switch key.lowercased() {
        case "left": send(chars: String(UnicodeScalar(NSLeftArrowFunctionKey)!), code: 123, fn: true)
        case "right": send(chars: String(UnicodeScalar(NSRightArrowFunctionKey)!), code: 124, fn: true)
        case "space": send(chars: " ", code: 49)
        case "escape": send(chars: "\u{1b}", code: 53)
        case "return": send(chars: "\r", code: 36)
        case "cmdreturn": send(chars: "\r", code: 36, mods: .command)
        default: post(key)
        }
    }

    private static func send(chars: String, code: UInt16, fn: Bool = false, mods: NSEvent.ModifierFlags = []) {
        guard let window = NSApp.keyWindow else { return }
        let flags: NSEvent.ModifierFlags = (fn ? NSEvent.ModifierFlags([.function, .numericPad]) : []).union(mods)
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                        context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                        isARepeat: false, keyCode: code) {
                NSApp.sendEvent(e)
            }
        }
    }
}
#endif

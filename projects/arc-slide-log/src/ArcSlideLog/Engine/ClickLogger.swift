//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import AppKit
import CoreGraphics
import ARCShowFormat

/// Click impulses: every key press and mouse button, with the capture clock reading and the app in
/// front, through a listen-only event tap (the Input Monitoring consent). A clicker is a keyboard that
/// sends Page Down, arrows, B or Esc; the edit needs the instants, the deck says what each one did.
/// Keys are logged by name or code only, never as typed text.
final class ClickLogger: @unchecked Sendable {
    struct Click: Equatable {
        let mono: Double
        /// key or mouse
        let source: String
        /// pagedown, right, space, mouse-left, key 23 ...
        let name: String
        let modifiers: String?
        let app: String?
    }

    var onClick: ((Click) -> Void)?
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    private var thread: Thread?
    private(set) var isRunning = false
    private var _count = 0
    private let lock = NSLock()
    var count: Int { lock.lock(); defer { lock.unlock() }; return _count }

    static var isTrusted: Bool { CGPreflightListenEventAccess() }

    /// Ask for Input Monitoring. The preflight request alone did not list the app in System Settings
    /// (2026-10-23, macOS 27), so this also tries to create a tap, which registers the app and prompts.
    @discardableResult static func requestTrust() -> Bool {
        if CGPreflightListenEventAccess() { return true }
        _ = CGRequestListenEventAccess()
        let mask: CGEventMask = 1 << CGEventType.keyDown.rawValue
        if let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly, eventsOfInterest: mask,
                                       callback: { _, _, event, _ in Unmanaged.passUnretained(event) }, userInfo: nil) {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        return CGPreflightListenEventAccess()
    }

    /// Key codes a clicker or a presenter uses, by name; anything else is "key N".
    static let names: [Int64: String] = [
        123: "left", 124: "right", 125: "down", 126: "up", 116: "pageup", 121: "pagedown",
        115: "home", 119: "end", 49: "space", 36: "return", 76: "enter", 53: "esc", 48: "tab", 51: "delete",
        11: "b", 13: "w", 96: "f5", 122: "f1", 120: "f2", 99: "f3", 118: "f4", 97: "f6", 98: "f7", 100: "f8",
        101: "f9", 109: "f10", 103: "f11", 111: "f12", 35: "p", 2: "d", 34: "i",
    ]

    static func name(forKeyCode code: Int64) -> String { names[code] ?? "key \(code)" }

    static func modifiers(_ flags: CGEventFlags) -> String? {
        var m: [String] = []
        if flags.contains(.maskCommand) { m.append("cmd") }
        if flags.contains(.maskAlternate) { m.append("opt") }
        if flags.contains(.maskControl) { m.append("ctrl") }
        if flags.contains(.maskShift) { m.append("shift") }
        return m.isEmpty ? nil : m.joined(separator: "+")
    }

    static func describe(type: CGEventType, event: CGEvent) -> (source: String, name: String, modifiers: String?)? {
        switch type {
        case .keyDown:
            // Auto-repeat is one press held, not more presses.
            if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return nil }
            return ("key", name(forKeyCode: event.getIntegerValueField(.keyboardEventKeycode)), modifiers(event.flags))
        case .leftMouseDown: return ("mouse", "mouse-left", modifiers(event.flags))
        case .rightMouseDown: return ("mouse", "mouse-right", modifiers(event.flags))
        case .otherMouseDown: return ("mouse", "mouse-\(event.getIntegerValueField(.mouseEventButtonNumber))", modifiers(event.flags))
        default: return nil
        }
    }

    func start() throws {
        guard !isRunning else { return }
        guard Self.isTrusted else { throw LoggerError.notTrusted }
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue) | (1 << CGEventType.otherMouseDown.rawValue)
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly, eventsOfInterest: mask,
                                          callback: { _, type, event, userInfo in
                                              guard let userInfo else { return Unmanaged.passUnretained(event) }
                                              let logger = Unmanaged<ClickLogger>.fromOpaque(userInfo).takeUnretainedValue()
                                              logger.handle(type: type, event: event)
                                              return Unmanaged.passUnretained(event)
                                          }, userInfo: me) else { throw LoggerError.tapFailed }
        self.tap = tap
        lock.lock(); _count = 0; lock.unlock()
        let t = Thread { [weak self] in
            let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
            let rl = CFRunLoopGetCurrent()
            self?.runLoop = rl
            CFRunLoopAddSource(rl, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
        }
        t.name = "arc.slidelog.clicks"
        t.qualityOfService = .userInteractive
        t.start()
        thread = t
        isRunning = true
    }

    private func handle(type: CGEventType, event: CGEvent) {
        let mono = SlideTrack.monotonicSeconds()
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput, let tap { CGEvent.tapEnable(tap: tap, enable: true); return }
        guard let d = Self.describe(type: type, event: event) else { return }
        let pid = pid_t(event.getIntegerValueField(.eventTargetUnixProcessID))
        let app = pid > 0 ? NSRunningApplication(processIdentifier: pid)?.bundleIdentifier : NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        lock.lock(); _count += 1; lock.unlock()
        onClick?(Click(mono: mono, source: d.source, name: d.name, modifiers: d.modifiers, app: app))
    }

    func stop() {
        guard isRunning else { return }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let rl = runLoop { CFRunLoopStop(rl) }
        tap = nil; runLoop = nil; thread = nil
        isRunning = false
    }

    enum LoggerError: LocalizedError {
        case notTrusted, tapFailed
        var errorDescription: String? {
            switch self {
            case .notTrusted: "Input Monitoring is not granted (System Settings > Privacy & Security > Input Monitoring)"
            case .tapFailed: "the event tap could not be created"
            }
        }
    }
}

//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import AppKit
import ApplicationServices

/// In-process Accessibility calls for another app's windows. Attributed to
/// ARC Capture itself, so the app's own Accessibility grant applies; a child
/// `osascript` was refused ("osascript is not allowed assistive access")
/// even with the app switched on in System Settings (2026-09-12).
enum AXWindows {
    static func windows(of bundleIdentifier: String, titlePrefix: String) -> [AXUIElement] {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first else { return [] }
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &value) == .success,
              let list = value as? [AXUIElement] else { return [] }
        return list.filter { title(of: $0).hasPrefix(titlePrefix) }
    }

    static func title(of w: AXUIElement) -> String {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &v) == .success else { return "" }
        return v as? String ?? ""
    }

    /// Top-left origin, global screen coordinates (System Events' space).
    static func frame(of w: AXUIElement) -> CGRect? {
        var pv: CFTypeRef?, sv: CFTypeRef?
        guard AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &pv) == .success,
              AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &sv) == .success else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        guard AXValueGetValue(pv as! AXValue, .cgPoint, &p), AXValueGetValue(sv as! AXValue, .cgSize, &s) else { return nil }
        return CGRect(origin: p, size: s)
    }

    @discardableResult
    static func set(_ w: AXUIElement, position: CGPoint, size: CGSize) -> Bool {
        var s = size, p = position
        guard let sv = AXValueCreate(.cgSize, &s), let pv = AXValueCreate(.cgPoint, &p) else { return false }
        let a = AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, sv)
        let b = AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, pv)
        // Size again after the move: some apps clamp the size to the display
        // the window sat on at the time.
        let c = AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, sv)
        return a == .success && b == .success && c == .success
    }

    @discardableResult
    static func raise(_ w: AXUIElement) -> Bool {
        AXUIElementPerformAction(w, kAXRaiseAction as CFString) == .success
    }

    /// One left click at a global top-left-origin point.
    static func click(at p: CGPoint) {
        guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left) else { return }
        down.post(tap: .cghidEventTap)
        usleep(40_000)
        up.post(tap: .cghidEventTap)
    }
}

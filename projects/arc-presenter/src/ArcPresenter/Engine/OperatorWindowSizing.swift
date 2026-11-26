//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import AppKit
import SwiftUI

/// The operator window's minimum size, derived ONCE per event instead of on
/// every display cycle.
///
/// Measured 2026-09-18 on the 16 GB Pro, 367-page deck live, nothing clicked,
/// 10 s `sample`: 35 % of the main thread sat in the display-cycle flush, all
/// of it `NSHostingView.minSize()` reached from both `layoutIfNeeded` and
/// `updateConstraintsIfNeeded`: SwiftUI re-deriving the window's content-size
/// extrema from the whole operator tree every cycle, because a `Window`
/// scene's hosting view carries `.minSize` in its `sizingOptions`. The tree's
/// minimum only changes on the events 5.0.2 already refits on (screens,
/// outputs opening or closing, leaving full screen), so: let SwiftUI derive it
/// on those, copy the result into `contentMinSize`, and clear the sizing
/// options in between.
///
/// `NSHostingView` is generic over its content, which a scene hides; the
/// protocol below is what lets the window's content view be reached without
/// naming that type.
protocol HostingSizingFreezable: AnyObject {
    /// Stop feeding the window; returns what was in force.
    func freezeSizing() -> NSHostingSizingOptions
    func thawSizing(_ options: NSHostingSizingOptions)
    var sizingIsFrozen: Bool { get }
}

extension NSHostingView: HostingSizingFreezable {
    func freezeSizing() -> NSHostingSizingOptions {
        let was = sizingOptions
        sizingOptions = []
        return was
    }
    func thawSizing(_ options: NSHostingSizingOptions) { sizingOptions = options }
    var sizingIsFrozen: Bool { sizingOptions.isEmpty }
}

@MainActor
enum OperatorWindowSizing {
    private static var thawed: NSHostingSizingOptions = [.minSize, .maxSize]
    private(set) static var frozenMinSize: CGSize?
    private(set) static var frozenAt: Date?

    static var operatorWindow: NSWindow? {
        NSApplication.shared.windows.first { $0.title == "ARC Presenter" || $0.identifier?.rawValue == "operator" }
    }

    /// Take the minimum SwiftUI has derived so far, make it the window's own,
    /// and stop the per-cycle derivation.
    static func freeze(reason: String) {
        guard let window = operatorWindow, let host = window.contentView as? HostingSizingFreezable else {
            ShowLog.log("operator window sizing: no hosting view to freeze (\(reason))")
            return
        }
        // What SwiftUI derived on its last pass. Once the options are cleared it
        // zeroes contentMinSize on a later pass of its own, so a zero read here
        // means "unchanged", never "no minimum": keep the last positive value.
        let derived = window.contentMinSize
        let minSize = derived.width > 0 && derived.height > 0 ? derived : (frozenMinSize ?? .zero)
        if !host.sizingIsFrozen { thawed = host.freezeSizing() }
        guard minSize.width > 0 else {
            ShowLog.log("operator window sizing: nothing derived yet (\(reason)); left thawed until the next refit")
            host.thawSizing(thawed)
            return
        }
        window.contentMinSize = minSize
        frozenMinSize = minSize; frozenAt = Date()
        // A footer group that grows past the window squeezes every other group (STATUS tiles at 1930 pt in a
        // 1920 pt window truncated NAVIGATE's counter and OUTPUTS' chips, 2026-09-19). Say so where the APP tile sees it.
        let width = window.frame.width
        if minSize.width > width + 0.5 {
            ShowLog.error("operator window needs \(Int(minSize.width)) pt but is \(Int(width)) pt wide: a footer group grew (\(reason))")
        }
        // SwiftUI's own next pass may clear it again: assert it once more.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            if let w = operatorWindow, (w.contentView as? HostingSizingFreezable)?.sizingIsFrozen == true, w.contentMinSize.width < minSize.width {
                w.contentMinSize = minSize
            }
        }
        ShowLog.log("operator window sizing frozen: min \(Int(minSize.width))x\(Int(minSize.height)) (\(reason))")
    }

    /// Let SwiftUI derive the minimum once more (a screen or an output
    /// changed), then freeze on the new value.
    static func refresh(reason: String, then done: (() -> Void)? = nil) {
        guard let window = operatorWindow, let host = window.contentView as? HostingSizingFreezable else { done?(); return }
        if host.sizingIsFrozen { host.thawSizing(thawed) }
        window.contentView?.needsLayout = true
        // Two turns of the run loop: the update-constraints and layout observers each run once.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            freeze(reason: reason)
            done?()
        }
    }

    static func setFrozen(_ frozen: Bool, reason: String) {
        guard let window = operatorWindow, let host = window.contentView as? HostingSizingFreezable else { return }
        if frozen { freeze(reason: reason) } else if host.sizingIsFrozen {
            host.thawSizing(thawed); frozenMinSize = nil; frozenAt = nil
            ShowLog.log("operator window sizing thawed (\(reason))")
        }
    }

    /// Read on the main thread whatever thread the control server asks from:
    /// NSWindow geometry read elsewhere comes back as zeros.
    nonisolated static var json: String {
        if Thread.isMainThread { return MainActor.assumeIsolated { jsonOnMain } }
        return DispatchQueue.main.sync { MainActor.assumeIsolated { jsonOnMain } }
    }

    private static var jsonOnMain: String {
        let window = operatorWindow
        let cls = window?.contentView.map { String(describing: type(of: $0)) } ?? ""
        let frozen = (window?.contentView as? HostingSizingFreezable)?.sizingIsFrozen ?? false
        let cmin = window?.contentMinSize ?? .zero
        let wmin = window?.minSize ?? .zero
        let held = frozenMinSize ?? .zero
        return "\"contentViewClass\":\"\(cls.replacingOccurrences(of: "\"", with: "'"))\",\"sizingFrozen\":\(frozen),\"contentMinSize\":{\"w\":\(Int(cmin.width)),\"h\":\(Int(cmin.height))},\"minSize\":{\"w\":\(Int(wmin.width)),\"h\":\(Int(wmin.height))},\"heldMinSize\":{\"w\":\(Int(held.width)),\"h\":\(Int(held.height))}"
    }
}

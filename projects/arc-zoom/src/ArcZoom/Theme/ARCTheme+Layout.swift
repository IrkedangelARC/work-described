//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import ARCStyle
import AppKit
import CoreGraphics
import SwiftUI

/// The spacing this app's own layout uses, on top of the shared ARCStyle package. ARC Presenter carries
/// the same pair of names for the same reason: `modulePad` (in the package) is a module's inside, and
/// `railPad` is the gap between modules and the window edge.
extension ARCTheme {
    /// VARIABLE RESOLUTION (2026-09-20), GROW ONLY since 2026-09-23. The operator surface is designed at
    /// 1920 x 1050 of content; a bigger window draws it larger. A SMALLER window no longer draws it smaller: at a
    /// MacBook Pro's default 1512 x 982 the old scale was 0.80 and every 10 pt label came out at 8-10 pt (
    /// "give the same sizing and layout treatment", after Presenter 5.5.0 and Capture 3.3.0). Below the design size
    /// the console REFLOWS instead (`OperatorLayout`): groups stack, pickers narrow, rails scroll as a last resort.
    /// Set by the operator window's root from its size, quantised so it only changes at meaningful steps.
    nonisolated(unsafe) static var uiScale: CGFloat = 1
    /// Content size on a 1080-line display once the title bar is off it: a 1920 x 1080 operator screen is scale 1.
    static let designSize = CGSize(width: 1920, height: 1050)
    static let minScale: CGFloat = 1
    static let maxScale: CGFloat = 1.6
    static func scale(for size: CGSize) -> CGFloat {
        let raw = min(size.width / designSize.width, size.height / designSize.height)
        return (min(max(raw, minScale), maxScale) * 20).rounded() / 20
    }
    /// The smallest console text: 12 pt (a 9 or 10 pt design size is raised by `legible`), never below 11.
    static let minConsoleText: CGFloat = 11
    /// Console text at the design size, scaled up on a big window, never down.
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        .system(size: max(minConsoleText, (legible(size) * uiScale).rounded()), weight: weight, design: .monospaced)
    }
    /// A design-size metric (a fixed width, a row height), scaled.
    static func s(_ v: CGFloat) -> CGFloat { (v * uiScale).rounded() }
    /// The operator window's minimum CONTENT size. Below a MacBook Pro's 1512 x ~870 visible content on purpose,
    /// so the window can always be made to fit; at the minimum the rails scroll rather than clip.
    /// 1440: a rail's narrowest row (a participant with TO PROGRAM / SPOTLIGHT / UNMUTE and a 64 pt name) needs
    /// ~460 pt, so three rails need ~1440 (measured, WindowSizingTests). Was 1100, where every rail clipped.
    static let consoleMinW: CGFloat = 1440
    static let consoleMinH: CGFloat = 720
    static var railPad: CGFloat { s(8) }
}

// MARK: - The ARC sub-group (2026-09-20 17:30: "use the ARC style sub group look with the grey")

// The colour itself is `ARCTheme.subGroup` in arc-style, from brand/arc_brand.json (screen.subGroup):
// every ARC app gets the same sub-group ground, and there is no hex literal here to drift.

extension View {
    /// A labelled grey panel inside a module. Related controls sit together under one small label, so a
    /// module reads as its parts, not as a pile of chips. No label: an unlabelled group (an action row).
    func arcSubGroup(_ label: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: ARCTheme.s(5)) {
            // Wraps to a second line rather than set the rail's width: a fixedSize label made the rail as
            // wide as its longest note ("devices · in: the mic the call hears · ...", 2026-09-23 sizing pass).
            if let label {
                Text(label.uppercased()).font(ARCTheme.ui(10, .heavy)).foregroundStyle(ARCTheme.text1)
                    .lineLimit(2).truncationMode(.tail).fixedSize(horizontal: false, vertical: true)
            }
            self
        }
        .padding(.horizontal, ARCTheme.s(8)).padding(.vertical, ARCTheme.s(7))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ARCTheme.subGroup)
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(ARCTheme.line, lineWidth: 1))
        .cornerRadius(4)
    }
}

/// The one chip: the seven private copies in the modules were identical (audit P2).
func arcChip(_ label: String, tint: Color = ARCTheme.text0, fill: Color? = nil, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Text(label).font(ARCTheme.ui(11, .bold)).lineLimit(1).fixedSize()
            .foregroundStyle(fill == nil ? tint : .white)
            .padding(.horizontal, ARCTheme.s(10)).padding(.vertical, ARCTheme.s(5))
            .background(fill ?? ARCTheme.appGrey)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(fill ?? ARCTheme.line, lineWidth: 1))
            .cornerRadius(4)
    }
    .buttonStyle(.plain)
}

/// A chip whose label is allowed to WRAP, for the few names too long to sit on one line beside
/// something else. A one-line `arcChip` with a long label sets the whole rail's minimum width and
/// pushes its neighbours narrow, which is how ZOOM PORTAL SETTINGS made WAITING ROOM OFF spill its
/// sub-group. The width is given, so this one can never do that.
func arcWrappingChip(_ label: String, width: CGFloat, tint: Color = ARCTheme.text0, fill: Color? = nil,
                     action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Text(label).font(ARCTheme.ui(11, .bold)).multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(fill == nil ? tint : .white)
            .frame(width: width)
            .padding(.vertical, ARCTheme.s(5))
            .background(fill ?? ARCTheme.appGrey)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(fill ?? ARCTheme.line, lineWidth: 1))
            .cornerRadius(4)
    }
    .buttonStyle(.plain)
}

/// A small label inside a sub-group row ("PGM", "PRESET").
func arcLabel(_ t: String) -> some View { Text(t).font(ARCTheme.ui(10, .heavy)).foregroundStyle(ARCTheme.text1).fixedSize() }

// MARK: - Responsive layout (2026-09-23: "the same sizing and layout treatment" as Presenter 5.5.0 / Capture 3.3.0)

/// How much room the operator window gives the console under its header, measured once and handed down so
/// every module decides the same way. A MacBook Pro at its default 1512 x 982 gives ~1512 x 750 here; a
/// 1920 x 1080 operator screen ~1920 x 950. Below the roomy width the console REFLOWS: groups that sat side
/// by side stack, pickers narrow, the rails are dealt differently, a rail scrolls as the last resort. Text
/// never shrinks for it (`ARCTheme.ui` is grow-only).
struct OperatorLayout: Equatable {
    var size: CGSize = CGSize(width: 1920, height: 900)
    /// One of the three rails, dividers taken off.
    var railW: CGFloat { ((size.width - 2) / 3).rounded(.down) }
    /// A rail too narrow for two groups of chips side by side.
    var narrow: Bool { railW < ARCTheme.s(600) }
}

private struct OperatorLayoutKey: EnvironmentKey {
    static let defaultValue = OperatorLayout()
}

extension EnvironmentValues {
    var operatorLayout: OperatorLayout {
        get { self[OperatorLayoutKey.self] }
        set { self[OperatorLayoutKey.self] = newValue }
    }
}

extension View {
    /// Scrolls vertically only when the content is taller than the space it is given; otherwise it lays out as
    /// is and its flexible tail takes the rest. A tail must declare an `idealHeight` (its useful minimum), or the
    /// fit test would read a list's full height and scroll the whole rail instead of the list.
    func scrollsWhenShort() -> some View {
        ViewThatFits(in: .vertical) {
            self
            ScrollView(.vertical, showsIndicators: true) { self }
        }
    }
}

// MARK: - Window placement

/// Keeps every ARC Zoom window on a screen (2026-09-23): a frame restored from a bigger or departed display is
/// shrunk to the visible frame and moved onto it; below the window's minimum it keeps its minimum and its TITLE
/// BAR on screen. Pure, so the arithmetic is tested; `WindowPlacement` applies it.
enum WindowFit {
    static func fit(_ frame: CGRect, minimum: CGSize, in visible: CGRect) -> CGRect {
        var f = frame
        f.size.width = max(minimum.width, min(f.width, visible.width))
        f.size.height = max(minimum.height, min(f.height, visible.height))
        // x: inside when it fits, else pinned to the left edge. y: inside when it fits, else the TOP stays on screen.
        f.origin.x = f.width <= visible.width ? min(max(f.minX, visible.minX), visible.maxX - f.width) : visible.minX
        f.origin.y = f.height <= visible.height ? min(max(f.minY, visible.minY), visible.maxY - f.height) : visible.maxY - f.height
        return f
    }
}

/// The control windows (Settings, Portal, Log, Chat, Captions, Participants): fitted when they come up and on
/// every screen change (debounced, they arrive in bursts). The operator window has its own fit in AppDelegate,
/// which also keeps it off the PGM / MON displays; the output windows are DisplayManager's and are never touched.
@MainActor
enum WindowPlacement {
    static let controlTitles: Set<String> = ["Settings", "Portal", "Log", "Chat", "Captions", "Participants"]
    private static var installed = false
    private static var work: DispatchWorkItem?

    static func install() {
        guard !installed else { return }
        installed = true
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { schedule() }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
            MainActor.assumeIsolated { if let w = note.object as? NSWindow, controlTitles.contains(w.title) { fit(w) } }
        }
        schedule()
    }

    static func schedule() {
        work?.cancel()
        let w = DispatchWorkItem { MainActor.assumeIsolated { fitAll() } }
        work = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: w)
    }

    static func fitAll() {
        for w in NSApplication.shared.windows where w.isVisible && controlTitles.contains(w.title) { fit(w) }
    }

    static func fit(_ w: NSWindow) {
        guard let screen = w.screen ?? NSScreen.main else { return }
        let minimum = w.frameRect(forContentRect: CGRect(origin: .zero, size: w.contentMinSize)).size
        let f = WindowFit.fit(w.frame, minimum: minimum, in: screen.visibleFrame)
        if f != w.frame {
            w.setFrame(f, display: true, animate: false)
            ShowLog.log("\(w.title) window fitted to \(screen.localizedName): \(Int(f.width))x\(Int(f.height))")
        }
    }
}

//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI

/// How much room the main window gives its screens (2026-09-23, "real, robust resizing adjustments for
/// different resolutions"). Measured once at the root and handed down, so every screen decides the same way:
/// at a MacBook Pro's default 1512 x 982 the window is short, at 1920 x 1080 and up it is roomy. A compact
/// screen REFLOWS (shorter log, narrower side columns, a scrolling column); it never shrinks its text.
struct CaptureLayout: Equatable {
    var size: CGSize = CGSize(width: ARCTheme.roomyW, height: ARCTheme.roomyH)

    /// Shorter than the full layout needs: logs and ACTIVITY give up height to the pictures.
    var shortH: Bool { size.height < ARCTheme.roomyH }
    /// Narrower than the full layout needs: side columns take their narrow widths.
    var narrowW: Bool { size.width < ARCTheme.roomyW }

    /// The capture monitor's rail: the picture keeps at least half the width.
    var railW: CGFloat { narrowW ? 340 : ARCTheme.railW }
    /// The monitor's LOG module body.
    var logH: CGFloat { shortH ? 72 : 120 }
    /// The SHOW tab: NEXT + STEPS on the left, HOLDING / PASSED OVER / REVIEW on the right.
    var showLeftW: CGFloat { narrowW ? 340 : 390 }
    var showRightW: CGFloat { narrowW ? 260 : 300 }
    /// The SHOW tab's ACTIVITY module, log included.
    var activityH: CGFloat { shortH ? 160 : 220 }
    /// The REVIEW tab's queue.
    var reviewQueueW: CGFloat { narrowW ? 300 : 360 }
}

private struct CaptureLayoutKey: EnvironmentKey {
    static let defaultValue = CaptureLayout()
}

extension EnvironmentValues {
    var captureLayout: CaptureLayout {
        get { self[CaptureLayoutKey.self] }
        set { self[CaptureLayoutKey.self] = newValue }
    }
}

extension View {
    /// Measures the space this view is given and hands it to everything inside as `captureLayout`.
    func measuresCaptureLayout() -> some View { modifier(CaptureLayoutReader()) }

    /// Scrolls vertically only when the content is taller than the space it is given; otherwise it lays out as is.
    func scrollsWhenShort() -> some View {
        ViewThatFits(in: .vertical) {
            self
            ScrollView(.vertical) { self }
        }
    }
}

/// Internal, not private: SwiftUI keys the saved window frame on the scene's type name, and a private type's name
/// carries a per-build address, so every build would forget the window's frame.
struct CaptureLayoutReader: ViewModifier {
    @State private var size: CGSize = CGSize(width: ARCTheme.roomyW, height: ARCTheme.roomyH)

    func body(content: Content) -> some View {
        content
            .environment(\.captureLayout, CaptureLayout(size: size))
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
    }
}

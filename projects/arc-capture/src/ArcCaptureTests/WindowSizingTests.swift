//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import XCTest
import SwiftUI
import AppKit

/// The window fits the screens ARC Capture runs on (2026-09-23): a MacBook Pro at its default 1512 x 982
/// and everything larger. The frame arithmetic is pure; the screens' minimums are measured, not inferred.
final class WindowSizingTests: XCTestCase {
    /// A 1512 x 982 MacBook Pro with the menu bar (notch) and the Dock showing: roughly 1512 x 880 visible.
    let macBookPro = CGRect(x: 0, y: 65, width: 1512, height: 880)
    let chrome = CGSize(width: 0, height: 32)
    var minFrame: CGSize { CGSize(width: ARCTheme.windowMinW + chrome.width, height: ARCTheme.windowMinH + chrome.height) }

    func testTheMinimumFitsAMacBookProWithTheDockShowing() {
        XCTAssertLessThanOrEqual(minFrame.width, macBookPro.width)
        XCTAssertLessThanOrEqual(minFrame.height, macBookPro.height)
    }

    func testAFrameRestoredFromABiggerDisplayIsShrunkAndMovedOnScreen() {
        let restored = CGRect(x: 300, y: 200, width: 1920, height: 1040)
        let f = CaptureWindowSizing.fit(restored, minimum: minFrame, in: macBookPro)
        XCTAssertTrue(macBookPro.contains(f), "\(f) not inside \(macBookPro)")
        XCTAssertEqual(f.width, 1512); XCTAssertEqual(f.height, 880)
    }

    func testAFrameThatFitsIsLeftAlone() {
        let f = CGRect(x: 100, y: 100, width: 1300, height: 800)
        XCTAssertEqual(CaptureWindowSizing.fit(f, minimum: minFrame, in: macBookPro), f)
    }

    func testAFrameBelowTheMinimumGrowsDownwardFromItsTop() {
        let f = CaptureWindowSizing.fit(CGRect(x: 100, y: 300, width: 900, height: 500), minimum: minFrame, in: macBookPro)
        XCTAssertEqual(f.size, minFrame)
        XCTAssertTrue(macBookPro.contains(f))
    }

    func testAScreenSmallerThanTheMinimumKeepsTheTitleBarOnScreen() {
        let tiny = CGRect(x: 0, y: 0, width: 1024, height: 640)
        let f = CaptureWindowSizing.fit(CGRect(x: 0, y: 0, width: 1400, height: 900), minimum: minFrame, in: tiny)
        XCTAssertEqual(f.size, minFrame)
        XCTAssertEqual(f.maxY, tiny.maxY, "the top edge, where the title bar is, stays on screen")
        XCTAssertEqual(f.minX, tiny.minX)
    }

    // MARK: Measured minimums of the screens that need no show folder

    /// The height a screen leaves for itself under the tab strip and its divider.
    private var screenMinH: CGFloat { ARCTheme.windowMinH - ARCTheme.tabStripH - 1 }

    @MainActor
    private func fitting<V: View>(_ view: V, at size: CGSize) -> CGSize {
        // Proposed exactly the space it gets; a screen that cannot fit answers with more than it was offered.
        let host = NSHostingController(rootView: view.environment(\.captureLayout, CaptureLayout(size: size)))
        return host.sizeThatFits(in: size)
    }

    /// The probe itself: offered too little, a screen answers with more, so a pass above means something.
    @MainActor
    func testTheMeasureSeesAnOverflow() {
        let session = CaptureSession(driver: FakeDriver(slides: 3), frameSource: FakeFrameSource(), recorder: VideoRecorder())
        let tooSmall = CGSize(width: 700, height: 300)
        let s = fitting(CaptureMonitorView(session: session), at: tooSmall)
        XCTAssertTrue(s.width > tooSmall.width || s.height > tooSmall.height, "the monitor claimed to fit \(tooSmall): \(s)")
    }

    @MainActor
    func testTheCaptureScreensFitTheMinimumWindow() {
        let small = CGSize(width: ARCTheme.windowMinW, height: screenMinH)
        let session = CaptureSession(driver: FakeDriver(slides: 3), frameSource: FakeFrameSource(), recorder: VideoRecorder())
        let screens: [(String, CGSize)] = [
            ("setup", fitting(CaptureSetupView(session: session), at: small)),
            ("monitor", fitting(CaptureMonitorView(session: session), at: small)),
            ("complete", fitting(CaptureCompleteView(session: session), at: small)),
        ]
        for (name, s) in screens {
            XCTAssertLessThanOrEqual(s.width, ARCTheme.windowMinW, "\(name) needs \(s.width) pt of width")
            XCTAssertLessThanOrEqual(s.height, screenMinH, "\(name) needs \(s.height) pt of height")
        }
    }
}

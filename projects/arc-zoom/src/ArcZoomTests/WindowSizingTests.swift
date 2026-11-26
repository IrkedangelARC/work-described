//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import XCTest
import SwiftUI
import AppKit
import ARCStyle
@testable import ArcZoom

/// The operator console fits the screens ARC Zoom runs on (2026-09-23): a MacBook Pro at its default 1512 x 982
/// with the Dock showing, and 1710, 1920, 2056 wide. The frame arithmetic is pure; the rails' needs are MEASURED
/// from the real views (pre-meeting and a staged meeting, LayoutStage), never inferred.
@MainActor
final class WindowSizingTests: XCTestCase {
    /// A 1512 x 982 MacBook Pro with the menu bar (notch) and the Dock showing: roughly 1512 x 880 visible.
    let macBookPro = CGRect(x: 0, y: 65, width: 1512, height: 880)
    let titleBar: CGFloat = 28

    override func setUp() { ARCTheme.uiScale = 1 }

    // MARK: Scale and minimum

    func testTextNeverShrinksBelowTheDesignSize() {
        XCTAssertEqual(ARCTheme.scale(for: CGSize(width: 1512, height: 872)), 1, "a MacBook reflows, it does not shrink")
        XCTAssertEqual(ARCTheme.scale(for: CGSize(width: 1180, height: 720)), 1)
        XCTAssertEqual(ARCTheme.scale(for: CGSize(width: 1920, height: 1012)), 1)
        XCTAssertEqual(ARCTheme.scale(for: CGSize(width: 3840, height: 2100)), 1.6, "a 4K window grows, capped")
        XCTAssertGreaterThanOrEqual(ARCTheme.legible(9), 12, "the smallest design size still draws at 12 pt")
    }

    func testTheMinimumWindowFitsAMacBookProWithTheDockShowing() {
        XCTAssertLessThanOrEqual(ARCTheme.consoleMinW, macBookPro.width)
        XCTAssertLessThanOrEqual(ARCTheme.consoleMinH + titleBar, macBookPro.height)
    }

    // MARK: WindowFit (pure)

    func testAFrameRestoredFromABiggerDisplayIsShrunkAndMovedOnScreen() {
        let f = WindowFit.fit(CGRect(x: 300, y: 200, width: 1920, height: 1040), minimum: CGSize(width: 1180, height: 748), in: macBookPro)
        XCTAssertTrue(macBookPro.contains(f), "\(f) not inside \(macBookPro)")
        XCTAssertEqual(f.size, CGSize(width: 1512, height: 880))
    }

    func testAFrameOnADepartedDisplayComesBack() {
        let f = WindowFit.fit(CGRect(x: 3000, y: -900, width: 820, height: 680), minimum: CGSize(width: 820, height: 668), in: macBookPro)
        XCTAssertTrue(macBookPro.contains(f))
        XCTAssertEqual(f.size, CGSize(width: 820, height: 680))
    }

    func testAFrameThatFitsIsLeftAlone() {
        let f = CGRect(x: 100, y: 100, width: 1300, height: 800)
        XCTAssertEqual(WindowFit.fit(f, minimum: CGSize(width: 1180, height: 748), in: macBookPro), f)
    }

    func testAScreenSmallerThanTheMinimumKeepsTheTitleBarOnScreen() {
        let tiny = CGRect(x: 0, y: 0, width: 1024, height: 640)
        let f = WindowFit.fit(CGRect(x: 0, y: 0, width: 1400, height: 900), minimum: CGSize(width: 1180, height: 748), in: tiny)
        XCTAssertEqual(f.size, CGSize(width: 1180, height: 748))
        XCTAssertEqual(f.maxY, tiny.maxY, "the top edge, where the title bar is, stays on screen")
        XCTAssertEqual(f.minX, tiny.minX)
    }

    // MARK: Measured: the rails at each window

    /// What one rail needs at `width`: its flexible tail at its declared useful minimum, everything else whole.
    private func need(_ sidecar: Sidecar, column: Int, layout: OperatorLayout, width: CGFloat) -> CGSize {
        let view = OperatorRail(column: column, scrolls: false)
            .fixedSize(horizontal: false, vertical: true)
            .environment(sidecar)
            .environment(DisplayManager())
            .environment(\.operatorLayout, layout)
        return NSHostingController(rootView: view).sizeThatFits(in: CGSize(width: width, height: 10_000))
    }

    /// Lays the whole console out in an off-screen window of `content` size; answers the rails' area.
    private func railsArea(_ sidecar: Sidecar, content: CGSize) -> (rails: CGSize, console: CGSize) {
        let root = LayoutStage.console(sidecar, displays: DisplayManager())
        let w = NSWindow(contentRect: CGRect(origin: .zero, size: content), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: root)
        w.contentView = hosting
        w.setContentSize(content)
        OperatorRails.lastSize = .zero
        for _ in 0..<6 { hosting.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        let console = NSHostingController(rootView: LayoutStage.console(sidecar, displays: DisplayManager())).sizeThatFits(in: content)
        w.close()
        return (OperatorRails.lastSize, console)
    }

    /// The probe itself: offered too little, a rail answers with more, so a pass below means something.
    func testTheMeasureSeesAnOverflow() {
        let sidecar = LayoutStage.sidecar(inMeeting: true)
        let narrow = OperatorLayout(size: CGSize(width: 900, height: 400))
        let s = need(sidecar, column: 2, layout: narrow, width: 240)
        XCTAssertGreaterThan(s.width, 240, "SETTINGS' chips cannot fit 240 pt, the probe must say so: \(s)")
        let tall = need(sidecar, column: 0, layout: narrow, width: 480)
        XCTAssertGreaterThan(tall.height, 400, "a meeting's rail 0 is taller than 400 pt: \(tall)")
    }

    private func check(content: CGSize, heightMustFit: Bool, file: StaticString = #filePath, line: UInt = #line) {
        for inMeeting in [false, true] {
            let sidecar = LayoutStage.sidecar(inMeeting: inMeeting)
            let (rails, console) = railsArea(sidecar, content: content)
            let tag = "\(Int(content.width))x\(Int(content.height)) \(inMeeting ? "meeting" : "pre-meeting")"
            XCTAssertLessThanOrEqual(console.width, content.width + 0.5, "\(tag): the console needs \(console.width) pt of width", file: file, line: line)
            XCTAssertGreaterThan(rails.height, 0, "\(tag): the rails were never laid out", file: file, line: line)
            let layout = OperatorLayout(size: rails)
            let pad = ARCTheme.railPad
            let inner = CGSize(width: layout.railW - 2 * pad, height: rails.height - 2 * pad)
            for c in 0..<3 {
                let n = need(sidecar, column: c, layout: layout, width: inner.width)
                print("SIZING \(tag) rail \(c): needs \(Int(n.width))x\(Int(n.height)) of \(Int(inner.width))x\(Int(inner.height))\(layout.narrow ? " (narrow)" : "")")
                XCTAssertLessThanOrEqual(n.width, inner.width + 0.5, "\(tag) rail \(c) is \(n.width) pt wide in \(inner.width)", file: file, line: line)
                if heightMustFit {
                    XCTAssertLessThanOrEqual(n.height, inner.height + 0.5, "\(tag) rail \(c) needs \(n.height) pt, has \(inner.height)", file: file, line: line)
                }
            }
        }
    }

    /// A rail's tail declares its useful minimum for the fit test; the module itself must fit inside it, or a
    /// rail that "fits" runs past the window (the 2026-09-23 first pass: PARTICIPANTS declared 90, needed 134).
    func testEachTailFitsInsideWhatItDeclares() {
        for inMeeting in [false, true] {
            let sidecar = LayoutStage.sidecar(inMeeting: inMeeting)
            let sdk = sidecar.engine as! SDKZoomEngine
            for narrow in [true, false] {
                let layout = OperatorLayout(size: CGSize(width: narrow ? 1512 : 1920, height: 600))
                let w = layout.railW - 2 * ARCTheme.railPad
                func minimum<V: View>(_ v: V) -> CGFloat {
                    let view = v.environment(sidecar).environment(DisplayManager()).environment(\.operatorLayout, layout)
                    return NSHostingController(rootView: view).sizeThatFits(in: CGSize(width: w, height: 1)).height
                }
                let tag = "\(inMeeting ? "meeting" : "pre-meeting") \(narrow ? "narrow" : "wide")"
                let roster = minimum(RosterModule()), captions = minimum(CaptionsModule(sdk: sdk, flexible: true)), video = minimum(VideoModule(sdk: sdk))
                print("TAIL \(tag): roster \(Int(roster))/\(Int(OperatorRail.rosterTail)) captions \(Int(captions))/\(Int(OperatorRail.captionsTail)) video \(Int(video))/\(Int(OperatorRail.videoTail))")
                XCTAssertLessThanOrEqual(roster, OperatorRail.rosterTail + 0.5, tag)
                XCTAssertLessThanOrEqual(captions, OperatorRail.captionsTail + 0.5, tag)
                // VIDEO is a tail only on wide rails; on a narrow one it sits under SHARE at its natural height.
                if !narrow { XCTAssertLessThanOrEqual(video, OperatorRail.videoTail + 0.5, tag) }
            }
        }
    }

    // MARK: PREVIEW, in the OUTPUTS panel (2026-09-24)

    /// PREVIEW takes the OUTPUTS panel's spare width and the picture row's height, and never sets that height (the
    /// rails keep every point: the rail tests below still pass with it drawn). Here: at every window, for each
    /// source, its controls fit the column they are given, the pane is a usable 16:9, nothing collapses.
    func testPreviewFitsTheOutputsPanelAtEveryWindow() {
        let sizes = [CGSize(width: 1512, height: 900 - titleBar), CGSize(width: 1710, height: 1040 - titleBar), CGSize(width: 1920, height: 1040 - titleBar),
                     CGSize(width: 2056, height: 1260 - titleBar), CGSize(width: ARCTheme.consoleMinW, height: ARCTheme.consoleMinH)]
        let stages: [(String, PreviewPlayer.Source, String?)] = [
            ("file", .file(URL(fileURLWithPath: "/Show/Opening video with a long file name.mp4")), nil),
            ("camera", .camera(id: "cam", name: "Blackmagic Design"), "Blackmagic Design"),
            ("off", .off, nil),
        ]
        for size in sizes {
            for (tag, src, audio) in stages {
                let sidecar = LayoutStage.sidecar(inMeeting: true)
                sidecar.preview.stageForLayout(src, audioIn: audio, onAir: tag == "file")
                PreviewModule.lastControls = .zero; PreviewModule.lastPane = .zero
                _ = railsArea(sidecar, content: size)
                let given = PreviewModule.lastControls, pane = PreviewModule.lastPane
                let label = "\(Int(size.width))x\(Int(size.height)) \(tag)"
                XCTAssertGreaterThan(given.width, 0, "\(label): PREVIEW was never laid out")
                let need = NSHostingController(rootView: PreviewControls().fixedSize(horizontal: false, vertical: true)
                    .environment(sidecar).environment(DisplayManager())).sizeThatFits(in: CGSize(width: given.width, height: 10_000))
                print("PREVIEW \(label): controls need \(Int(need.width))x\(Int(need.height)) of \(Int(given.width))x\(Int(given.height)), pane \(Int(pane.width))x\(Int(pane.height))")
                XCTAssertLessThanOrEqual(need.width, given.width + 0.5, "\(label): the controls are wider than their column")
                XCTAssertLessThanOrEqual(need.height, given.height + 0.5, "\(label): the controls are taller than the row gives")
                XCTAssertGreaterThanOrEqual(given.width, ARCTheme.s(200) - 0.5, "\(label): the controls column collapsed")
                XCTAssertGreaterThanOrEqual(pane.height, ARCTheme.s(70), "\(label): the pane collapsed")
                XCTAssertEqual(pane.width / max(pane.height, 1), 16.0 / 9.0, accuracy: 0.05, "\(label): the pane is 16:9")
            }
        }
    }

    /// Window sizes as the operator would set them; content = window minus the title bar.
    func testAMacBookProAtItsDefaultFitsWithoutScrolling() { check(content: CGSize(width: 1512, height: 900 - titleBar), heightMustFit: true) }
    func testA1710MacBookFits() { check(content: CGSize(width: 1710, height: 1040 - titleBar), heightMustFit: true) }
    func testA1080OperatorScreenFits() { check(content: CGSize(width: 1920, height: 1040 - titleBar), heightMustFit: true) }
    func testA2056MacBookFits() { check(content: CGSize(width: 2056, height: 1260 - titleBar), heightMustFit: true) }
    /// At the minimum a rail may scroll (the last resort), but nothing may be wider than its rail.
    func testTheMinimumWindowNeverClipsSideways() { check(content: CGSize(width: ARCTheme.consoleMinW, height: ARCTheme.consoleMinH), heightMustFit: false) }
}


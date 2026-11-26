//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//


import XCTest
@testable import ArcPresenter

/// The generic window source (2026-09-18): the router drives it, the switch
/// engine takes it through its own capture, and its pure rules hold.
@MainActor
final class WindowSourceTests: XCTestCase {
    final class Recorder: LiveNavigable {
        var calls: [String] = []
        func liveNext()      { calls.append("next") }
        func livePrevious()  { calls.append("previous") }
        func liveGoToFirst() { calls.append("first") }
        func liveGoToLast()  { calls.append("last") }
    }
    final class FakeWindows: SwitchEngine.OutputWindows {
        var calls: [String] = []
        func setAlpha(_ alpha: CGFloat, of output: OutputType, over seconds: Double) async { calls.append("\(output.rawValue)=\(Int(alpha))") }
    }
    final class FakeCapture: SwitchEngine.LiveCapture {
        let name: String
        init(_ name: String) { self.name = name }
        var isRunning = false
        var lastError: String?
        var calls: [String] = []
        /// A start that takes real time, so a take can arrive while prepare() is still running.
        var startDelayNanos: UInt64 = 0
        func start() async -> Bool {
            if startDelayNanos > 0 { try? await Task.sleep(nanoseconds: startDelayNanos) }
            calls.append("start"); isRunning = true; return true
        }
        func stop() async { calls.append("stop"); isRunning = false }
    }

    // MARK: router

    func testRouterDrivesTheWindowWhenItIsLive() {
        let deck = Recorder(), ppt = Recorder(), win = Recorder()
        let router = SourceRouter(deck: deck, powerPoint: ppt, window: win, deckBlack: {}, windowBundleID: { "com.apple.iWork.Keynote" }, frontmostBundleID: { nil })
        router.live = .window
        router.next(); router.previous(); router.first(); router.last()
        XCTAssertEqual(win.calls, ["next", "previous", "first", "last"])
        XCTAssertTrue(deck.calls.isEmpty); XCTAssertTrue(ppt.calls.isEmpty)
        XCTAssertFalse(router.acceptsDeckOnlyCommands)
    }

    func testGlobalTapIsDroppedWhenTheParkedAppItselfIsFrontmost() {
        let deck = Recorder(), ppt = Recorder(), win = Recorder()
        var frontmost: String? = "com.apple.iWork.Keynote"
        let router = SourceRouter(deck: deck, powerPoint: ppt, window: win, deckBlack: {}, windowBundleID: { "com.apple.iWork.Keynote" }, frontmostBundleID: { frontmost })
        router.live = .window
        router.globalNext()
        XCTAssertEqual(win.calls, [], "Keynote already got the key; forwarding it would advance twice")
        frontmost = "com.apple.finder"
        router.globalNext()
        XCTAssertEqual(win.calls, ["next"])
    }

    func testRouterWithoutAWindowSourceIgnoresWindowClicks() {
        let deck = Recorder(), ppt = Recorder()
        let router = SourceRouter(deck: deck, powerPoint: ppt, deckBlack: {}, frontmostBundleID: { nil })
        router.live = .window
        router.next()
        XCTAssertTrue(deck.calls.isEmpty && ppt.calls.isEmpty)
    }

    // MARK: switch engine

    func testTakeWindowUsesTheWindowCaptureAndRoutesClicksToTheWindow() async {
        let deck = Recorder(), ppt = Recorder(), win = Recorder()
        let router = SourceRouter(deck: deck, powerPoint: ppt, window: win, deckBlack: {}, frontmostBundleID: { nil })
        let pptCap = FakeCapture("ppt"), winCap = FakeCapture("win")
        var mutes: [String] = []
        let engine = SwitchEngine(router: router, capture: pptCap, windowCapture: winCap,
                                  powerPointIsReady: { false }, windowIsReady: { true },
                                  silenceDeck: {}, restoreDeck: {},
                                  mutePowerPoint: { mutes.append("mute ppt") }, unmutePowerPoint: { mutes.append("unmute ppt") },
                                  muteWindow: { mutes.append("mute win") }, unmuteWindow: { mutes.append("unmute win") },
                                  windows: FakeWindows())
        engine.fadeSeconds = 0
        let r1 = await engine.takePowerPoint(); XCTAssertFalse(r1, "PowerPoint is not ready")
        let r2 = await engine.takeWindow(); XCTAssertTrue(r2)
        XCTAssertEqual(engine.liveSource, .window)
        XCTAssertEqual(router.live, .window)
        XCTAssertEqual(winCap.calls, ["start"]); XCTAssertTrue(pptCap.calls.isEmpty)
        XCTAssertEqual(mutes, ["unmute win"])
        router.next()
        XCTAssertEqual(win.calls, ["next"])
        let r3 = await engine.returnToDeck(); XCTAssertTrue(r3)
        XCTAssertEqual(engine.liveSource, .deck)
        XCTAssertEqual(router.live, .deck)
        XCTAssertEqual(mutes, ["unmute win", "mute win"])
        XCTAssertTrue(winCap.isRunning, "the picture keeps running for the next take")
    }

    /// Picking a window in the popover starts prepare() in a task. An operator who hits TAKE WINDOW
    /// straight after arrives while it is still running: measured at 0.12 s on the office workstation drill
    /// (2026-09-18), and the take was dropped with no log line and no lastError, leaving "armed
    /// window, live deck" and nothing to explain it. The take must WAIT for the prepare.
    func testATakeDuringPrepareWaitsInsteadOfBeingDroppedSilently() async {
        let router = SourceRouter(deck: Recorder(), powerPoint: Recorder(), window: Recorder(), deckBlack: {}, frontmostBundleID: { nil })
        let winCap = FakeCapture("win")
        winCap.startDelayNanos = 250_000_000
        let engine = SwitchEngine(router: router, capture: FakeCapture("ppt"), windowCapture: winCap,
                                  powerPointIsReady: { false }, windowIsReady: { true },
                                  silenceDeck: {}, restoreDeck: {}, windows: FakeWindows())
        engine.fadeSeconds = 0

        async let prepared: Bool = engine.prepare(.window)
        try? await Task.sleep(nanoseconds: 40_000_000)   // the operator hits TAKE 0.04 s later
        XCTAssertTrue(engine.isPreparing, "the drill's race: the take lands mid-prepare")
        let took = await engine.takeWindow()
        _ = await prepared

        XCTAssertTrue(took, "the take waited for the prepare instead of being dropped")
        XCTAssertEqual(engine.liveSource, .window)
        XCTAssertEqual(router.live, .window)
    }

    func testTakeWindowIsRefusedUntilAWindowIsAttached() async {
        let router = SourceRouter(deck: Recorder(), powerPoint: Recorder(), window: Recorder(), deckBlack: {}, frontmostBundleID: { nil })
        let engine = SwitchEngine(router: router, capture: FakeCapture("ppt"), windowCapture: FakeCapture("win"),
                                  powerPointIsReady: { true }, windowIsReady: { false },
                                  silenceDeck: {}, restoreDeck: {}, windows: FakeWindows())
        engine.fadeSeconds = 0
        let r4 = await engine.takeWindow(); XCTAssertFalse(r4)
        XCTAssertEqual(engine.lastError, "no window is attached and ready")
        XCTAssertEqual(engine.liveSource, .deck)
        let r5 = await engine.takePowerPoint(); XCTAssertTrue(r5, "PowerPoint is still the armed source")
        XCTAssertEqual(engine.liveSource, .powerpoint)
    }

    func testArmIsRefusedWhileASourceIsLive() async {
        let router = SourceRouter(deck: Recorder(), powerPoint: Recorder(), window: Recorder(), deckBlack: {}, frontmostBundleID: { nil })
        let engine = SwitchEngine(router: router, capture: FakeCapture("ppt"), windowCapture: FakeCapture("win"),
                                  powerPointIsReady: { true }, windowIsReady: { true },
                                  silenceDeck: {}, restoreDeck: {}, windows: FakeWindows())
        engine.fadeSeconds = 0
        XCTAssertTrue(engine.arm(.window))
        XCTAssertTrue(engine.isExternalArmed(.window))
        XCTAssertFalse(engine.arm(.deck), "the deck is not an external source")
        let r6 = await engine.take(.powerpoint); XCTAssertTrue(r6, "a take arms its own source")
        XCTAssertTrue(engine.isExternalArmed(.powerpoint))
        XCTAssertFalse(engine.arm(.window), "not while PowerPoint is live")
        XCTAssertTrue(engine.stateJSON.contains("\"live\":\"powerpoint\""))
        XCTAssertTrue(engine.stateJSON.contains("\"armed\":\"powerpoint\""))
    }

    func testSourceLostWhileTheWindowIsLiveReturnsToTheDeck() async {
        let router = SourceRouter(deck: Recorder(), powerPoint: Recorder(), window: Recorder(), deckBlack: {}, frontmostBundleID: { nil })
        var mutes: [String] = []
        let engine = SwitchEngine(router: router, capture: FakeCapture("ppt"), windowCapture: FakeCapture("win"),
                                  powerPointIsReady: { false }, windowIsReady: { true },
                                  silenceDeck: {}, restoreDeck: {},
                                  muteWindow: { mutes.append("mute") }, unmuteWindow: { mutes.append("unmute") }, windows: FakeWindows())
        engine.fadeSeconds = 0
        let r7 = await engine.takeWindow(); XCTAssertTrue(r7)
        await engine.sourceLost("Keynote quit")
        XCTAssertEqual(engine.liveSource, .deck)
        XCTAssertEqual(engine.lastError, "Keynote quit")
        XCTAssertEqual(mutes, ["unmute", "unmute", "mute"], "released on the loss, then the return's mute (a no-op on a gone app)")
    }

    // MARK: pure rules

    func testClickerKeysAreArrowsAndHomeEnd() {
        XCTAssertEqual(WindowSource.keyCode(for: .next), 124)
        XCTAssertEqual(WindowSource.keyCode(for: .previous), 123)
        XCTAssertEqual(WindowSource.keyCode(for: .first), 115)
        XCTAssertEqual(WindowSource.keyCode(for: .last), 119)
    }

    func testCandidateWindowsAreRealOnScreenWindowsOfOtherApps() {
        let big = CGSize(width: 1280, height: 720), min = CGSize(width: 320, height: 200)
        XCTAssertTrue(WindowSource.isCandidate(bundleID: "com.apple.iWork.Keynote", own: "com.arc.presenter", layer: 0, size: big, minSize: min))
        XCTAssertFalse(WindowSource.isCandidate(bundleID: "com.arc.presenter", own: "com.arc.presenter", layer: 0, size: big, minSize: min), "never Presenter's own windows")
        XCTAssertFalse(WindowSource.isCandidate(bundleID: "", own: "com.arc.presenter", layer: 0, size: big, minSize: min), "no bundle, no app to post keys to")
        XCTAssertFalse(WindowSource.isCandidate(bundleID: "com.apple.dock", own: "com.arc.presenter", layer: 20, size: big, minSize: min), "menu bar, dock, overlays")
        XCTAssertFalse(WindowSource.isCandidate(bundleID: "com.apple.finder", own: "com.arc.presenter", layer: 0, size: CGSize(width: 300, height: 100), minSize: min), "palettes")
    }

    func testParkFrameKeepsTheAspectAndCentresOnTheProgramDisplay() {
        let display = CGRect(x: 1920, y: 0, width: 1920, height: 1080)
        let sixteenNine = WindowSource.parkFrame(for: CGSize(width: 1280, height: 720), in: display)
        XCTAssertEqual(sixteenNine, CGRect(x: 1920, y: 0, width: 1920, height: 1080), "a 16:9 window fills the 16:9 display")
        let fourThree = WindowSource.parkFrame(for: CGSize(width: 1024, height: 768), in: display)
        XCTAssertEqual(fourThree, CGRect(x: 2160, y: 0, width: 1440, height: 1080), "pillarboxed, centred")
        let huge = WindowSource.parkFrame(for: CGSize(width: 3840, height: 2160), in: display)
        XCTAssertEqual(huge, CGRect(x: 1920, y: 0, width: 1920, height: 1080), "shrunk to fit, never enlarged past the display")
        let smallOnBig = WindowSource.parkFrame(for: CGSize(width: 960, height: 540), in: display)
        XCTAssertEqual(smallOnBig.size, CGSize(width: 1920, height: 1080), "a small window is enlarged to fill")
    }

    func testCocoaFrameConvertsToTopLeftGlobalSpace() {
        // Main 2048x1152; a 1920x1280 display to its right, bottoms aligned: Cocoa y = 0 .. 1280,
        // so its top sits 128 pt above the main's top: top-left y = -128.
        let cocoa = CGRect(x: 2048, y: 0, width: 1920, height: 1280)
        XCTAssertEqual(WindowSource.topLeft(cocoa, mainHeight: 1152), CGRect(x: 2048, y: -128, width: 1920, height: 1280))
        // Tops aligned instead (Cocoa y = -128 .. 1152): top-left y = 0.
        XCTAssertEqual(WindowSource.topLeft(CGRect(x: 2048, y: -128, width: 1920, height: 1280), mainHeight: 1152).minY, 0)
        // A display above the main one: Cocoa y = 1152 .. 2232 sits at top-left y = -1080.
        XCTAssertEqual(WindowSource.topLeft(CGRect(x: 0, y: 1152, width: 1920, height: 1080), mainHeight: 1152), CGRect(x: 0, y: -1080, width: 1920, height: 1080))
    }

    func testListJSONEscapesTitles() {
        let pick = WindowSource.Pick(windowID: 7, ownerPID: 42, bundleID: "com.apple.iWork.Keynote", appName: "Keynote", title: "1.29 \"Demo\" Info", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let json = WindowSource.listJSON([pick])
        XCTAssertTrue(json.contains("\"title\":\"1.29 \\\"Demo\\\" Info\""), json)
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: Data(json.utf8)))
    }
}

/// LET GO sends the window home (2026-09-19).
final class WindowSourceHomeFrameTests: XCTestCase {
    let control = CGRect(x: 0, y: 0, width: 2048, height: 1152)
    let program = CGRect(x: 2048, y: -128, width: 1920, height: 1280)
    var screens: [CGRect] { [control, program] }

    func testAWindowFromTheControlMonitorGoesBackExactlyWhereItWas() {
        let original = CGRect(x: 9, y: 166, width: 1578, height: 932)
        XCTAssertEqual(WindowSource.homeFrame(original: original, program: program, control: control, screens: screens), original)
    }

    func testAWindowThatLivedOnTheProgramDisplayComesToTheControlMonitor() {
        let original = CGRect(x: 2100, y: 100, width: 1200, height: 800)
        let home = WindowSource.homeFrame(original: original, program: program, control: control, screens: screens)
        XCTAssertTrue(control.contains(home), "on the control monitor")
        XCTAssertEqual(home.size, original.size, "same size when it fits")
        XCTAssertEqual(home.midX, control.midX, accuracy: 1); XCTAssertEqual(home.midY, control.midY, accuracy: 1)
    }

    func testAWindowFromADisplayThatWentAwayComesToTheControlMonitorFitted() {
        let original = CGRect(x: 6000, y: 0, width: 3000, height: 2000)
        let home = WindowSource.homeFrame(original: original, program: program, control: control, screens: screens)
        XCTAssertTrue(control.contains(home))
        XCTAssertLessThanOrEqual(home.width, control.width); XCTAssertLessThanOrEqual(home.height, control.height)
        XCTAssertEqual(home.width / home.height, 1.5, accuracy: 0.01, "aspect kept")
    }

    func testOneDisplayLeavesTheWindowWhereItWas() {
        let original = CGRect(x: 100, y: 100, width: 800, height: 600)
        XCTAssertEqual(WindowSource.homeFrame(original: original, program: control, control: control, screens: [control]), original, "the control monitor IS the program display: no move")
    }

    func testNoControlMonitorMeansTheOriginal() {
        let original = CGRect(x: 2100, y: 100, width: 1200, height: 800)
        XCTAssertEqual(WindowSource.homeFrame(original: original, program: program, control: nil, screens: screens), original)
    }

    /// Zoom drill 2026-09-20: an unparked window streamed at the PROGRAM's pixel size was drawn at
    /// native pixels, offset and clipped. The stream is the window's own size at the display scale,
    /// whole even pixels, never below 2x2.
    func testStreamSizeIsTheWindowsOwnPixels() {
        XCTAssertEqual(WindowCapture.streamSize(for: CGSize(width: 1309, height: 1122), scale: 2), CGSize(width: 2618, height: 2244))
        XCTAssertEqual(WindowCapture.streamSize(for: CGSize(width: 1309.5, height: 1122), scale: 1), CGSize(width: 1308, height: 1122))
        XCTAssertEqual(WindowCapture.streamSize(for: CGSize(width: 641, height: 0.4), scale: 1), CGSize(width: 640, height: 2))
        XCTAssertEqual(WindowCapture.streamSize(for: CGSize(width: 100, height: 50), scale: 0), CGSize(width: 100, height: 50))
    }

    /// PLAN_zoom_source step 2: Zoom windows send keys to the deck and never mute on RETURN; every
    /// other app keeps PowerPoint's rules; an operator override wins either way.
    func testZoomWindowsDriveTheDeckAndNeverMute() {
        XCTAssertFalse(WindowSource.clickerDrivesWindow(bundleID: "us.zoom.xos", override: nil))
        XCTAssertFalse(WindowSource.mutesOnReturn(bundleID: "us.zoom.xos", override: nil))
        XCTAssertTrue(WindowSource.clickerDrivesWindow(bundleID: "com.apple.iWork.Keynote", override: nil))
        XCTAssertTrue(WindowSource.mutesOnReturn(bundleID: "com.apple.iWork.Keynote", override: nil))
        XCTAssertTrue(WindowSource.clickerDrivesWindow(bundleID: nil, override: nil))
        XCTAssertTrue(WindowSource.clickerDrivesWindow(bundleID: "us.zoom.xos", override: true))
        XCTAssertFalse(WindowSource.mutesOnReturn(bundleID: "com.apple.iWork.Keynote", override: false))
    }

    /// The per-source knobs are ONE profile: the rule for the app, the operator's overrides on top.
    func testSourceProfileRuleAndOverrides() {
        let zoom = WindowSource.SourceProfile.rule(for: "us.zoom.xos")
        XCTAssertEqual(zoom, .zoom); XCTAssertFalse(zoom.clickerDrivesWindow); XCTAssertFalse(zoom.mutesOnReturn); XCTAssertEqual(zoom.cropTop, 44)
        XCTAssertEqual(WindowSource.SourceProfile.rule(for: "com.apple.iWork.Keynote"), .slideshow)
        // ARC Zoom draws its own borderless windows: a Zoom source with nothing to crop.
        let sidecar = WindowSource.SourceProfile.rule(for: "com.example.arc.ArcZoom")
        XCTAssertEqual(sidecar, .arcZoom)
        XCTAssertFalse(sidecar.clickerDrivesWindow); XCTAssertFalse(sidecar.mutesOnReturn)
        XCTAssertEqual(sidecar.cropTop, 0, "our own window has no title strip")
        XCTAssertEqual(WindowSource.SourceProfile.rule(for: nil), .slideshow)
        let over = zoom.overriding(clicker: true, mute: nil, cropTop: 0)
        XCTAssertTrue(over.clickerDrivesWindow); XCTAssertFalse(over.mutesOnReturn); XCTAssertEqual(over.cropTop, 0)
        XCTAssertEqual(WindowSource.SourceProfile.slideshow.overriding(clicker: nil, mute: nil, cropTop: -5).cropTop, 0, "never negative")
    }

    /// The crop as the layer wants it: unit space, origin bottom-left, so the TOP comes off by keeping less height.
    func testContentsRectCutsTheTop() {
        XCTAssertEqual(WindowCapture.contentsRect(cropTop: 28, windowHeight: 720), CGRect(x: 0, y: 0, width: 1, height: 1 - 28.0 / 720.0))
        XCTAssertEqual(WindowCapture.contentsRect(cropTop: 0, windowHeight: 720), CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertEqual(WindowCapture.contentsRect(cropTop: 28, windowHeight: 30), CGRect(x: 0, y: 0, width: 1, height: 1), "a window shorter than the strip is left alone")
    }
}

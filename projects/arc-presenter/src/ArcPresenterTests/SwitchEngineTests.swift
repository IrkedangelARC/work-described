//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import XCTest
@testable import ArcPresenter

@MainActor
final class SwitchEngineTests: XCTestCase {
    final class Recorder: LiveNavigable {
        var calls: [String] = []
        func liveNext()      { calls.append("next") }
        func livePrevious()  { calls.append("previous") }
        func liveGoToFirst() { calls.append("first") }
        func liveGoToLast()  { calls.append("last") }
    }
    /// Records every alpha the engine asks for, in order.
    final class FakeWindows: SwitchEngine.OutputWindows {
        var calls: [String] = []
        func setAlpha(_ alpha: CGFloat, of output: OutputType, over seconds: Double) async {
            calls.append("\(output.rawValue)=\(Int(alpha))")
        }
    }
    final class FakeCapture: SwitchEngine.LiveCapture {
        var isRunning = false
        var lastError: String?
        var startResult = true
        var calls: [String] = []
        func start() async -> Bool { calls.append("start"); isRunning = startResult; if !startResult { lastError = "no permission" }; return startResult }
        func stop() async { calls.append("stop"); isRunning = false }
    }

    var deck: Recorder!
    var powerPoint: Recorder!
    var windows: FakeWindows!
    var capture: FakeCapture!
    var deckCalls: [String] = []
    var router: SourceRouter!
    var ready = true
    var engine: SwitchEngine!

    override func setUp() {
        super.setUp()
        deck = Recorder(); powerPoint = Recorder(); windows = FakeWindows(); capture = FakeCapture(); deckCalls = []; ready = true
        router = SourceRouter(deck: deck, powerPoint: powerPoint, deckBlack: {}, frontmostBundleID: { nil })
        engine = SwitchEngine(router: router, capture: capture, powerPointIsReady: { [unowned self] in self.ready },
                              silenceDeck: { [unowned self] in self.deckCalls.append("silence") },
                              restoreDeck: { [unowned self] in self.deckCalls.append("restore") }, windows: windows)
        engine.fadeSeconds = 0
    }

    // MARK: composite (default)

    func testDefaultModeIsCompositeSoTheProgramWindowNeverGoesTransparent() async {
        XCTAssertEqual(engine.mode, .composite)
        await engine.takePowerPoint()
        XCTAssertFalse(windows.calls.contains("program-output=0"), "an opaque program window is what keeps the menu bar covered")
    }

    func testTakeIsRefusedUntilPowerPointIsParkedAndReady() async {
        ready = false
        let r1 = await engine.takePowerPoint()
        XCTAssertFalse(r1)
        XCTAssertEqual(engine.state, .deck)
        XCTAssertEqual(router.live, .deck)
        XCTAssertEqual(windows.calls, [])
        XCTAssertEqual(capture.calls, [])
        XCTAssertNotNil(engine.lastError)
    }

    func testCompositeTakeStartsTheCaptureBeforeAnythingFades() async {
        let r2 = await engine.takePowerPoint()
        XCTAssertTrue(r2)
        XCTAssertEqual(capture.calls, ["start"])
        XCTAssertEqual(engine.state, .powerpoint)
        XCTAssertEqual(engine.veil, 1, "the deck is under black")
        XCTAssertEqual(engine.reveal, 1, "the captured picture is up")
        XCTAssertEqual(windows.calls, ["confidence-monitor=0"], "only the confidence window goes transparent, for Presenter View")
        XCTAssertEqual(router.live, .powerpoint)
        router.next()
        XCTAssertEqual(powerPoint.calls, ["next"])
        XCTAssertEqual(deck.calls, [])
    }

    func testPrepareStartsTheCaptureAndLeavesTheDeckLive() async {
        let r = await engine.prepare()
        XCTAssertTrue(r)
        XCTAssertEqual(capture.calls, ["start"])
        XCTAssertEqual(engine.state, .deck)
        XCTAssertEqual(engine.veil, 0)
        XCTAssertEqual(router.live, .deck)
        // A take after prepare does not start the capture again.
        let took = await engine.takePowerPoint()
        XCTAssertTrue(took)
        XCTAssertEqual(capture.calls, ["start"])
    }

    func testPrepareIsRefusedUntilPowerPointIsReady() async {
        ready = false
        let r = await engine.prepare()
        XCTAssertFalse(r)
        XCTAssertEqual(capture.calls, [])
    }

    func testCompositeTakeFailsCleanlyWhenTheCaptureCannotStart() async {
        capture.startResult = false
        let r3 = await engine.takePowerPoint()
        XCTAssertFalse(r3)
        XCTAssertEqual(engine.state, .deck)
        XCTAssertEqual(engine.veil, 0, "nothing faded: the audience never saw black")
        XCTAssertEqual(engine.reveal, 0)
        XCTAssertEqual(windows.calls, [])
        XCTAssertEqual(router.live, .deck)
        XCTAssertEqual(engine.lastError, "no permission")
    }

    func testCompositeBlackIsTheRevealNotAWindowAlpha() async {
        await engine.takePowerPoint()
        windows.calls = []
        XCTAssertTrue(router.toggleBlack(), "black routes to the switch engine, not the deck")
        await engine.blackFade?.value
        XCTAssertTrue(engine.powerPointBlack)
        XCTAssertEqual(engine.reveal, 0, "the picture drops to the black veil")
        XCTAssertEqual(windows.calls, [])
        XCTAssertTrue(router.toggleBlack())
        await engine.blackFade?.value
        XCTAssertFalse(engine.powerPointBlack)
        XCTAssertEqual(engine.reveal, 1)
        XCTAssertEqual(powerPoint.calls, [], "nothing is sent to PowerPoint for black")
    }

    func testCompositeReturnDropsThePictureRestoresConfidenceLiftsTheVeilKeepsCapture() async {
        await engine.takePowerPoint()
        windows.calls = []; capture.calls = []
        let r4 = await engine.returnToDeck()
        XCTAssertTrue(r4)
        XCTAssertEqual(engine.state, .deck)
        XCTAssertEqual(engine.reveal, 0)
        XCTAssertEqual(engine.veil, 0)
        XCTAssertEqual(windows.calls, ["confidence-monitor=1"])
        XCTAssertEqual(capture.calls, [], "the capture keeps feeding the SOURCES thumbnail until PowerPoint is closed")
        XCTAssertTrue(capture.isRunning)
        XCTAssertFalse(engine.powerPointBlack)
        XCTAssertEqual(router.live, .deck)
        router.next()
        XCTAssertEqual(deck.calls, ["next"])
    }

    func testTakeSilencesTheDeck_ReturnRestoresIt() async {
        await engine.takePowerPoint()
        XCTAssertEqual(deckCalls, ["silence"], "a clip hidden under the veil must not keep sounding")
        await engine.returnToDeck()
        XCTAssertEqual(deckCalls, ["silence", "restore"], "the same players come back; the clip never stopped")
    }

    func testRefusedTakeDoesNotTouchTheDeck() async {
        ready = false
        await engine.takePowerPoint()
        XCTAssertEqual(deckCalls, [])
    }

    // MARK: transparent (fallback)

    func testTransparentTakeFadesBothWindowsOutAndNeverStartsTheCapture() async {
        engine.mode = .transparent
        let r5 = await engine.takePowerPoint()
        XCTAssertTrue(r5)
        XCTAssertEqual(capture.calls, [])
        XCTAssertEqual(engine.veil, 1)
        XCTAssertEqual(engine.reveal, 0)
        XCTAssertEqual(Set(windows.calls), ["program-output=0", "confidence-monitor=0"])
        XCTAssertEqual(router.live, .powerpoint)
    }

    func testTransparentBlackIsTheProgramWindowAlpha() async {
        engine.mode = .transparent
        await engine.takePowerPoint()
        windows.calls = []
        XCTAssertTrue(router.toggleBlack())
        await engine.blackFade?.value
        XCTAssertEqual(windows.calls, ["program-output=1"])
        XCTAssertTrue(router.toggleBlack())
        await engine.blackFade?.value
        XCTAssertEqual(windows.calls, ["program-output=1", "program-output=0"])
    }

    func testTransparentReturnBringsTheWindowsBackThenLiftsTheVeil() async {
        engine.mode = .transparent
        await engine.takePowerPoint()
        windows.calls = []
        let r6 = await engine.returnToDeck()
        XCTAssertTrue(r6)
        XCTAssertEqual(engine.state, .deck)
        XCTAssertEqual(Set(windows.calls), ["program-output=1", "confidence-monitor=1"])
        XCTAssertEqual(engine.veil, 0)
        XCTAssertEqual(router.live, .deck)
    }

    // MARK: guards

    func testTakeTwiceIsANoOp() async {
        await engine.takePowerPoint()
        windows.calls = []; capture.calls = []
        let r7 = await engine.takePowerPoint()
        XCTAssertFalse(r7)
        XCTAssertEqual(windows.calls, [])
        XCTAssertEqual(capture.calls, [])
    }

    func testReturnWithoutATakeIsANoOp() async {
        let r8 = await engine.returnToDeck()
        XCTAssertFalse(r8)
        XCTAssertEqual(windows.calls, [])
    }

    func testBlackOnTheDeckIsUntouchedByTheEngine() {
        XCTAssertTrue(router.toggleBlack())
        XCTAssertFalse(engine.powerPointBlack)
        XCTAssertEqual(windows.calls, [])
        XCTAssertEqual(engine.reveal, 0)
    }

    // MARK: source lost (audit 2026-09-16, R4)

    func testSourceLostWhileLiveReturnsToTheDeckAndSaysWhy() async {
        await engine.takePowerPoint()
        XCTAssertEqual(engine.state, .powerpoint)
        await engine.sourceLost("PowerPoint quit")
        XCTAssertEqual(engine.state, .deck)
        XCTAssertEqual(router.live, .deck)
        XCTAssertEqual(engine.lastError, "PowerPoint quit")
        XCTAssertEqual(deckCalls, ["silence", "restore"], "the deck's audio comes back with the picture")
    }

    func testSourceLostWhileOnTheDeckOnlyRecordsTheReason() async {
        await engine.sourceLost("the PowerPoint capture stopped")
        XCTAssertEqual(engine.state, .deck)
        XCTAssertEqual(engine.lastError, "the PowerPoint capture stopped")
        XCTAssertEqual(windows.calls, [])
    }
}

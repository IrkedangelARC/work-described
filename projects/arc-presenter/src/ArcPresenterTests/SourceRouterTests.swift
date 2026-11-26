//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import XCTest
@testable import ArcPresenter

@MainActor
final class SourceRouterTests: XCTestCase {
    final class Recorder: LiveNavigable {
        var calls: [String] = []
        func liveNext()      { calls.append("next") }
        func livePrevious()  { calls.append("previous") }
        func liveGoToFirst() { calls.append("first") }
        func liveGoToLast()  { calls.append("last") }
    }

    var deck: Recorder!
    var powerPoint: Recorder!
    var deckBlacks = 0
    var frontmost: String?
    var router: SourceRouter!

    override func setUp() {
        super.setUp()
        deck = Recorder()
        powerPoint = Recorder()
        deckBlacks = 0
        frontmost = nil
        router = SourceRouter(deck: deck, powerPoint: powerPoint,
                              deckBlack: { [unowned self] in self.deckBlacks += 1 },
                              frontmostBundleID: { [unowned self] in self.frontmost })
    }

    func testDefaultsToDeckSoV3BehaviourIsUnchanged() {
        XCTAssertEqual(router.live, .deck)
        router.next(); router.previous(); router.first(); router.last()
        XCTAssertEqual(deck.calls, ["next", "previous", "first", "last"])
        XCTAssertEqual(powerPoint.calls, [])
    }

    func testPowerPointLiveRoutesEveryNavigationCommandToPowerPoint() {
        router.live = .powerpoint
        router.next(); router.previous(); router.first(); router.last()
        XCTAssertEqual(powerPoint.calls, ["next", "previous", "first", "last"])
        XCTAssertEqual(deck.calls, [], "the deck nobody can see must not move")
    }

    func testBlackOnDeckBlacksTheDeck() {
        XCTAssertTrue(router.toggleBlack())
        XCTAssertEqual(deckBlacks, 1)
    }

    func testBlackOnPowerPointIsRefusedNotAppliedToTheDeck() {
        router.live = .powerpoint
        XCTAssertFalse(router.toggleBlack())
        XCTAssertEqual(deckBlacks, 0)
    }

    func testDeckOnlyCommandsFollowTheLiveSource() {
        XCTAssertTrue(router.acceptsDeckOnlyCommands)
        router.live = .powerpoint
        XCTAssertFalse(router.acceptsDeckOnlyCommands)
    }

    func testGlobalTapSkipsWhenPowerPointIsLiveAndFrontmost() {
        // PowerPoint already received the key natively; forwarding it would advance twice.
        router.live = .powerpoint
        frontmost = PowerPointSource.bundleID
        router.globalNext(); router.globalPrevious()
        XCTAssertEqual(powerPoint.calls, [])
        XCTAssertEqual(deck.calls, [])
    }

    func testGlobalTapForwardsWhenPowerPointIsLiveButAnotherAppIsFrontmost() {
        router.live = .powerpoint
        frontmost = "com.apple.finder"
        router.globalNext(); router.globalPrevious()
        XCTAssertEqual(powerPoint.calls, ["next", "previous"])
    }

    func testGlobalTapStillDrivesTheDeckWhenPowerPointIsMerelyFrontmost() {
        // V3 behaviour: the clicker drives the live deck whatever app is in front.
        frontmost = PowerPointSource.bundleID
        router.globalNext()
        XCTAssertEqual(deck.calls, ["next"])
    }

    /// PLAN_zoom_source step 2 (2026-09-20): a live window whose app is not a slideshow (Zoom) sends
    /// the keys to the DECK, accepts deck-only commands, and its app being frontmost never swallows a tap.
    func testWindowThatDoesNotKeepKeysDrivesTheDeck() {
        let window = Recorder()
        var keeps = false
        let r = SourceRouter(deck: deck, powerPoint: powerPoint, window: window,
                             deckBlack: { [unowned self] in self.deckBlacks += 1 },
                             windowBundleID: { "us.zoom.xos" },
                             windowKeepsKeys: { keeps },
                             frontmostBundleID: { "us.zoom.xos" })
        r.live = .window
        r.next(); r.previous(); r.globalNext()
        XCTAssertEqual(deck.calls, ["next", "previous", "next"])
        XCTAssertEqual(window.calls, [])
        XCTAssertTrue(r.acceptsDeckOnlyCommands)
        keeps = true
        r.next(); r.globalNext()
        XCTAssertEqual(window.calls, ["next"], "with keys kept, the tap is swallowed because Zoom is frontmost")
        XCTAssertFalse(r.acceptsDeckOnlyCommands)
    }

    /// Step 1b: CLICKER OFF drops the GLOBAL tap only; direct keys, menu and API still drive the deck.
    func testClickerOffDropsOnlyTheGlobalTap() {
        router.globalClickerOn = false
        router.globalNext(); router.globalPrevious()
        XCTAssertEqual(deck.calls, [], "the tap is dropped")
        router.next(); router.previous()
        XCTAssertEqual(deck.calls, ["next", "previous"], "the operator's own keys still work")
        router.globalClickerOn = true
        router.globalNext()
        XCTAssertEqual(deck.calls, ["next", "previous", "next"])
    }
}

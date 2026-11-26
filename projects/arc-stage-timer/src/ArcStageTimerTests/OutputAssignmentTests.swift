//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

#if os(macOS)
import XCTest
@testable import ARC_Stage_Timer

/// The OUTPUTS assignment rules (2026-09-24): remembered by display identity, never by index; kept through an
/// unplug; warnings for the control display, the built-in screen, a shared display, an unplugged one.
final class OutputAssignmentTests: XCTestCase {
    // The rules below were written with the KEY OVERLAY enabled (1.3.3 behaviour); the OFF rules have their own
    // tests at the end. The setting is restored after each test.
    private var keyWas = false
    override func setUp() { super.setUp(); keyWas = KeyOverlaySetting.isEnabled; KeyOverlaySetting.isEnabled = true }
    override func tearDown() { KeyOverlaySetting.isEnabled = keyWas; super.tearDown() }

    // A MacBook (built-in, primary) with two externals, left to right.
    private let laptop = DisplayInfo(id: "UUID-BUILTIN", name: "Built-in Retina Display", index: 1,
                                     frame: CGRect(x: 0, y: 0, width: 1512, height: 982), pixelWidth: 3024, pixelHeight: 1964,
                                     isPrimary: true, isBuiltIn: true)
    private let lg = DisplayInfo(id: "UUID-LG", name: "LG 27UK850", index: 2,
                                 frame: CGRect(x: 1512, y: 0, width: 1920, height: 1080), pixelWidth: 3840, pixelHeight: 2160,
                                 isPrimary: false, isBuiltIn: false)
    private let tv = DisplayInfo(id: "UUID-TV", name: "SONY TV", index: 3,
                                 frame: CGRect(x: 3432, y: 0, width: 1920, height: 1080), pixelWidth: 1920, pixelHeight: 1080,
                                 isPrimary: false, isBuiltIn: false)

    private func moved(_ d: DisplayInfo, index: Int, id: String? = nil) -> DisplayInfo {
        DisplayInfo(id: id ?? d.id, name: d.name, index: index, frame: d.frame, pixelWidth: d.pixelWidth,
                    pixelHeight: d.pixelHeight, isPrimary: d.isPrimary, isBuiltIn: d.isBuiltIn)
    }

    // MARK: Identity and persistence

    func testNotSetByDefault() {
        let book = OutputAssignmentBook()
        XCTAssertEqual(book.state(.stage, among: [laptop, lg]), .notSet)
        XCTAssertEqual(book.state(.confidence, among: [laptop, lg]), .notSet)
    }

    func testAssignmentFollowsDisplayIdentityNotIndex() {
        var book = OutputAssignmentBook()
        book.assign(.stage, to: tv)          // display 3 today
        // Replugged in another order: the TV is display 2 now, the LG display 3.
        let reordered = [laptop, moved(tv, index: 2), moved(lg, index: 3)]
        XCTAssertEqual(book.state(.stage, among: reordered).display?.id, "UUID-TV")
        XCTAssertEqual(book.state(.stage, among: reordered).display?.index, 2)
    }

    func testPersistsAcrossRelaunch() throws {
        let suite = "OutputAssignmentTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var book = OutputAssignmentBook()
        book.assign(.stage, to: lg)
        book.assign(.confidence, to: tv)
        book.assign(.control, to: laptop)
        book.save(to: defaults)

        let reloaded = OutputAssignmentBook.load(from: defaults, displays: [laptop, lg, tv])
        XCTAssertEqual(reloaded, book)
        XCTAssertEqual(reloaded.state(.stage, among: [laptop, lg, tv]).display?.name, "LG 27UK850")
        XCTAssertEqual(reloaded.state(.confidence, among: [laptop, lg, tv]).display?.name, "SONY TV")
    }

    func testMigratesTheOneTwoUUIDOnlyFormat() throws {
        let suite = "OutputAssignmentTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["stage": "UUID-LG", "control": "UUID-GONE"], forKey: OutputAssignmentBook.legacyKey)

        let book = OutputAssignmentBook.load(from: defaults, displays: [laptop, lg])
        XCTAssertEqual(book.state(.stage, among: [laptop, lg]).display?.name, "LG 27UK850")
        // A display 1.2 remembered but that is not here is kept, as unplugged, not dropped.
        guard case .unplugged(let s) = book.state(.control, among: [laptop, lg]) else { return XCTFail("expected unplugged") }
        XCTAssertEqual(s.id, "UUID-GONE")
    }

    func testNameAndResolutionFallbackWhenUUIDChanges() {
        var book = OutputAssignmentBook()
        book.assign(.stage, to: lg)
        // Same monitor through a different adapter: a new UUID, the same name and size.
        let lgNewPort = moved(lg, index: 2, id: "UUID-LG-OTHER-PORT")
        XCTAssertEqual(book.state(.stage, among: [laptop, lgNewPort]).display?.id, "UUID-LG-OTHER-PORT")
    }

    func testNoGuessBetweenTwoIdenticalMonitors() {
        var book = OutputAssignmentBook()
        book.assign(.stage, to: lg)
        let twinA = moved(lg, index: 2, id: "UUID-A"), twinB = moved(lg, index: 3, id: "UUID-B")
        guard case .unplugged = book.state(.stage, among: [laptop, twinA, twinB]) else {
            return XCTFail("two identical monitors must not be guessed between")
        }
    }

    // MARK: Unplug and return

    func testUnpluggedKeepsAssignmentAndRestores() {
        var book = OutputAssignmentBook()
        book.assign(.stage, to: tv)
        guard case .unplugged(let s) = book.state(.stage, among: [laptop, lg]) else { return XCTFail("expected unplugged") }
        XCTAssertEqual(s.name, "SONY TV")
        XCTAssertEqual(book.warnings(among: [laptop, lg], controlDisplayID: laptop.id), [.unplugged(.stage, tv.stored)])
        // Plugged back in (at another index): the same assignment, no warning.
        XCTAssertEqual(book.state(.stage, among: [laptop, moved(tv, index: 2)]).display?.id, "UUID-TV")
        XCTAssertTrue(book.warnings(among: [laptop, moved(tv, index: 2)], controlDisplayID: laptop.id).isEmpty)
    }

    // MARK: Warnings

    func testWarnsWhenOutputIsOnTheControlDisplay() {
        var book = OutputAssignmentBook()
        book.assign(.stage, to: lg)
        let w = book.warnings(among: [laptop, lg], controlDisplayID: lg.id)
        XCTAssertEqual(w, [.onControlDisplay(.stage, lg)])
    }

    func testWarnsWhenOutputIsOnTheBuiltInScreen() {
        var book = OutputAssignmentBook()
        book.assign(.confidence, to: laptop)
        // The console is on the LG, so this is the built-in warning, not the control one.
        XCTAssertEqual(book.warnings(among: [laptop, lg], controlDisplayID: lg.id), [.onBuiltIn(.confidence, laptop)])
        // Console on the laptop too: the control warning covers it (one warning, not two).
        XCTAssertEqual(book.warnings(among: [laptop, lg], controlDisplayID: laptop.id), [.onControlDisplay(.confidence, laptop)])
    }

    func testWarnsWhenTwoOutputsShareADisplay() {
        var book = OutputAssignmentBook()
        book.assign(.stage, to: lg)
        book.assign(.confidence, to: lg)
        XCTAssertEqual(book.warnings(among: [laptop, lg, tv], controlDisplayID: laptop.id), [.shared(lg, [.stage, .confidence])])
    }

    func testCleanRigHasNoWarnings() {
        var book = OutputAssignmentBook()
        book.assign(.stage, to: lg)
        book.assign(.confidence, to: tv)
        book.assign(.control, to: laptop)
        XCTAssertTrue(book.warnings(among: [laptop, lg, tv], controlDisplayID: laptop.id).isEmpty)
    }

    func testControlSharingWithConsoleIsNotAWarning() {
        // CONTROL is the console itself: it is never "on the control display" or "sharing".
        var book = OutputAssignmentBook()
        book.assign(.control, to: laptop)
        XCTAssertTrue(book.warnings(among: [laptop], controlDisplayID: laptop.id).isEmpty)
    }

    func testClearGoesBackToNotSet() {
        var book = OutputAssignmentBook()
        book.assign(.stage, to: lg)
        book.clear(.stage)
        XCTAssertEqual(book.state(.stage, among: [laptop, lg]), .notSet)
    }

    // MARK: Opening an output with no display: the suggestion

    func testSuggestionAvoidsControlBuiltInAndTakenDisplays() {
        var book = OutputAssignmentBook()
        XCTAssertEqual(book.suggestion(for: .stage, among: [laptop, lg, tv], controlDisplayID: laptop.id)?.id, "UUID-LG")
        book.assign(.stage, to: lg)
        XCTAssertEqual(book.suggestion(for: .confidence, among: [laptop, lg, tv], controlDisplayID: laptop.id)?.id, "UUID-TV")
        // One display, and the console is on it: nothing sensible, nothing guessed.
        XCTAssertNil(book.suggestion(for: .stage, among: [laptop], controlDisplayID: laptop.id))
    }

    func testWarningTextNamesTheDisplay() {
        XCTAssertTrue(AssignmentWarning.unplugged(.stage, tv.stored).text.contains("UNPLUGGED"))
        XCTAssertTrue(AssignmentWarning.shared(lg, [.stage, .confidence]).text.contains("LG 27UK850"))
    }
    // MARK: GO LIVE: where each output goes (2026-09-24)

    func testGoLiveUsesAssignedDisplays() {
        var book = OutputAssignmentBook()
        book.assign(.stage, to: tv)
        book.assign(.confidence, to: lg)
        let plan = book.goLivePlan(among: [laptop, lg, tv], controlDisplayID: laptop.id, alreadyLive: [])
        XCTAssertEqual(plan.targets[.stage]?.id, "UUID-TV")
        XCTAssertEqual(plan.targets[.confidence]?.id, "UUID-LG")
        XCTAssertTrue(plan.fallback.isEmpty)
        XCTAssertNil(plan.targets[.control], "GO LIVE never touches CONTROL")
    }

    func testGoLiveFallbackPutsTheTwoOutputsOnDifferentDisplays() {
        let plan = OutputAssignmentBook().goLivePlan(among: [laptop, lg, tv], controlDisplayID: laptop.id, alreadyLive: [])
        XCTAssertEqual(plan.targets[.stage]?.id, "UUID-LG")
        XCTAssertEqual(plan.targets[.confidence]?.id, "UUID-TV")
        XCTAssertEqual(plan.fallback, [.stage, .confidence])
    }

    func testGoLiveFallbackAvoidsTheOtherOutputsAssignment() {
        var book = OutputAssignmentBook()
        book.assign(.stage, to: lg)       // the first free display, taken by STAGE
        let plan = book.goLivePlan(among: [laptop, lg, tv], controlDisplayID: laptop.id, alreadyLive: [])
        XCTAssertEqual(plan.targets[.stage]?.id, "UUID-LG")
        XCTAssertEqual(plan.targets[.confidence]?.id, "UUID-TV")
        XCTAssertEqual(plan.fallback, [.confidence])
    }

    func testGoLiveFallbackNeverUsesTheConsolesDisplay() {
        // Console on the LG: the built-in laptop screen is the only other display, so the CONFIDENCE MONITOR
        // goes there, not on the LG; with one output display the KEY OVERLAY waits for an assignment.
        let plan = OutputAssignmentBook().goLivePlan(among: [laptop, lg], controlDisplayID: lg.id, alreadyLive: [])
        XCTAssertEqual(plan.targets[.stage]?.id, "UUID-BUILTIN")
        XCTAssertNil(plan.targets[.confidence])
        XCTAssertEqual(plan.skipped[.confidence], .keyNeedsAssignment)
    }

    /// 2026-09-24: one free external and nothing assigned -> the CONFIDENCE MONITOR only. The KEY OVERLAY
    /// feeds an ATEM and is mostly black on a screen of its own, so it goes live only when assigned.
    func testGoLiveOneExternalPutsUpOnlyTheConfidenceMonitor() {
        let book = OutputAssignmentBook()
        let plan = book.goLivePlan(among: [laptop, lg], controlDisplayID: laptop.id, alreadyLive: [])
        XCTAssertEqual(plan.targets[.stage]?.id, "UUID-LG")
        XCTAssertEqual(plan.fallback, [.stage])
        XCTAssertNil(plan.targets[.confidence])
        XCTAssertEqual(plan.skipped[.confidence], .keyNeedsAssignment)
        // ...and with the CONFIDENCE MONITOR up, GO LIVE is FULLY live, not "1/2".
        var assigned = book; assigned.assign(.stage, to: lg)
        let expected = assigned.goLiveExpected(among: [laptop, lg], controlDisplayID: laptop.id, live: [.stage])
        XCTAssertEqual(expected, [.stage])
        XCTAssertEqual(OutputAssignmentBook.goLiveButton(live: [.stage], expected: expected, hasOutputDisplay: true), .live)
    }

    func testGoLiveNeverOpensTwoOutputsOnOneDisplay() {
        // The operator's MD-1 (2026-09-24): both assigned to the one external. The CONFIDENCE MONITOR wins; the KEY
        // OVERLAY stays off and is not counted against "fully live".
        var book = OutputAssignmentBook()
        book.assign(.stage, to: lg)
        book.assign(.confidence, to: lg)
        let plan = book.goLivePlan(among: [laptop, lg], controlDisplayID: laptop.id, alreadyLive: [])
        XCTAssertEqual(plan.targets[.stage]?.id, "UUID-LG")
        XCTAssertNil(plan.targets[.confidence])
        XCTAssertEqual(plan.skipped[.confidence], .sharesConfidenceMonitor(lg))
        let expected = book.goLiveExpected(among: [laptop, lg], controlDisplayID: laptop.id, live: [.stage])
        XCTAssertEqual(OutputAssignmentBook.goLiveButton(live: [.stage], expected: expected, hasOutputDisplay: true), .live)
        // Same with a spare display: an explicit shared assignment is still not opened on top.
        let three = book.goLivePlan(among: [laptop, lg, tv], controlDisplayID: laptop.id, alreadyLive: [])
        XCTAssertNil(three.targets[.confidence])
        // And the CHECKS say so, in words.
        let w = book.warnings(among: [laptop, lg], controlDisplayID: laptop.id)
        XCTAssertEqual(w, [.shared(lg, [.stage, .confidence])])
        XCTAssertTrue(w[0].text.hasPrefix("KEY OVERLAY shares LG 27UK850 with the CONFIDENCE MONITOR"))
    }

    func testGoLiveTakesALiveKeyOverlayOffTheMonitorsDisplay() {
        var book = OutputAssignmentBook()
        book.assign(.stage, to: lg)
        book.assign(.confidence, to: lg)
        let plan = book.goLivePlan(among: [laptop, lg], controlDisplayID: laptop.id, alreadyLive: [.confidence])
        XCTAssertEqual(plan.targets[.stage]?.id, "UUID-LG")
        XCTAssertEqual(plan.takeOff, [.confidence])
    }

    func testGoLiveConfidenceMonitorWinsTheOnlyExternal() {
        // The KEY OVERLAY holds the only external and the CONFIDENCE MONITOR has no assignment: the monitor
        // takes that display (its fallback) and the key stays off.
        var book = OutputAssignmentBook()
        book.assign(.confidence, to: lg)
        let plan = book.goLivePlan(among: [laptop, lg], controlDisplayID: laptop.id, alreadyLive: [])
        XCTAssertEqual(plan.targets[.stage]?.id, "UUID-LG")
        XCTAssertNil(plan.targets[.confidence])
        XCTAssertEqual(plan.skipped[.confidence], .sharesConfidenceMonitor(lg))
    }

    // MARK: Assigning onto a display another output already uses

    func testConflictWhenAssigningOntoTheOtherOutputsDisplay() {
        var book = OutputAssignmentBook()
        book.assign(.stage, to: lg)
        XCTAssertEqual(book.conflict(assigning: .confidence, to: lg, among: [laptop, lg, tv]), .stage)
        XCTAssertNil(book.conflict(assigning: .confidence, to: tv, among: [laptop, lg, tv]))
        XCTAssertNil(book.conflict(assigning: .stage, to: lg, among: [laptop, lg, tv]), "its own display is no conflict")
        XCTAssertNil(book.conflict(assigning: .control, to: lg, among: [laptop, lg, tv]), "CONTROL is not a room output")
    }

    // MARK: KEY OVERLAY layout (the clipped cue title, 2026-09-24)

    func testKeyOverlayCueInfoNeverStartsAboveTheScreen() {
        for size in [CGSize(width: 1920, height: 1080), CGSize(width: 1280, height: 720), CGSize(width: 3840, height: 2160)] {
            for inset in [0.0, 0.1, 0.3, 1.0] {
                let p = StageDisplayView.cueInfoTopLeft(width: size.width, height: size.height, margin: 40, rule: 4, inset: inset)
                XCTAssertGreaterThanOrEqual(p.y, 0)
                XCTAssertLessThan(p.y, size.height / 2)
                XCTAssertGreaterThanOrEqual(p.x, 0)
            }
        }
        // At the default inset it sits just inside the top-left bracket, not centred on the screen edge.
        let home = StageDisplayView.cueInfoTopLeft(width: 1920, height: 1080, margin: 40, rule: 4, inset: 0)
        XCTAssertEqual(home.y, 52)
    }

    func testGoLiveWithNoExternalDisplayOpensNothing() {
        var book = OutputAssignmentBook()
        book.assign(.stage, to: laptop)   // even an explicit assignment to the console's own screen
        let plan = book.goLivePlan(among: [laptop], controlDisplayID: laptop.id, alreadyLive: [])
        XCTAssertTrue(plan.targets.isEmpty)
        XCTAssertEqual(plan.skipped, [.stage: .noOutputDisplay, .confidence: .noOutputDisplay])
    }

    func testGoLiveLeavesAnUnpluggedOutputForTheRestoreRule() {
        var book = OutputAssignmentBook()
        book.assign(.stage, to: tv)
        let plan = book.goLivePlan(among: [laptop, lg, tv], controlDisplayID: laptop.id, alreadyLive: [])
        XCTAssertEqual(plan.targets[.stage]?.id, "UUID-TV")
        let unplugged = book.goLivePlan(among: [laptop, lg], controlDisplayID: laptop.id, alreadyLive: [])
        XCTAssertNil(unplugged.targets[.stage])
        XCTAssertEqual(unplugged.skipped[.stage], .unplugged(tv.stored))
        // An unplugged output is still expected: GO LIVE is not "fully live" without it.
        XCTAssertEqual(book.goLiveExpected(among: [laptop, lg], controlDisplayID: laptop.id, live: []), [.stage])
    }

    func testGoLiveFromPartialOnlyBringsUpTheMissingOutput() {
        var book = OutputAssignmentBook()
        book.assign(.stage, to: lg)
        let plan = book.goLivePlan(among: [laptop, lg, tv], controlDisplayID: laptop.id, alreadyLive: [.stage])
        XCTAssertNil(plan.targets[.stage], "a live output is left where it is")
        XCTAssertEqual(plan.targets[.confidence]?.id, "UUID-TV", "and the missing one avoids the live one's display")
    }

    func testGoLiveButtonStates() {
        let both: Set<StageWindow> = [.stage, .confidence]
        XCTAssertEqual(OutputAssignmentBook.goLiveButton(live: [], expected: both, hasOutputDisplay: true), .off)
        XCTAssertEqual(OutputAssignmentBook.goLiveButton(live: [.stage], expected: both, hasOutputDisplay: true), .partial(1, 2))
        XCTAssertEqual(OutputAssignmentBook.goLiveButton(live: [.confidence], expected: both, hasOutputDisplay: true), .partial(1, 2))
        XCTAssertEqual(OutputAssignmentBook.goLiveButton(live: both, expected: both, hasOutputDisplay: true), .live)
        XCTAssertEqual(OutputAssignmentBook.goLiveButton(live: [], expected: [], hasOutputDisplay: false), .noOutputDisplay)
        // CONTROL being "live" is not an output being live.
        XCTAssertEqual(OutputAssignmentBook.goLiveButton(live: [.control], expected: both, hasOutputDisplay: true), .off)
    }

    // MARK: Window titles vs operator names (the 2026-09-24 rename)

    /// Every output window is found by its TITLE. The operator now reads CONFIDENCE MONITOR for the stage
    /// window and KEY OVERLAY for the confidence window, but the titles did not change: each title must still
    /// match exactly one window, and the console's titles none.
    func testEveryWindowTitleMatchesExactlyOneWindow() {
        let titles: [String: StageWindow] = [
            StageWindowTitle.stage: .stage,
            StageWindowTitle.keyOverlay: .confidence,
            StageWindowTitle.widget: .widget,
        ]
        for (title, window) in titles {
            XCTAssertEqual(StageWindow.matching(title: title), window, title)
            let hits = StageWindow.allCases.filter { $0 != .control && title.contains($0.titleMatch) }
            XCTAssertEqual(hits, [window], "\(title) must match one window only")
        }
        for console in ["ARC Stage Timer", "Shows", "JOB-0000 Test Show", ""] {
            XCTAssertNil(StageWindow.matching(title: console), "the console (\(console)) is not an output")
        }
        XCTAssertEqual(OutputType.stageDisplay.windowTitle, StageWindowTitle.stage)
        XCTAssertEqual(OutputType.confidence.windowTitle, StageWindowTitle.keyOverlay)
    }

    /// The trap the rename sets: a window TITLED with the new operator name would be caught by the wrong
    /// matcher under the old rule ("Confidence" matched the key layer). Titles and names must stay apart.
    func testOperatorNamesAreNotWindowTitles() {
        for w in StageWindow.roomOutputs {
            XCTAssertNotEqual(w.titleMatch.uppercased(), w.outputLabel, "\(w): its title must not be its new operator name")
        }
        XCTAssertFalse("Confidence Monitor".contains(StageWindowTitle.keyOverlay),
                       "the KEY OVERLAY matcher must not catch a title reading Confidence Monitor")
        XCTAssertEqual(StageWindow.stage.outputLabel, "CONFIDENCE MONITOR")
        XCTAssertEqual(StageWindow.confidence.outputLabel, "KEY OVERLAY")
    }

    func testAPINamesOldAndNew() {
        XCTAssertEqual(StageWindow(apiName: "stage"), .stage)
        XCTAssertEqual(StageWindow(apiName: "confidence-monitor"), .stage)
        XCTAssertEqual(StageWindow(apiName: "CONF-MON"), .stage)
        XCTAssertEqual(StageWindow(apiName: "confidence"), .confidence, "the old name keeps its old meaning")
        XCTAssertEqual(StageWindow(apiName: "key-overlay"), .confidence)
        XCTAssertEqual(StageWindow(apiName: "key"), .confidence)
        XCTAssertEqual(StageWindow(apiName: "control"), .control)
        XCTAssertNil(StageWindow(apiName: "monitor"))
    }
    // MARK: Windows restored at launch (the stray KEY OVERLAY, 2026-09-24)

    func testRestoredOutputWithNoAssignmentIsClosed() {
        let book = OutputAssignmentBook()
        XCTAssertEqual(book.restoredWindowAction(.confidence, among: [laptop, lg]), .close)
        XCTAssertEqual(book.restoredWindowAction(.stage, among: [laptop, lg]), .close)
    }

    func testRestoredOutputWithAConnectedDisplayGoesBackLiveThere() {
        var book = OutputAssignmentBook()
        book.assign(.stage, to: lg)
        book.assign(.confidence, to: tv)
        // Even after a replug that renumbered the displays.
        let now = [laptop, moved(tv, index: 2), moved(lg, index: 3)]
        XCTAssertEqual(book.restoredWindowAction(.stage, among: now), .place(moved(lg, index: 3)))
        XCTAssertEqual(book.restoredWindowAction(.confidence, among: now), .place(moved(tv, index: 2)))
    }

    func testRestoredOutputWhoseDisplayIsUnpluggedStaysParked() {
        var book = OutputAssignmentBook()
        book.assign(.confidence, to: tv)
        XCTAssertEqual(book.restoredWindowAction(.confidence, among: [laptop, lg]), .park(tv.stored))
        // A cleared assignment turns the same window into a stray again.
        book.clear(.confidence)
        XCTAssertEqual(book.restoredWindowAction(.confidence, among: [laptop, lg]), .close)
    }
    // MARK: KEY OVERLAY off in Settings (the default, 1.3.4)

    func testKeyOverlayOffLeavesOnlyTheConfidenceMonitorAndControl() {
        KeyOverlaySetting.isEnabled = false
        XCTAssertEqual(StageWindow.roomOutputs, [.stage])
        XCTAssertEqual(StageWindow.assignable, [.stage, .control])
        KeyOverlaySetting.isEnabled = true
        XCTAssertEqual(StageWindow.roomOutputs, [.stage, .confidence])
        XCTAssertEqual(StageWindow.assignable, [.stage, .confidence, .control])
    }

    func testKeyOverlayOffGoLiveIgnoresKeyEntirely() {
        var book = OutputAssignmentBook()
        book.assign(.stage, to: lg)
        book.assign(.confidence, to: tv)          // a dormant assignment on its own display
        KeyOverlaySetting.isEnabled = false
        let plan = book.goLivePlan(among: [laptop, lg, tv], controlDisplayID: laptop.id, alreadyLive: [])
        XCTAssertEqual(plan.targets.keys.sorted { $0.rawValue < $1.rawValue }, [.stage])
        XCTAssertNil(plan.skipped[.confidence], "not skipped: not considered at all")
        let expected = book.goLiveExpected(among: [laptop, lg, tv], controlDisplayID: laptop.id, live: [.stage])
        XCTAssertEqual(expected, [.stage])
        XCTAssertEqual(OutputAssignmentBook.goLiveButton(live: [.stage], expected: expected, hasOutputDisplay: true), .live)
        // Nothing assigned and two spare displays: still only the CONFIDENCE MONITOR.
        let fresh = OutputAssignmentBook().goLivePlan(among: [laptop, lg, tv], controlDisplayID: laptop.id, alreadyLive: [])
        XCTAssertEqual(Array(fresh.targets.keys), [.stage])
        XCTAssertTrue(fresh.fallback == [.stage])
    }

    func testKeyOverlayOffHasNoKeyWarningsOrConflicts() {
        var book = OutputAssignmentBook()
        book.assign(.stage, to: lg)
        book.assign(.confidence, to: lg)          // would be the shared-display warning when on
        KeyOverlaySetting.isEnabled = false
        XCTAssertTrue(book.warnings(among: [laptop, lg], controlDisplayID: laptop.id).isEmpty)
        XCTAssertNil(book.conflict(assigning: .stage, to: lg, among: [laptop, lg]))
        // The dormant assignment is kept, not deleted, and comes back when the setting is turned on.
        XCTAssertEqual(book.stored(.confidence)?.id, "UUID-LG")
        KeyOverlaySetting.isEnabled = true
        XCTAssertEqual(book.warnings(among: [laptop, lg], controlDisplayID: laptop.id), [.shared(lg, [.stage, .confidence])])
    }

    func testKeyOverlayOnIsTheOneThreeThreeBehaviour() {
        var book = OutputAssignmentBook()
        book.assign(.stage, to: lg)
        book.assign(.confidence, to: tv)
        KeyOverlaySetting.isEnabled = true
        let plan = book.goLivePlan(among: [laptop, lg, tv], controlDisplayID: laptop.id, alreadyLive: [])
        XCTAssertEqual(plan.targets[.stage]?.id, "UUID-LG")
        XCTAssertEqual(plan.targets[.confidence]?.id, "UUID-TV")
    }

    func testAPIRefusesKeyOverlayRoutesWhileOff() {
        KeyOverlaySetting.isEnabled = false
        for name in ["confidence", "key-overlay", "key", "confidence-output"] {
            XCTAssertTrue(KeyOverlaySetting.refuses(StageWindow(apiName: name)), name)
        }
        for name in ["stage", "confidence-monitor", "control"] {
            XCTAssertFalse(KeyOverlaySetting.refuses(StageWindow(apiName: name)), name)
        }
        XCTAssertTrue(KeyOverlaySetting.disabledError.contains("Key Overlay is disabled in Settings"))
        KeyOverlaySetting.isEnabled = true
        XCTAssertFalse(KeyOverlaySetting.refuses(StageWindow(apiName: "key-overlay")))
    }

    func testKeyOverlayIsOffByDefault() throws {
        let suite = "KeyOverlayDefault-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(defaults.bool(forKey: KeyOverlaySetting.defaultsKey), "a fresh or existing install starts with it off")
    }
}
#endif

//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import XCTest
import ARCShowFormat   // types that moved to the package (a045aea)
@testable import ArcPresenter

/// The simple cue engine (stage timer merge, phase 2 as rescoped): select,
/// start, stop, reset, previous, next. No schedule tracking.
@MainActor
final class CueTimerTests: XCTestCase {
    private var folder = FileManager.default.temporaryDirectory
    private var store = RundownStore(followingShowFolder: false)
    private var timer = TimerEngine()
    private var cue: CueTimer!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("cuetimer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        store = RundownStore(followingShowFolder: false)
        store.open(folder: folder)
        store.create(name: "Show")
        store.add(RundownCue(title: "Welcome", durationSeconds: 300))
        store.add(RundownCue(title: "Keynote", durationSeconds: 1800))
        store.add(RundownCue(title: "Break", durationSeconds: 900))
        timer = TimerEngine()
        cue = CueTimer(timer: timer, store: store)
    }
    override func tearDownWithError() throws { timer.stop(); try? FileManager.default.removeItem(at: folder) }

    func testNothingSelectedIsIdleAndSaysSo() {
        XCTAssertNil(cue.now); XCTAssertEqual(cue.shade, .idle); XCTAssertEqual(cue.displayString, "--:--")
        cue.stop(); cue.reset()
        XCTAssertEqual(cue.lastAction, "reset: nothing selected")
    }

    func testSelectLoadsTheCueStoppedAtFullLength() {
        cue.select(index: 1)
        XCTAssertEqual(cue.now?.title, "Keynote")
        XCTAssertEqual(cue.next?.title, "Break")
        XCTAssertFalse(cue.isRunning)
        XCTAssertEqual(timer.mode, .countDown)
        XCTAssertEqual(timer.countdownDuration, 1800)
        XCTAssertEqual(cue.displayString, "30:00")
        XCTAssertEqual(cue.shade, .normal)
    }

    func testStartWithNothingSelectedTakesTheFirstCue() {
        cue.start()
        XCTAssertEqual(cue.now?.title, "Welcome")
        XCTAssertTrue(cue.isRunning)
        XCTAssertTrue(cue.lastAction.hasPrefix("START Welcome"))
    }

    func testStartStopResetAreIdempotentAndHonest() async throws {
        cue.select(index: 0)
        cue.start(); cue.start()
        XCTAssertTrue(cue.isRunning)
        try await Task.sleep(for: .milliseconds(1200))
        cue.stop(); cue.stop()
        XCTAssertFalse(cue.isRunning)
        XCTAssertLessThan(timer.remaining, 300, "it counted")
        XCTAssertTrue(cue.lastAction.hasPrefix("STOP Welcome at"))
        cue.reset()
        XCTAssertEqual(timer.remaining, 300, "back to the full length")
        XCTAssertFalse(cue.isRunning)
    }

    func testNextAndPreviousCarryTheRunningState() {
        cue.select(index: 0)
        cue.goNext()
        XCTAssertEqual(cue.now?.title, "Keynote"); XCTAssertFalse(cue.isRunning, "was stopped, stays stopped")
        cue.start()
        cue.goNext()
        XCTAssertEqual(cue.now?.title, "Break"); XCTAssertTrue(cue.isRunning, "was running, the next cue runs")
        XCTAssertEqual(timer.countdownDuration, 900)
        cue.goNext()
        XCTAssertEqual(cue.now?.title, "Break"); XCTAssertEqual(cue.lastAction, "at the last cue")
        cue.goPrevious(); cue.goPrevious()
        XCTAssertEqual(cue.now?.title, "Welcome"); XCTAssertTrue(cue.isRunning)
        cue.goPrevious()
        XCTAssertEqual(cue.lastAction, "at the first cue")
    }

    func testSelectingAnotherCueWhileRunningStops() {
        cue.select(index: 0); cue.start()
        cue.select(index: 2)
        XCTAssertFalse(cue.isRunning)
        XCTAssertEqual(cue.now?.title, "Break")
        XCTAssertEqual(cue.lastAction, "selected Break (stopped)")
    }

    func testShadeFollowsTheCuesOwnThresholdsAndHoldsAtZero() async throws {
        store.add(RundownCue(title: "Tiny", durationSeconds: 2))
        cue.select(index: 3)
        XCTAssertEqual(cue.shade, .normal, "fresh, the cue is normal whatever its length")
        cue.start()
        try await Task.sleep(for: .milliseconds(2600))
        XCTAssertTrue(cue.isOver)
        XCTAssertEqual(cue.shade, .over)
        XCTAssertEqual(cue.displayString, "00:00", "holds at zero; no running overtime figure")
        cue.stop()
    }

    func testARemovedSelectedCueLeavesNothingSelected() {
        cue.select(index: 1)
        store.remove(id: cue.now!.id)
        XCTAssertNil(cue.now)
        XCTAssertEqual(cue.shade, .idle)
        cue.goNext()
        XCTAssertEqual(cue.now?.title, "Welcome", "NEXT from nothing takes the first cue")
    }
}

/// The rows changing under the selection (review, 2026-09-19).
final class CueTimerReconcileTests: XCTestCase {
    @MainActor
    private func make() -> (CueTimer, RundownStore, TimerEngine) {
        let store = RundownStore(followingShowFolder: false)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cue-reconcile-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        store.open(folder: folder)
        store.create(name: "Test")
        store.add(RundownCue(title: "One", durationSeconds: 600))
        store.add(RundownCue(title: "Two", durationSeconds: 300))
        let timer = TimerEngine()
        return (CueTimer(timer: timer, store: store), store, timer)
    }

    @MainActor
    func testRemovingTheRunningCueStopsAndClears() {
        let (cue, store, timer) = make()
        cue.select(index: 0); cue.start()
        XCTAssertTrue(cue.isRunning)
        store.remove(id: store.rundown!.cues[0].id)
        XCTAssertNil(cue.selectedID, "nothing selected")
        XCTAssertFalse(timer.isRunning, "and nothing counting behind it")
    }

    @MainActor
    func testEditingTheSelectedCuesLengthReachesTheCountdown() {
        let (cue, store, timer) = make()
        cue.select(index: 0)
        XCTAssertEqual(timer.countdownDuration, 600)
        var c = store.rundown!.cues[0]; c.durationSeconds = 1200
        store.update(c)
        XCTAssertEqual(timer.countdownDuration, 1200, "the loaded countdown follows the edit")
        XCTAssertEqual(cue.selectedID, c.id, "still selected")
    }
}

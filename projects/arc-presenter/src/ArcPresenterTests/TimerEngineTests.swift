//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import XCTest
@testable import ArcPresenter

@MainActor
final class TimerEngineTests: XCTestCase {
    var timer: TimerEngine!

    override func setUp() {
        super.setUp()
        timer = TimerEngine()
    }

    // MARK: - Initial State

    func testInitialState() {
        XCTAssertEqual(timer.elapsed, 0)
        XCTAssertFalse(timer.isRunning)
        XCTAssertEqual(timer.mode, .countUp)
        XCTAssertEqual(timer.countdownDuration, 30 * 60)
        XCTAssertEqual(timer.displayString, "00:00")
        XCTAssertFalse(timer.isOvertime)
    }

    // MARK: - Start / Stop / Reset

    func testStartSetsRunning() {
        timer.start()
        XCTAssertTrue(timer.isRunning)
    }

    func testStopClearsRunning() {
        timer.start()
        timer.stop()
        XCTAssertFalse(timer.isRunning)
    }

    func testResetClearsAll() {
        timer.start()
        timer.stop()
        timer.reset()
        XCTAssertFalse(timer.isRunning)
        XCTAssertEqual(timer.elapsed, 0)
    }

    func testToggle() {
        XCTAssertFalse(timer.isRunning)
        timer.toggle()
        XCTAssertTrue(timer.isRunning)
        timer.toggle()
        XCTAssertFalse(timer.isRunning)
    }

    func testDoubleStartIgnored() {
        timer.start()
        timer.start()
        XCTAssertTrue(timer.isRunning)
    }

    func testDoubleStopIgnored() {
        timer.stop()
        XCTAssertFalse(timer.isRunning)
    }

    // MARK: - Display String

    func testDisplayStringZero() {
        XCTAssertEqual(timer.displayString, "00:00")
    }

    func testDisplayStringCountUp() {
        timer.mode = .countUp
        // Simulate elapsed time via internal state
        // Since elapsed is private(set), we test via the formatted output at 0
        XCTAssertEqual(timer.displayString, "00:00")
    }

    func testDisplayStringCountDown() {
        timer.mode = .countDown
        timer.countdownDuration = 30 * 60
        // At 0 elapsed, remaining = 30:00
        XCTAssertEqual(timer.displayString, "30:00")
    }

    func testDisplayStringCountDownShort() {
        timer.mode = .countDown
        timer.countdownDuration = 5 * 60
        XCTAssertEqual(timer.displayString, "05:00")
    }

    // MARK: - Overtime

    func testNotOvertimeInCountUp() {
        timer.mode = .countUp
        XCTAssertFalse(timer.isOvertime)
    }

    func testNotOvertimeWhenNotExceeded() {
        timer.mode = .countDown
        timer.countdownDuration = 30 * 60
        XCTAssertFalse(timer.isOvertime)
    }

    // MARK: - Remaining

    func testRemainingAtZeroElapsed() {
        timer.mode = .countDown
        timer.countdownDuration = 20 * 60
        XCTAssertEqual(timer.remaining, 20 * 60)
    }

    // MARK: - Mode Switching

    func testModeSwitch() {
        timer.mode = .countUp
        XCTAssertEqual(timer.mode, .countUp)
        timer.mode = .countDown
        XCTAssertEqual(timer.mode, .countDown)
    }

    func testCountdownDurationChange() {
        timer.countdownDuration = 45 * 60
        XCTAssertEqual(timer.countdownDuration, 45 * 60)
    }
}

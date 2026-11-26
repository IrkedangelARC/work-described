//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import XCTest
import SwiftData
@testable import ARC_Stage_Timer

final class TimerEngineOffsetTests: XCTestCase {

    private var engine: TimerEngine!
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUp() {
        super.setUp()
        engine = TimerEngine()
        container = try! ModelContainer(for: Show.self, Cue.self,
                                        configurations: .init(isStoredInMemoryOnly: true))
        context = ModelContext(container)
    }

    override func tearDown() {
        engine.stop()
        engine = nil
        container = nil
        context = nil
        super.tearDown()
    }

    // MARK: - Helpers

    /// Build a show with cues starting at `baseHour:baseMinute`, each `durationSec` long
    private func makeScheduledShow(
        baseHour: Int = 16,
        baseMinute: Int = 0,
        cueCount: Int = 5,
        durationSec: Int = 180
    ) -> Show {
        let calendar = Calendar.current
        let baseDate = calendar.startOfDay(for: Date())

        let show = Show(name: "Test Show", date: baseDate)
        context.insert(show)

        var cues: [Cue] = []
        for i in 0..<cueCount {
            let minuteOffset = baseMinute + (i * durationSec / 60)
            let startTime = calendar.date(bySettingHour: baseHour,
                                          minute: minuteOffset,
                                          second: 0, of: baseDate)!
            let cue = Cue(title: "Cue \(i + 1)", sortOrder: i,
                          startTime: startTime, durationSeconds: durationSec)
            cue.show = show
            context.insert(cue)
            cues.append(cue)
        }
        show.cues = cues
        return show
    }

    /// Build a show with NO startTime on cues (unscheduled)
    private func makeUnscheduledShow(cueCount: Int = 3) -> Show {
        let show = Show(name: "Unscheduled Show", date: Date())
        context.insert(show)

        var cues: [Cue] = []
        for i in 0..<cueCount {
            let cue = Cue(title: "Cue \(i + 1)", sortOrder: i, durationSeconds: 300)
            cue.show = show
            context.insert(cue)
            cues.append(cue)
        }
        show.cues = cues
        return show
    }

    // MARK: - isScheduledShow Detection

    func testScheduledShowDetected() {
        let show = makeScheduledShow()
        engine.loadShow(show)

        XCTAssertTrue(engine.isScheduledShow, "Show with startTime cues should be detected as scheduled")
        XCTAssertEqual(engine.cues.count, 5)
    }

    func testUnscheduledShowDetected() {
        let show = makeUnscheduledShow()
        engine.loadShow(show)

        XCTAssertFalse(engine.isScheduledShow, "Show without startTime cues should NOT be scheduled")
    }

    // MARK: - Offset Before Show Starts

    func testOffsetIsZeroBeforeStart() {
        let show = makeScheduledShow()
        engine.loadShow(show)

        XCTAssertEqual(engine.showOffsetSeconds, 0, "Offset should be 0 before show starts")
        XCTAssertEqual(engine.showOffsetDisplay, "ON TIME")
        XCTAssertEqual(engine.offsetStatus, .onTime)
    }

    // MARK: - showStartedAt Tracking

    func testShowStartedAtRecordedOnFirstCue() {
        let show = makeScheduledShow()
        engine.loadShow(show)

        XCTAssertNil(engine.showStartedAt)
        engine.start()
        XCTAssertNotNil(engine.showStartedAt, "showStartedAt should be set when first cue starts")
    }

    func testShowStartedAtNotOverwrittenOnSecondCue() {
        let show = makeScheduledShow()
        engine.loadShow(show)

        engine.start()
        let firstStartTime = engine.showStartedAt
        engine.next()
        engine.start()

        XCTAssertEqual(engine.showStartedAt, firstStartTime,
                       "showStartedAt should NOT change when second cue starts")
    }

    // MARK: - Actual Start Time Recording

    func testActualStartTimeRecordedPerCue() {
        let show = makeScheduledShow()
        engine.loadShow(show)

        let cue0 = engine.cues[0]
        let cue1 = engine.cues[1]

        engine.start()
        XCTAssertNotNil(engine.cueActualStartTimes[cue0.id])
        XCTAssertNil(engine.cueActualStartTimes[cue1.id])

        engine.next()
        engine.start()
        XCTAssertNotNil(engine.cueActualStartTimes[cue1.id])
    }

    // MARK: - OffsetStatus Enum

    func testOffsetStatusOnTime() {
        XCTAssertEqual(OffsetStatus.from(offsetSeconds: 0), .onTime)
        XCTAssertEqual(OffsetStatus.from(offsetSeconds: 15), .onTime)
        XCTAssertEqual(OffsetStatus.from(offsetSeconds: -20), .onTime)
        XCTAssertEqual(OffsetStatus.from(offsetSeconds: 30), .onTime)
    }

    func testOffsetStatusAhead() {
        XCTAssertEqual(OffsetStatus.from(offsetSeconds: -31), .ahead)
        XCTAssertEqual(OffsetStatus.from(offsetSeconds: -120), .ahead)
        XCTAssertEqual(OffsetStatus.from(offsetSeconds: -600), .ahead)
    }

    func testOffsetStatusBehind() {
        XCTAssertEqual(OffsetStatus.from(offsetSeconds: 31), .behind)
        XCTAssertEqual(OffsetStatus.from(offsetSeconds: 120), .behind)
        XCTAssertEqual(OffsetStatus.from(offsetSeconds: 300), .behind)
    }

    func testOffsetStatusWayBehind() {
        XCTAssertEqual(OffsetStatus.from(offsetSeconds: 301), .wayBehind)
        XCTAssertEqual(OffsetStatus.from(offsetSeconds: 600), .wayBehind)
    }

    // MARK: - showOffsetDisplay Formatting

    func testOffsetDisplayOnTime() {
        // Directly test the format logic via OffsetStatus thresholds
        let show = makeScheduledShow()
        engine.loadShow(show)
        // Before start => 0 offset
        XCTAssertEqual(engine.showOffsetDisplay, "ON TIME")
    }

    // MARK: - Projected Start Times

    func testProjectedStartTimesWithZeroOffset() {
        let show = makeScheduledShow()
        engine.loadShow(show)

        // Before show starts, offset is 0, so projected == scheduled
        for i in 0..<engine.cues.count {
            let projected = engine.projectedStartTime(for: i)
            XCTAssertNotNil(projected)
            XCTAssertEqual(projected, engine.cues[i].startTime,
                           "Projected should equal scheduled when offset is 0")
        }
    }

    func testProjectedStartTimeNilForUnscheduled() {
        let show = makeUnscheduledShow()
        engine.loadShow(show)

        XCTAssertNil(engine.projectedStartTime(for: 0),
                     "Projected start should be nil for unscheduled show")
    }

    func testProjectedStartTimeOutOfBounds() {
        let show = makeScheduledShow(cueCount: 3)
        engine.loadShow(show)

        XCTAssertNil(engine.projectedStartTime(for: -1))
        XCTAssertNil(engine.projectedStartTime(for: 10))
    }

    // MARK: - Stop Resets Timekeeping

    func testStopResetsAllTimekeeping() {
        let show = makeScheduledShow()
        engine.loadShow(show)

        engine.start()
        XCTAssertNotNil(engine.showStartedAt)
        XCTAssertFalse(engine.cueActualStartTimes.isEmpty)

        engine.stop()
        XCTAssertNil(engine.showStartedAt, "stop() should clear showStartedAt")
        XCTAssertTrue(engine.cueActualStartTimes.isEmpty, "stop() should clear actual start times")
    }

    // MARK: - Inter-Cue Pause Tracking

    func testNextStartsPauseTracking() {
        let show = makeScheduledShow()
        engine.loadShow(show)

        engine.start()
        engine.next() // should set interCuePauseStart internally
        // State should be idle after next()
        XCTAssertEqual(engine.state, .idle)
    }

    // MARK: - ROS Import Integration

    func testROSImportCreatesScheduledCues() throws {
        let json = """
        {
          "event_name": "Quick Test",
          "event_date": "2026-02-27",
          "sessions": [
            {"time_range": "4:00 PM - 4:03 PM", "session_title": "Cue 1", "duration_minutes": 3},
            {"time_range": "4:03 PM - 4:06 PM", "session_title": "Cue 2", "duration_minutes": 3},
            {"time_range": "4:06 PM - 4:09 PM", "session_title": "Cue 3", "duration_minutes": 3}
          ]
        }
        """
        let data = json.data(using: .utf8)!
        let show = try ROSImporter.importShow(from: data)

        // Insert into context for SwiftData
        context.insert(show)
        for cue in show.cues { context.insert(cue) }

        engine.loadShow(show)
        XCTAssertTrue(engine.isScheduledShow)
        XCTAssertEqual(engine.cues.count, 3)

        // Verify start times were parsed
        for cue in engine.cues {
            XCTAssertNotNil(cue.startTime, "Cue '\(cue.title)' should have a startTime")
        }

        // Verify durations are 3 minutes = 180 seconds
        for cue in engine.cues {
            XCTAssertEqual(cue.durationSeconds, 180, "Each cue should be 180s")
        }

        // Verify start times are 3 minutes apart
        let cue0Start = engine.cues[0].startTime!
        let cue1Start = engine.cues[1].startTime!
        let cue2Start = engine.cues[2].startTime!
        XCTAssertEqual(cue1Start.timeIntervalSince(cue0Start), 180, accuracy: 1)
        XCTAssertEqual(cue2Start.timeIntervalSince(cue1Start), 180, accuracy: 1)
    }

    // MARK: - Full Lifecycle

    func testFullLifecycleDoesNotCrash() {
        let show = makeScheduledShow()
        engine.loadShow(show)

        // Start cue 0
        engine.start()
        XCTAssertEqual(engine.state, .running)

        // Pause
        engine.pause()
        XCTAssertEqual(engine.state, .paused)

        // Resume
        engine.resume()
        XCTAssertEqual(engine.state, .running)

        // Next cue
        engine.next()
        XCTAssertEqual(engine.state, .idle)
        XCTAssertEqual(engine.currentCueIndex, 1)

        // Start cue 1
        engine.start()
        XCTAssertEqual(engine.state, .running)

        // Previous
        engine.previous()
        XCTAssertEqual(engine.state, .idle)
        XCTAssertEqual(engine.currentCueIndex, 0)

        // GoTo cue 3
        engine.goToCue(at: 3)
        XCTAssertEqual(engine.currentCueIndex, 3)

        // Start and advance to end
        engine.start()
        engine.next()  // cue 4 (last)
        engine.start()
        engine.next()  // finished (no more cues)
        XCTAssertEqual(engine.state, .finished)

        // Stop resets everything
        engine.stop()
        XCTAssertEqual(engine.state, .idle)
        XCTAssertNil(engine.showStartedAt)
    }

    // MARK: - Offset Computed During Running Cue

    func testOffsetDuringRunningCue() {
        // Create a show where cue starts "now" so offset should be near 0
        let calendar = Calendar.current
        let now = Date()
        let baseDate = calendar.startOfDay(for: now)

        let show = Show(name: "Now Show", date: baseDate)
        context.insert(show)

        let startTime = now.addingTimeInterval(0) // scheduled for right now
        let cue = Cue(title: "Right Now Cue", sortOrder: 0,
                       startTime: startTime, durationSeconds: 180)
        cue.show = show
        context.insert(cue)
        show.cues = [cue]

        engine.loadShow(show)
        engine.start()

        // Just started, offset should be very small (within a second of scheduled)
        let offset = engine.showOffsetSeconds
        XCTAssertTrue(abs(offset) <= 2,
                      "Offset should be near 0 when starting on time, got \(offset)")
    }

    func testOffsetWhenStartingLate() {
        // Create a show where the cue was scheduled 2 minutes ago
        let calendar = Calendar.current
        let now = Date()
        let baseDate = calendar.startOfDay(for: now)

        let show = Show(name: "Late Show", date: baseDate)
        context.insert(show)

        let scheduledStart = now.addingTimeInterval(-120) // 2 min ago
        let cue = Cue(title: "Late Cue", sortOrder: 0,
                       startTime: scheduledStart, durationSeconds: 180)
        cue.show = show
        context.insert(cue)
        show.cues = [cue]

        engine.loadShow(show)
        engine.start()

        // We started 2 minutes late, offset should be ~120s
        let offset = engine.showOffsetSeconds
        XCTAssertTrue(offset >= 118 && offset <= 122,
                      "Offset should be ~120s when starting 2 min late, got \(offset)")
        XCTAssertEqual(engine.offsetStatus, .behind)
    }

    func testOffsetWhenStartingEarly() {
        // Create a show where the cue is scheduled 2 minutes from now
        let calendar = Calendar.current
        let now = Date()
        let baseDate = calendar.startOfDay(for: now)

        let show = Show(name: "Early Show", date: baseDate)
        context.insert(show)

        let scheduledStart = now.addingTimeInterval(120) // 2 min from now
        let cue = Cue(title: "Early Cue", sortOrder: 0,
                       startTime: scheduledStart, durationSeconds: 180)
        cue.show = show
        context.insert(cue)
        show.cues = [cue]

        engine.loadShow(show)
        engine.start()

        // We started 2 minutes early, offset should be ~-120s
        let offset = engine.showOffsetSeconds
        XCTAssertTrue(offset <= -118 && offset >= -122,
                      "Offset should be ~-120s when starting 2 min early, got \(offset)")
        XCTAssertEqual(engine.offsetStatus, .ahead)
    }
}

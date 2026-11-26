//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import XCTest
import SwiftData
@testable import ARC_Stage_Timer

/// The full CUE EDITOR's contract: a draft is stored whole on SAVE, cleaned up on the way in,
/// re-chains later start times, and comes back in one UNDO.
final class CueFullEditorTests: XCTestCase {

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
        engine = nil; container = nil; context = nil
        super.tearDown()
    }

    private func loadScheduledShow(count: Int = 4, duration: Int = 600) -> Date {
        let base = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date())!
        let show = Show(name: "Editor Test", date: base)
        context.insert(show)
        var cues: [Cue] = []
        for i in 0..<count {
            let cue = Cue(title: "Cue \(i + 1)", sortOrder: i,
                          startTime: base.addingTimeInterval(Double(i * duration)), durationSeconds: duration)
            cue.show = show
            context.insert(cue)
            cues.append(cue)
        }
        show.cues = cues
        engine.loadShow(show)
        return base
    }

    func testNormalizedTrimsAndClamps() {
        let cue = Cue(title: "x", durationSeconds: 300)
        var d = CueDraft(cue)
        d.title = "  Keynote  "
        d.subtitle = "   "
        d.format = .keynote
        d.customFormatLabel = "Ignored unless custom"
        d.warningThreshold = 900          // past the duration
        d.dangerThreshold = 900           // past the warning
        let n = d.normalized
        XCTAssertEqual(n.title, "Keynote")
        XCTAssertEqual(n.subtitle, "")
        XCTAssertEqual(n.customFormatLabel, "")
        XCTAssertEqual(n.warningThreshold, 300)
        XCTAssertEqual(n.dangerThreshold, 299)
    }

    func testApplyStoresEveryField() {
        let cue = Cue(title: "Old", durationSeconds: 300)
        var d = CueDraft(cue)
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        d.title = "Panel: Climate"; d.subtitle = "Adaptation"; d.speakers = "A, B"
        d.format = .custom; d.customFormatLabel = "Roundtable"
        d.startTime = start; d.durationSeconds = 2700
        d.warningThreshold = 300; d.dangerThreshold = 60; d.overtimeAllowed = false
        d.notes = "4 handhelds"
        d.apply(to: cue)
        XCTAssertEqual(cue.title, "Panel: Climate")
        XCTAssertEqual(cue.subtitle, "Adaptation")
        XCTAssertEqual(cue.speakers, "A, B")
        XCTAssertEqual(cue.formatLabel, "Roundtable")
        XCTAssertEqual(cue.startTime, start)
        XCTAssertEqual(cue.durationSeconds, 2700)
        XCTAssertEqual(cue.warningThreshold, 300)
        XCTAssertEqual(cue.dangerThreshold, 60)
        XCTAssertFalse(cue.overtimeAllowed)
        XCTAssertEqual(cue.notes, "4 handhelds")
        XCTAssertEqual(CueDraft(cue), d.normalized)
    }

    func testEmptyTitleIsInvalid() {
        var d = CueDraft(Cue(title: "x"))
        d.title = "   "
        XCTAssertFalse(d.isValid)
    }

    func testUpdateRechainsLaterStartsAndUndoes() {
        let base = loadScheduledShow()
        let target = engine.cues[1]
        var d = CueDraft(target)
        d.durationSeconds = 1200     // 10 min -> 20 min
        d.title = "Longer"
        XCTAssertTrue(engine.updateCue(id: target.id, with: d))

        XCTAssertEqual(target.title, "Longer")
        XCTAssertEqual(engine.cues[2].startTime, base.addingTimeInterval(600 + 1200))
        XCTAssertEqual(engine.cues[3].startTime, base.addingTimeInterval(600 + 1200 + 600))
        XCTAssertEqual(engine.undoActionName, "Edit Cue")

        engine.undo()
        XCTAssertEqual(target.title, "Cue 2")
        XCTAssertEqual(target.durationSeconds, 600)
        XCTAssertEqual(engine.cues[2].startTime, base.addingTimeInterval(1200))
        XCTAssertEqual(engine.cues[3].startTime, base.addingTimeInterval(1800))
    }

    func testNewStartTimeMovesLaterCues() {
        let base = loadScheduledShow()
        let target = engine.cues[2]
        var d = CueDraft(target)
        d.startTime = base.addingTimeInterval(3600)   // after a lunch gap
        engine.updateCue(id: target.id, with: d)
        XCTAssertEqual(target.startTime, base.addingTimeInterval(3600))
        XCTAssertEqual(engine.cues[3].startTime, base.addingTimeInterval(3600 + 600))
    }

    func testUnchangedDraftRegistersNoUndo() {
        _ = loadScheduledShow()
        let target = engine.cues[0]
        XCTAssertTrue(engine.updateCue(id: target.id, with: CueDraft(target)))
        XCTAssertFalse(engine.canUndo)
    }

    func testRemovedCueIsRefused() {
        _ = loadScheduledShow()
        let orphan = Cue(title: "Not in show")
        XCTAssertFalse(engine.updateCue(id: orphan.id, with: CueDraft(orphan)))
    }
}

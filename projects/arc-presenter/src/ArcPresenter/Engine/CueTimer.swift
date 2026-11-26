//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation
import ARCShowFormat
import Observation

/// The stage timer's engine, made simple on purpose (2026-09-18:
/// "remove the time tracking to agenda that shows overtime. give robust start
/// stop and cue select controls").
///
/// One cue is selected. START counts it down, STOP holds it, RESET puts it
/// back to its full length, PREV and NEXT move to the neighbouring cue and
/// keep running if the timer was running, and clicking a row selects it.
/// That is the whole engine. It does not project start times, shift the
/// schedule to now, propose compression, or keep a tally of how far behind
/// the agenda the room is; a cue that runs past zero holds at 0:00 in the
/// danger colour and says OVER, with no running figure.
///
/// It drives Presenter's existing `TimerEngine`, so the footer TIMER module
/// and the confidence monitor's timer row show the cue's countdown with no
/// change of their own.
@MainActor @Observable
final class CueTimer {
    /// What colour the stage should be, from the cue's own thresholds.
    enum Shade: String { case idle, normal, warning, danger, over }

    private let timer: TimerEngine
    private let store: RundownStore
    private(set) var selectedID: UUID?
    private(set) var lastAction = ""

    init(timer: TimerEngine, store: RundownStore) {
        self.timer = timer
        self.store = store
        store.onChange = { [weak self] in self?.reconcile() }
    }

    /// The rows changed under the selection (review, 2026-09-19). The selected cue removed: the
    /// countdown was still running behind NOTHING SELECTED, so stop and clear. The selected cue's
    /// length edited: the running countdown kept the old length, so re-apply it, elapsed kept.
    func reconcile() {
        guard let id = selectedID else { return }
        guard let c = cues.first(where: { $0.id == id }) else {
            timer.stop(); timer.reset(); selectedID = nil
            note("selected cue removed: stopped")
            return
        }
        let length = TimeInterval(c.durationSeconds)
        if timer.countdownDuration != length {
            timer.countdownDuration = length
            note("\(c.title) now \(Rundown.clock(c.durationSeconds))\(timer.isRunning ? ", running" : "")")
        }
    }

    // MARK: - What is selected

    var cues: [RundownCue] { store.rundown?.cues ?? [] }
    var selectedIndex: Int? { cues.firstIndex { $0.id == selectedID } }
    var now: RundownCue? { selectedIndex.map { cues[$0] } }
    var next: RundownCue? { selectedIndex.flatMap { $0 + 1 < cues.count ? cues[$0 + 1] : nil } }
    var hasPrevious: Bool { (selectedIndex ?? 0) > 0 }
    var hasNext: Bool { next != nil }

    var isRunning: Bool { selectedID != nil && timer.isRunning }
    var remaining: TimeInterval { selectedID == nil ? 0 : timer.remaining }
    var displayString: String { selectedID == nil ? "--:--" : timer.displayString }
    var isOver: Bool { selectedID != nil && timer.isOvertime }

    var shade: Shade {
        guard let c = now else { return .idle }
        if timer.isOvertime { return .over }
        let r = Int(remaining.rounded(.up))
        if r <= c.dangerSeconds { return .danger }
        if r <= c.warningSeconds { return .warning }
        return .normal
    }

    // MARK: - Controls. None of them can fail; each says what it did.

    /// Select a cue: the timer stops and holds that cue's full length.
    func select(_ id: UUID) {
        guard let c = cues.first(where: { $0.id == id }) else { note("select: no such cue"); return }
        let wasRunning = isRunning
        load(c)
        note("selected \(c.title)\(wasRunning ? " (stopped)" : "")")
    }

    func select(index: Int) {
        guard cues.indices.contains(index) else { note("select: no cue \(index + 1)"); return }
        select(cues[index].id)
    }

    /// Count the selected cue down. With nothing selected, the first cue.
    func start() {
        if selectedID == nil {
            guard let first = cues.first else { note("start: the rundown is empty"); return }
            load(first)
        }
        guard !timer.isRunning else { return }
        timer.start()
        note("START \(now?.title ?? "")")
    }

    func stop() {
        guard timer.isRunning else { return }
        timer.stop()
        note("STOP \(now?.title ?? "") at \(timer.displayString)")
    }

    func toggle() { isRunning ? stop() : start() }

    /// The selected cue back to its full length, stopped.
    func reset() {
        guard let c = now else { note("reset: nothing selected"); return }
        load(c)
        note("RESET \(c.title)")
    }

    /// The next cue, running if this one was running.
    func goNext() { step(by: 1) }
    func goPrevious() { step(by: -1) }

    /// Jump to a cue by position, running if the timer was running.
    func goTo(index: Int) {
        guard cues.indices.contains(index) else { note("go to: no cue \(index + 1)"); return }
        let wasRunning = isRunning
        load(cues[index])
        if wasRunning { timer.start() }
        note("GO \(cues[index].title)\(wasRunning ? ", running" : "")")
    }

    private func step(by delta: Int) {
        guard let i = selectedIndex else {
            if delta > 0, let first = cues.first { load(first); note("selected \(first.title)") } else { note("nothing selected") }
            return
        }
        let j = i + delta
        guard cues.indices.contains(j) else { note(delta > 0 ? "at the last cue" : "at the first cue"); return }
        goTo(index: j)
    }

    // MARK: -

    private func load(_ c: RundownCue) {
        timer.stop()
        timer.mode = .countDown
        timer.countdownDuration = TimeInterval(c.durationSeconds)
        timer.reset()
        selectedID = c.id
    }

    private func note(_ what: String) {
        lastAction = what
        ShowLog.log("cue timer: \(what)")
    }
}

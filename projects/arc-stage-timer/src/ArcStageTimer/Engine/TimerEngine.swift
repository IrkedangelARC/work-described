//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation
import Combine
#if os(iOS)
import UIKit  // for isIdleTimerDisabled
#endif

enum TimerState: String {
    case idle
    case running
    case paused
    case overtime
    case finished
}

@Observable
final class TimerEngine {
    // MARK: - State

    private(set) var state: TimerState = .idle
    private(set) var elapsedSeconds: Int = 0
    private(set) var colorState: TimerColorState = .idle

    var cues: [Cue] = []
    private(set) var currentCueIndex: Int = 0
    private var currentCueID: UUID?

    var autoAdvance: Bool = false

    // MARK: - Undo

    private var undoAction: (() -> Void)?
    private(set) var undoActionName: String?

    var canUndo: Bool { undoAction != nil }

    /// Execute single-step undo. Clears the undo state after execution.
    func undo() {
        guard let action = undoAction else { return }
        let name = undoActionName
        undoAction = nil
        undoActionName = nil
        action()
        _ = name // consumed
    }

    private func registerUndo(name: String, action: @escaping () -> Void) {
        undoAction = action
        undoActionName = name
    }

    // MARK: - Schedule Tracking

    private(set) var isScheduledShow: Bool = false
    private(set) var showStartedAt: Date?
    private(set) var cueActualStartTimes: [UUID: Date] = [:]
    private var interCuePauseStart: Date?
    private(set) var totalPauseSeconds: TimeInterval = 0

    // MARK: - Session Recording

    struct CueRecord: Identifiable {
        let id: UUID
        let cueID: UUID
        let title: String
        var actualStart: Date?
        var actualEnd: Date?
        var elapsedSeconds: Int = 0
        var scheduledDuration: Int = 0
    }

    private(set) var sessionLog: [CueRecord] = []

    var formattedPauseTime: String {
        let total = Int(totalPauseSeconds)
        let m = total / 60
        let s = total % 60
        return "\(m):\(String(format: "%02d", s))"
    }

    // MARK: - Platform Sleep Prevention

    #if os(macOS)
    private var sleepActivity: NSObjectProtocol?
    #endif

    // MARK: - Computed

    var currentCue: Cue? {
        guard currentCueIndex >= 0, currentCueIndex < cues.count else { return nil }
        return cues[currentCueIndex]
    }

    var nextCue: Cue? {
        let next = currentCueIndex + 1
        guard next < cues.count else { return nil }
        return cues[next]
    }

    var remainingSeconds: Int {
        guard let cue = currentCue else { return 0 }
        return max(cue.durationSeconds - elapsedSeconds, 0)
    }

    var overtimeSeconds: Int {
        guard let cue = currentCue else { return 0 }
        return max(elapsedSeconds - cue.durationSeconds, 0)
    }

    var isOvertime: Bool {
        guard let cue = currentCue else { return false }
        return elapsedSeconds > cue.durationSeconds
    }

    var progress: Double {
        guard let cue = currentCue, cue.durationSeconds > 0 else { return 0 }
        return min(Double(elapsedSeconds) / Double(cue.durationSeconds), 1.0)
    }

    var displayTime: String {
        if isOvertime {
            return formatTime(overtimeSeconds, prefix: "+")
        }
        return formatTime(remainingSeconds)
    }

    var hasNext: Bool { currentCueIndex < cues.count - 1 }
    var hasPrevious: Bool { currentCueIndex > 0 }

    // MARK: - Offset Computed Properties

    var showOffsetSeconds: Int {
        guard isScheduledShow, let currentCue = currentCue,
              let scheduledStart = currentCue.startTime else { return 0 }
        let now = Date()
        if state == .idle || state == .finished {
            // Between cues: offset = how late we are vs scheduled start of this cue
            guard showStartedAt != nil else { return 0 }
            return Int(now.timeIntervalSince(scheduledStart))
        } else {
            // During cue: offset = (actual start - scheduled start) + overtime
            guard let actualStart = cueActualStartTimes[currentCue.id] else { return 0 }
            let startOffset = Int(actualStart.timeIntervalSince(scheduledStart))
            let overtime = max(0, elapsedSeconds - currentCue.durationSeconds)
            return startOffset + overtime
        }
    }

    var showOffsetDisplay: String {
        let total = abs(showOffsetSeconds)
        let m = total / 60
        let s = total % 60
        if abs(showOffsetSeconds) <= 30 { return "ON TIME" }
        let sign = showOffsetSeconds > 0 ? "+" : "-"
        if m > 0 {
            return "\(sign)\(m):\(String(format: "%02d", s))"
        }
        return "\(sign)0:\(String(format: "%02d", s))"
    }

    var offsetStatus: OffsetStatus {
        OffsetStatus.from(offsetSeconds: showOffsetSeconds)
    }

    func projectedStartTime(for index: Int) -> Date? {
        guard isScheduledShow, index >= 0, index < cues.count else { return nil }
        guard let scheduledStart = cues[index].startTime else { return nil }
        // Projected = scheduled + current offset
        return scheduledStart.addingTimeInterval(TimeInterval(showOffsetSeconds))
    }

    // MARK: - Schedule Shift (Phase 1)

    /// Shifts all remaining cue startTimes forward by the current offset so
    /// the show is "on time" from this point forward. Returns the shift in seconds.
    @discardableResult
    func shiftScheduleToNow() -> Int {
        guard isScheduledShow, showOffsetSeconds > 30 else { return 0 }
        let shift = showOffsetSeconds
        let shiftInterval = TimeInterval(shift)
        let startIdx = currentCueIndex
        // Register undo: shift back by the negative amount
        registerUndo(name: "Shift Schedule") { [weak self] in
            guard let self else { return }
            for i in startIdx..<self.cues.count {
                if let start = self.cues[i].startTime {
                    self.cues[i].startTime = start.addingTimeInterval(-shiftInterval)
                }
            }
        }
        // Shift current + all future cues
        for i in startIdx..<cues.count {
            if let start = cues[i].startTime {
                cues[i].startTime = start.addingTimeInterval(shiftInterval)
            }
        }
        return shift
    }

    // MARK: - Live Cue Manipulation (Phase 2)

    /// Insert a cue after the given index (nil = append to end).
    /// Returns the index where the cue was inserted.
    @discardableResult
    func insertCue(_ cue: Cue, afterIndex: Int?) -> Int {
        let insertAt: Int
        if let after = afterIndex {
            insertAt = min(after + 1, cues.count)
        } else {
            insertAt = cues.count
        }
        // Register undo: remove the cue we're about to insert
        registerUndo(name: "Add Cue") { [weak self] in
            guard let self else { return }
            if insertAt < self.cues.count, self.cues[insertAt].id == cue.id {
                self.cues.remove(at: insertAt)
                self.reindexSortOrder(from: insertAt)
                self.resyncIndex()
                if !self.cues.isEmpty {
                    self.recalculateStartTimes(from: max(0, insertAt - 1))
                }
            }
        }
        cues.insert(cue, at: insertAt)
        reindexSortOrder(from: insertAt)
        resyncIndex()
        recalculateStartTimes(from: max(0, insertAt - 1))
        return insertAt
    }

    /// Remove the cue at the given index. Returns false if it's the
    /// currently-running cue or the index is invalid.
    func removeCue(at index: Int) -> Bool {
        guard index >= 0, index < cues.count else { return false }
        guard index != currentCueIndex || state == .idle else { return false }
        let removedCue = cues[index]
        // Register undo: re-insert the removed cue at its original position
        registerUndo(name: "Remove Cue") { [weak self] in
            guard let self else { return }
            let reinsertAt = min(index, self.cues.count)
            self.cues.insert(removedCue, at: reinsertAt)
            self.reindexSortOrder(from: reinsertAt)
            self.resyncIndex()
            self.recalculateStartTimes(from: max(0, reinsertAt - 1))
        }
        cues.remove(at: index)
        reindexSortOrder(from: index)
        resyncIndex()
        if !cues.isEmpty {
            recalculateStartTimes(from: max(0, index - 1))
        }
        return true
    }

    /// Move a cue from one position to another.
    func moveCue(from source: Int, to destination: Int) {
        guard source >= 0, source < cues.count,
              destination >= 0, destination < cues.count,
              source != destination else { return }
        // Register undo: move back from destination to source
        registerUndo(name: "Move Cue") { [weak self] in
            guard let self else { return }
            guard destination >= 0, destination < self.cues.count,
                  source >= 0, source <= self.cues.count else { return }
            let cue = self.cues.remove(at: destination)
            self.cues.insert(cue, at: source)
            let start = min(source, destination)
            self.reindexSortOrder(from: start)
            self.resyncIndex()
            self.recalculateStartTimes(from: start)
        }
        let cue = cues.remove(at: source)
        cues.insert(cue, at: destination)
        let start = min(source, destination)
        reindexSortOrder(from: start)
        resyncIndex()
        recalculateStartTimes(from: start)
    }

    /// Store a full-editor edit on a cue, undoable as one step. Later cues re-chain their start
    /// times from this one, so a new duration or start moves the rest of a scheduled show with it.
    /// Returns false when the cue is no longer in the run order.
    @discardableResult
    func updateCue(id: UUID, with draft: CueDraft) -> Bool {
        guard let index = cues.firstIndex(where: { $0.id == id }) else { return false }
        let cue = cues[index]
        let before = CueDraft(cue)
        guard draft.normalized != before else { return true }
        registerUndo(name: "Edit Cue") { [weak self] in
            guard let self, let i = self.cues.firstIndex(where: { $0.id == id }) else { return }
            before.apply(to: self.cues[i])
            self.recalculateStartTimes(from: i + 1)
            self.updateColorState()
        }
        draft.apply(to: cue)
        recalculateStartTimes(from: index + 1)
        updateColorState()
        return true
    }

    // MARK: - Smart Compression (Phase 3)

    struct CompressionProposal: Identifiable {
        let id: UUID
        let cueID: UUID
        let title: String
        let format: CueFormat
        let originalDuration: Int
        let proposedDuration: Int

        var savedSeconds: Int { originalDuration - proposedDuration }
        var reductionPercent: Double {
            guard originalDuration > 0 else { return 0 }
            return Double(savedSeconds) / Double(originalDuration) * 100
        }
    }

    /// Calculate a compression proposal to recover the current schedule deficit.
    /// Returns nil if no compression is needed or possible.
    func calculateCompression() -> (proposals: [CompressionProposal], targetEnd: Date, originalEnd: Date, deficit: Int)? {
        guard isScheduledShow, showOffsetSeconds > 30 else { return nil }
        let deficit = showOffsetSeconds
        var remaining = deficit
        var proposals: [CompressionProposal] = []

        // Only compress future cues (after current)
        let futureCues = Array(cues.suffix(from: min(currentCueIndex + 1, cues.count)))
        guard !futureCues.isEmpty else { return nil }

        // Pass 1: Compress compressible cues (breaks, transitions, social, greenRoom)
        for cue in futureCues where remaining > 0 && cue.format.isCompressible {
            let floor = cue.format.minimumDurationSeconds
            let maxCut = Int(Double(cue.durationSeconds) * cue.format.maxCompressionRatio)
            let available = max(0, cue.durationSeconds - floor)
            let cut = min(min(maxCut, available), remaining)
            if cut > 0 {
                proposals.append(CompressionProposal(
                    id: UUID(),
                    cueID: cue.id,
                    title: cue.title,
                    format: cue.format,
                    originalDuration: cue.durationSeconds,
                    proposedDuration: cue.durationSeconds - cut
                ))
                remaining -= cut
            }
        }

        // Pass 2: Compress content cues if deficit remains
        for cue in futureCues where remaining > 0 && !cue.format.isCompressible {
            let floor = cue.format.minimumDurationSeconds
            let maxCut = Int(Double(cue.durationSeconds) * cue.format.maxCompressionRatio)
            let available = max(0, cue.durationSeconds - floor)
            let cut = min(min(maxCut, available), remaining)
            if cut > 0 {
                proposals.append(CompressionProposal(
                    id: UUID(),
                    cueID: cue.id,
                    title: cue.title,
                    format: cue.format,
                    originalDuration: cue.durationSeconds,
                    proposedDuration: cue.durationSeconds - cut
                ))
                remaining -= cut
            }
        }

        guard !proposals.isEmpty else { return nil }

        // Calculate end times
        let totalSaved = proposals.reduce(0) { $0 + $1.savedSeconds }
        let originalEnd: Date
        if let lastCue = cues.last, let lastStart = lastCue.startTime {
            originalEnd = lastStart.addingTimeInterval(Double(lastCue.durationSeconds))
        } else {
            originalEnd = Date()
        }
        let targetEnd = originalEnd.addingTimeInterval(Double(-totalSaved))

        return (proposals: proposals, targetEnd: targetEnd, originalEnd: originalEnd, deficit: deficit)
    }

    /// Apply a set of compression proposals — mutate durations and recalculate startTimes.
    func applyCompression(_ proposals: [CompressionProposal]) {
        // Capture original durations for undo
        let originals: [(cueID: UUID, duration: Int)] = proposals.compactMap { proposal in
            guard let idx = cues.firstIndex(where: { $0.id == proposal.cueID }) else { return nil }
            return (cueID: proposal.cueID, duration: cues[idx].durationSeconds)
        }
        let startIdx = currentCueIndex
        registerUndo(name: "Compress Schedule") { [weak self] in
            guard let self else { return }
            for original in originals {
                if let idx = self.cues.firstIndex(where: { $0.id == original.cueID }) {
                    self.cues[idx].durationSeconds = original.duration
                }
            }
            self.recalculateStartTimes(from: startIdx)
        }
        for proposal in proposals {
            if let idx = cues.firstIndex(where: { $0.id == proposal.cueID }) {
                cues[idx].durationSeconds = proposal.proposedDuration
            }
        }
        recalculateStartTimes(from: currentCueIndex)
    }

    // MARK: - Index Safety

    /// Re-derive currentCueIndex from currentCueID after any cue array mutation.
    private func resyncIndex() {
        guard let id = currentCueID,
              let idx = cues.firstIndex(where: { $0.id == id }) else {
            // Current cue was removed or array is empty — clamp to last valid
            currentCueIndex = max(0, cues.count - 1)
            currentCueID = cues.isEmpty ? nil : cues[currentCueIndex].id
            return
        }
        currentCueIndex = idx
    }

    /// Fix sortOrder values on all cues starting from a given index.
    private func reindexSortOrder(from startIndex: Int = 0) {
        for i in startIndex..<cues.count {
            cues[i].sortOrder = i
        }
    }

    /// Cascade startTime through cues from a given index. If the cue at `from`
    /// has no startTime, propagation stops (unscheduled shows are unaffected).
    func recalculateStartTimes(from startIndex: Int = 0) {
        guard !cues.isEmpty, startIndex < cues.count else { return }
        // Determine base time — either the cue's existing startTime or derived from prior cue
        var nextStart: Date?
        if startIndex == 0 {
            nextStart = cues[0].startTime
        } else {
            guard let prev = cues[startIndex - 1].startTime else { return }
            nextStart = prev.addingTimeInterval(Double(cues[startIndex - 1].durationSeconds))
        }
        guard var currentStart = nextStart else { return }
        for i in startIndex..<cues.count {
            cues[i].startTime = currentStart
            currentStart = currentStart.addingTimeInterval(Double(cues[i].durationSeconds))
        }
    }

    // MARK: - Private

    private var timer: AnyCancellable?
    private var tickDate: Date?
    private var accumulatedTime: TimeInterval = 0

    // MARK: - Timer Control

    /// What is on: the stage footer and the operate widget name the show.
    private(set) var showName: String = ""
    private(set) var showArcNumber: String?

    func loadShow(_ show: Show) {
        stop()
        showName = show.name
        showArcNumber = show.arcNumber
        cues = show.sortedCues
        currentCueIndex = 0
        currentCueID = cues.first?.id
        isScheduledShow = cues.contains { $0.startTime != nil }
        showStartedAt = nil
        cueActualStartTimes = [:]
        interCuePauseStart = nil
        totalPauseSeconds = 0
        state = cues.isEmpty ? .idle : .idle
        updateColorState()
    }

    func start() {
        guard let cue = currentCue else { return }
        let now = Date()
        state = .running
        accumulatedTime = 0
        tickDate = now
        // Record show start (first cue only)
        if showStartedAt == nil {
            showStartedAt = now
        }
        // Record actual start time for this cue
        cueActualStartTimes[cue.id] = now
        // Session log: record cue start
        sessionLog.append(CueRecord(
            id: UUID(), cueID: cue.id, title: cue.title,
            actualStart: now, scheduledDuration: cue.durationSeconds
        ))
        // Stop inter-cue pause tracking
        if let pauseStart = interCuePauseStart {
            totalPauseSeconds += now.timeIntervalSince(pauseStart)
            interCuePauseStart = nil
        }
        startTicking()
        disableSleep()
        updateColorState()
    }

    func pause() {
        guard state == .running || state == .overtime else { return }
        state = .paused
        stopTicking()
        // Note: deliberate pauses during a cue still count toward real time
        // (the offset tracks wall-clock vs schedule, not active run time)
    }

    func resume() {
        guard state == .paused else { return }
        state = isOvertime ? .overtime : .running
        tickDate = Date()
        startTicking()
    }

    func togglePlayPause() {
        switch state {
        case .idle, .finished:
            start()
        case .running, .overtime:
            pause()
        case .paused:
            resume()
        }
    }

    func stop() {
        // Session log: record final cue end
        if let idx = sessionLog.lastIndex(where: { $0.cueID == currentCueID && $0.actualEnd == nil }) {
            sessionLog[idx].actualEnd = Date()
            sessionLog[idx].elapsedSeconds = elapsedSeconds
        }
        state = .idle
        elapsedSeconds = 0
        accumulatedTime = 0
        showStartedAt = nil
        cueActualStartTimes = [:]
        interCuePauseStart = nil
        totalPauseSeconds = 0
        sessionLog = []
        stopTicking()
        enableSleep()
        updateColorState()
    }

    func reset() {
        let wasRunning = state == .running || state == .overtime
        elapsedSeconds = 0
        accumulatedTime = 0
        if wasRunning {
            tickDate = Date()
        }
        state = wasRunning ? .running : .idle
        updateColorState()
    }

    func next() {
        // Session log: record cue end
        if let idx = sessionLog.lastIndex(where: { $0.cueID == currentCueID }) {
            sessionLog[idx].actualEnd = Date()
            sessionLog[idx].elapsedSeconds = elapsedSeconds
        }
        guard hasNext else {
            state = .finished
            stopTicking()
            enableSleep()
            return
        }
        currentCueIndex += 1
        // Bounds safety: clamp if cues were removed concurrently
        guard currentCueIndex < cues.count else {
            currentCueIndex = max(0, cues.count - 1)
            currentCueID = cues.last?.id
            state = .finished
            stopTicking()
            enableSleep()
            return
        }
        currentCueID = cues[currentCueIndex].id
        elapsedSeconds = 0
        accumulatedTime = 0
        // Start inter-cue pause tracking
        interCuePauseStart = Date()
        // Always pause on cue change — operator presses play when ready
        state = .idle
        stopTicking()
        updateColorState()
    }

    func previous() {
        guard hasPrevious, currentCueIndex - 1 >= 0, currentCueIndex - 1 < cues.count else { return }
        currentCueIndex -= 1
        currentCueID = cues[currentCueIndex].id
        elapsedSeconds = 0
        accumulatedTime = 0
        interCuePauseStart = Date()
        state = .idle
        stopTicking()
        updateColorState()
    }

    func goToCue(at index: Int) {
        guard index >= 0, index < cues.count else { return }
        currentCueIndex = index
        currentCueID = cues[index].id
        elapsedSeconds = 0
        accumulatedTime = 0
        interCuePauseStart = Date()
        state = .idle
        stopTicking()
        updateColorState()
    }

    func addTime(seconds: Int) {
        guard let cue = currentCue else { return }
        cue.durationSeconds = max(cue.durationSeconds + seconds, 0)
        updateColorState()
    }

    func subtractTime(seconds: Int) {
        addTime(seconds: -seconds)
    }

    // MARK: - Sleep Prevention

    private func disableSleep() {
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = true
        #elseif os(macOS)
        if sleepActivity == nil {
            sleepActivity = ProcessInfo.processInfo.beginActivity(
                options: [.idleDisplaySleepDisabled, .idleSystemSleepDisabled],
                reason: "ARC Stage Timer running"
            )
        }
        #endif
    }

    private func enableSleep() {
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = false
        #elseif os(macOS)
        if let activity = sleepActivity {
            ProcessInfo.processInfo.endActivity(activity)
            sleepActivity = nil
        }
        #endif
    }

    // MARK: - Session Log Export

    /// Export session log as CSV data for post-show analysis
    func exportSessionLog() -> Data? {
        guard !sessionLog.isEmpty else { return nil }
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "HH:mm:ss"

        var csv = "Cue,Title,Scheduled (min),Actual (min),Delta (min),Start,End\n"
        for (i, record) in sessionLog.enumerated() {
            let scheduled = Double(record.scheduledDuration) / 60.0
            let actual = Double(record.elapsedSeconds) / 60.0
            let delta = actual - scheduled
            let startStr = record.actualStart.map { dateFormatter.string(from: $0) } ?? ""
            let endStr = record.actualEnd.map { dateFormatter.string(from: $0) } ?? ""
            // Escape title commas for CSV
            let safeTitle = record.title.contains(",") ? "\"\(record.title)\"" : record.title
            csv += "\(i + 1),\(safeTitle),\(String(format: "%.1f", scheduled)),\(String(format: "%.1f", actual)),\(String(format: "%+.1f", delta)),\(startStr),\(endStr)\n"
        }

        // Summary row
        let totalScheduled = sessionLog.reduce(0) { $0 + $1.scheduledDuration }
        let totalActual = sessionLog.reduce(0) { $0 + $1.elapsedSeconds }
        let totalDelta = totalActual - totalScheduled
        csv += "\n,TOTAL,\(String(format: "%.1f", Double(totalScheduled) / 60.0)),\(String(format: "%.1f", Double(totalActual) / 60.0)),\(String(format: "%+.1f", Double(totalDelta) / 60.0)),,\n"

        return csv.data(using: .utf8)
    }

    // MARK: - Private Tick

    private func startTicking() {
        stopTicking()
        timer = Timer.publish(every: 0.25, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.tick()
            }
    }

    private func stopTicking() {
        timer?.cancel()
        timer = nil
    }

    private func tick() {
        guard currentCueIndex >= 0, currentCueIndex < cues.count else {
            stopTicking()
            return
        }
        guard let tickDate, let cue = currentCue else { return }

        let now = Date()
        let delta = now.timeIntervalSince(tickDate)
        self.tickDate = now
        accumulatedTime += delta
        elapsedSeconds = Int(accumulatedTime)

        updateColorState()

        // Hit zero
        if elapsedSeconds >= cue.durationSeconds {
            if cue.overtimeAllowed {
                state = .overtime
            } else if autoAdvance {
                next()
            } else {
                state = .finished
                stopTicking()
            }
        }
    }

    private func updateColorState() {
        guard let cue = currentCue else {
            colorState = .idle
            return
        }
        guard state != .idle else {
            colorState = .idle
            return
        }
        colorState = TimerColorState.compute(
            remaining: remainingSeconds,
            warning: cue.warningThreshold,
            danger: cue.dangerThreshold,
            isOvertime: isOvertime
        )
    }

    // MARK: - Helpers

    private func formatTime(_ totalSeconds: Int, prefix: String = "") -> String {
        let h = totalSeconds / 3600
        let m = (totalSeconds % 3600) / 60
        let s = totalSeconds % 60
        if h > 0 {
            return "\(prefix)\(h):\(String(format: "%02d", m)):\(String(format: "%02d", s))"
        }
        return "\(prefix)\(String(format: "%02d", m)):\(String(format: "%02d", s))"
    }

}

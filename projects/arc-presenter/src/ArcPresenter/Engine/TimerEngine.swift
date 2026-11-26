//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation

enum TimerUrgency {
    case normal
    case warning
    case critical
    case overtime

    static func compute(
        mode: TimerEngine.Mode,
        elapsed: TimeInterval,
        countdownDuration: TimeInterval,
        warningSeconds: Int,
        criticalSeconds: Int
    ) -> TimerUrgency {
        guard mode == .countDown else { return .normal }
        if elapsed > countdownDuration { return .overtime }
        let remaining = Int(countdownDuration - elapsed)
        if remaining <= criticalSeconds { return .critical }
        if remaining <= warningSeconds { return .warning }
        return .normal
    }
}

@MainActor
@Observable
final class TimerEngine {
    enum Mode: String, CaseIterable {
        case countUp = "Count Up"
        case countDown = "Count Down"
    }

    private(set) var elapsed: TimeInterval = 0
    private(set) var isRunning: Bool = false
    var mode: Mode = .countUp
    var countdownDuration: TimeInterval = 30 * 60

    private var timer: Timer?
    private var startDate: Date?
    private var accumulatedTime: TimeInterval = 0

    /// What survives a relaunch: a running timer keeps its start date, so the
    /// elapsed time is right even across the seconds the app was gone.
    struct Snapshot: Codable, Equatable {
        let mode: String
        let countdownDuration: TimeInterval
        let accumulated: TimeInterval
        let startedAt: Date?
    }

    /// Reads no ticking property (the saver observes this).
    var snapshot: Snapshot {
        Snapshot(mode: mode.rawValue, countdownDuration: countdownDuration, accumulated: accumulatedTime, startedAt: startDate)
    }

    func restore(_ s: Snapshot) {
        stop()
        if let m = Mode(rawValue: s.mode) { mode = m }
        countdownDuration = s.countdownDuration
        accumulatedTime = max(0, s.accumulated)
        elapsed = accumulatedTime
        if let started = s.startedAt {
            isRunning = true
            startDate = started
            timer = Timer.commonModes(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.tick() }
            }
            tick()
        }
    }

    var remaining: TimeInterval {
        max(0, countdownDuration - elapsed)
    }

    /// The time of day a running countdown reaches zero; nil when not running, counting up, or already over.
    var endsAt: Date? {
        guard isRunning, mode == .countDown, !isOvertime else { return nil }
        return Date().addingTimeInterval(remaining)
    }

    /// How long the timer has run, as the digits show it (for a countdown's ELAPSED readout).
    var elapsedString: String { Self.format(elapsed) }

    static func format(_ time: TimeInterval) -> String {
        let hours = Int(time) / 3600
        let minutes = (Int(time) % 3600) / 60
        let seconds = Int(time) % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, seconds) }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    var displayTime: TimeInterval {
        mode == .countUp ? elapsed : remaining
    }

    var displayString: String {
        let time = displayTime
        let hours = Int(time) / 3600
        let minutes = (Int(time) % 3600) / 60
        let seconds = Int(time) % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    var isOvertime: Bool {
        mode == .countDown && elapsed > countdownDuration
    }

    var overtimeString: String {
        guard isOvertime else { return "" }
        let over = elapsed - countdownDuration
        let total = Int(over)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "+%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "+%d:%02d", minutes, seconds)
    }

    func start() {
        guard !isRunning else { return }
        ShowLog.log("timer start (\(mode.rawValue), \(durationDisplayString))")
        isRunning = true
        startDate = Date()
        timer = Timer.commonModes(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tick()
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        ShowLog.log("timer stop at \(displayString)")
        isRunning = false
        accumulatedTime = elapsed
        startDate = nil
        timer?.invalidate()
        timer = nil
    }

    func reset() {
        stop()
        ShowLog.log("timer reset")
        elapsed = 0
        accumulatedTime = 0
    }

    func toggle() {
        if isRunning { stop() } else { start() }
    }

    func adjustDuration(byMinutes minutes: Int) {
        let newDuration = countdownDuration + TimeInterval(minutes * 60)
        countdownDuration = max(60, newDuration)
    }

    var durationDisplayString: String {
        let total = Int(countdownDuration)
        let hours = total / 3600
        let mins = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, mins, secs)
        }
        return String(format: "%d:%02d", mins, secs)
    }

    func setDuration(from text: String) {
        let parts = text.split(separator: ":").compactMap { Int($0) }
        var totalSeconds = 0
        switch parts.count {
        case 1: totalSeconds = parts[0] * 60
        case 2: totalSeconds = parts[0] * 60 + parts[1]
        case 3: totalSeconds = parts[0] * 3600 + parts[1] * 60 + parts[2]
        default: return
        }
        guard totalSeconds > 0 else { return }
        countdownDuration = TimeInterval(totalSeconds)
    }

    private func tick() {
        guard let start = startDate else { return }
        elapsed = accumulatedTime + Date().timeIntervalSince(start)
    }
}

extension Timer {
    /// A repeating timer on the main run loop in COMMON modes. `Timer.scheduledTimer` schedules in
    /// the default mode only, which the run loop leaves while a SwiftUI gesture tracks the mouse:
    /// during a grip drag on the confidence monitor the stage clock stopped ticking and the health
    /// heartbeat reported the whole drag as main-thread lag (2.6 s for a 2.4 s drag; measured
    /// 2026-09-19, the same values over the control route produced none). Every timer in the app
    /// goes through here.
    @discardableResult
    static func commonModes(withTimeInterval interval: TimeInterval, repeats: Bool, block: @escaping @MainActor (Timer) -> Void) -> Timer {
        // Fires on the main run loop, so the block runs on the main actor, as every caller (all main-actor code) expects.
        let t = Timer(timeInterval: interval, repeats: repeats) { timer in MainActor.assumeIsolated { block(timer) } }
        RunLoop.main.add(t, forMode: .common)
        return t
    }
}

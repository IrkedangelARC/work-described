//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation
import SwiftUI

/// Live picture of what the capture is doing, for the monitor window
/// (2026-09-12: "a GUI for capture that displays what it is doing in
/// real time"). Every DebugLog line lands here too, so the window shows the
/// same story as /tmp/arc-capture.log. Main-actor, observable.
@MainActor @Observable
final class CaptureMonitor {
    static let shared = CaptureMonitor()

    struct Line: Identifiable {
        let id = UUID()
        let time: Date
        let tag: String
        let message: String
    }

    /// What the session is doing right now, in operator words.
    var phase: String = "idle"
    /// PowerPoint's slide number the show is on, and the visible total.
    var pptxSlide: Int = 0
    var totalSlides: Int = 0
    var hiddenSlides: Int = 0
    var movieSlides: Int = 0
    var loopSlides: Int = 0
    var autoAdvanceSlides: Int = 0
    /// Clicks of the current slide: done / expected (-1 = unknown).
    var clicksDone: Int = 0
    var clicksExpected: Int = -1
    /// Seconds left on a movie/loop hold, when one is running.
    var holdRemaining: Double = 0
    var holdTotal: Double = 0
    /// Stream health.
    var framesPerSecond: Double = 0
    var lastFrameAge: Double = 0
    var streamRestarts: Int = 0
    /// Seconds since captured app audio was last above the silence floor.
    var soundAge: Double = -1
    var stalls: Int = 0
    var recording: Bool = false
    var recordingSeconds: Double = 0
    var startedAt: Date?
    var warnings: [String] = []
    var lines: [Line] = []
    /// Transition clips written so far (clip is only the way into a slide).
    var transitionsCaptured: Int = 0
    /// One line about the last slide finalised, in operator words.
    var lastCaptured: String = "—"

    private var frameStamps: [Date] = []

    func reset() {
        phase = "idle"; pptxSlide = 0; totalSlides = 0; hiddenSlides = 0; movieSlides = 0; loopSlides = 0; autoAdvanceSlides = 0
        clicksDone = 0; clicksExpected = -1; holdRemaining = 0; holdTotal = 0
        framesPerSecond = 0; lastFrameAge = 0; streamRestarts = 0; stalls = 0; recording = false; recordingSeconds = 0
        startedAt = Date(); warnings = []; lines = []; frameStamps = []
        transitionsCaptured = 0; lastCaptured = "—"
    }

    func log(_ tag: String, _ message: String) {
        // Per-frame statistics stay in /tmp/arc-capture.log; on screen they
        // buried every event under 30 lines a second (2026-09-12).
        if tag == "Frame", message.hasPrefix("f#") { return }
        lines.append(Line(time: Date(), tag: tag, message: message))
        if lines.count > 400 { lines.removeFirst(lines.count - 400) }
        if tag == "Frame", message.hasPrefix("stream restarted") { streamRestarts += 1 }
        if message.hasPrefix("STALL") { stalls += 1 }
    }

    /// Called per delivered frame (cheap): keeps a one-second rate window.
    func frameArrived() {
        let now = Date()
        frameStamps.append(now)
        frameStamps.removeAll { now.timeIntervalSince($0) > 1.0 }
        framesPerSecond = Double(frameStamps.count)
        lastFrameAge = 0
    }

    /// Timer tick from the view (4 Hz): ages and countdowns.
    func tick() {
        if let last = frameStamps.last { lastFrameAge = Date().timeIntervalSince(last) }
        if let s = frameStamps.last, Date().timeIntervalSince(s) > 1.0 { framesPerSecond = 0 }
    }

    var elapsed: TimeInterval { startedAt.map { Date().timeIntervalSince($0) } ?? 0 }
}

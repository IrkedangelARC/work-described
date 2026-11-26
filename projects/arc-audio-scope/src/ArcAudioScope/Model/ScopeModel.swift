//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation
import ScopeKit
import SwiftUI

/// A marker on the waterfall's time axis.
struct ScopeMark: Identifiable, Equatable {
    enum Kind { case ring, clip, manual }
    let id = UUID()
    var kind: Kind
    /// Analyser clock, seconds.
    var time: Double
    /// Hz for a ring or a hand mark that found a line, nil for a clip (drawn across the full width).
    var frequency: Double?
}

/// The RING OUT screen's live data: the RTA traces, the open ring flags, the waterfall's
/// freeze and scrub state. Its own ObservableObject so the 20 Hz stream redraws only the views
/// that show it. Settings live in the show file (MeterModel); the slices live in `history`.
@MainActor
final class ScopeModel: ObservableObject {
    @Published private(set) var frame = ScopeFrame()
    /// Rings still sounding.
    @Published private(set) var openFlags: [RingFlag] = []
    @Published private(set) var marks: [ScopeMark] = []
    /// Slice number the waterfall is frozen at (nil = live), and how far back it is scrubbed.
    @Published private(set) var frozenAt: Int?
    @Published var scrubSeconds = 0.0
    /// Cursor on the shared frequency axis, 0...1 across the plot. Nil when not pointing.
    @Published var cursor: Double?
    /// Where the waterfall sits in the root view, for the screen capture.
    var waterfallFrame = CGRect.zero

    let history = SliceHistory()
    /// The waterfall's renderer. Nil only where Metal is missing.
    private(set) lazy var renderer = WaterfallRenderer(history: history)
    private(set) var sliceInterval = 0.02
    /// How far behind the sound the newest slice is (the analyser centres its windows).
    private(set) var latency = 0.0
    /// Called for every ring flag opened or closed, with the wall-clock time of its hit.
    var onRing: ((RingFlag, Date) -> Void)?

    /// Which source the switch is set to: the test signal, or the microphone.
    private var testSource = false

    var isFrozen: Bool { frozenAt != nil }

    func engineStarted(sliceInterval: Double, latency: Double) {
        self.sliceInterval = sliceInterval
        self.latency = latency
        frame = ScopeFrame()
        openFlags = []
        marks = []
        frozenAt = nil
        scrubSeconds = 0
    }

    func engineStopped() {
        openFlags = []
    }

    func receive(_ f: ScopeFrame) {
        // The engine changes source a moment after the switch is thrown. Flags in a frame still
        // made from the old source are the old source's, and are dropped.
        for e in f.events where f.testSignal == testSource {
            if e.final {
                openFlags.removeAll { $0.id == e.id }
            } else {
                openFlags.append(e)
                marks.append(ScopeMark(kind: .ring, time: e.time, frequency: e.frequency))
            }
            onRing?(e, Date().addingTimeInterval(e.time - f.time - latency))
        }
        // Marks older than the history are gone from the waterfall too.
        let oldest = f.time - Double(SliceHistory.capacity) * sliceInterval
        if let first = marks.first, first.time < oldest { marks.removeAll { $0.time < oldest } }
        frame = f
    }

    /// The source changed (microphone or test signal): what was flagged belongs to the old one.
    func sourceChanged(test: Bool) {
        testSource = test
        openFlags = []
        marks = []
    }

    /// The tech marked this moment by hand. `frequency` is what the analysis named, if anything.
    func markManual(time: Double, frequency: Double?) {
        marks.append(ScopeMark(kind: .manual, time: time, frequency: frequency))
    }

    func markClip() {
        marks.append(ScopeMark(kind: .clip, time: frame.time, frequency: nil))
    }

    // MARK: freeze and scrub

    func setFrozen(_ on: Bool) {
        if on {
            if frozenAt == nil { frozenAt = history.state.total }
        } else {
            frozenAt = nil
            scrubSeconds = 0
        }
    }

    /// Seconds of history behind the frozen point that can still be scrubbed to.
    func scrubLimit(span: Double) -> Double {
        guard let frozenAt else { return 0 }
        let s = history.state
        let held = min(s.total, SliceHistory.capacity)
        let lost = s.total - frozenAt            // slices written since the freeze push the oldest out
        return max(0, Double(held - lost) * sliceInterval - span)
    }

    func scrub(to seconds: Double, span: Double) {
        scrubSeconds = min(max(0, seconds), scrubLimit(span: span))
    }

    /// The slice number at the top of the waterfall, and the analyser time there.
    var headSlice: Int {
        guard let frozenAt else { return history.state.total }
        return max(1, frozenAt - Int((scrubSeconds / sliceInterval).rounded()))
    }
    var headTime: Double { Double(headSlice) * sliceInterval }
}

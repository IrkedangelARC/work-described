//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation
import AppKit
import SwiftUI

@MainActor
@Observable
final class UserPreferences {
    private static let logoKey = "confidenceMonitorLogoBookmark"
    private static let resetOnQuitKey = "resetSessionOnQuit"
    private static let timerWarningSecondsKey = "timerWarningSeconds"
    private static let timerCriticalSecondsKey = "timerCriticalSeconds"

    static let defaultWarningSeconds = 300
    static let defaultCriticalSeconds = 60

    var customLogoImage: NSImage?
    private(set) var customLogoURL: URL?

    private static let quickMessagesKey = "quickMessages"
    /// The MESSAGE TO PRESENTER preset grid (12 entries). Empty strings are
    /// allowed and rendered as blank buttons that send nothing.
    static var storedQuickMessages: [String] {
        let stored = UserDefaults.standard.stringArray(forKey: quickMessagesKey) ?? []
        return stored.count == MessageEngine.defaultQuickMessages.count ? stored : MessageEngine.defaultQuickMessages
    }
    var quickMessages: [String] {
        get { Self.storedQuickMessages }
        set { UserDefaults.standard.set(newValue, forKey: Self.quickMessagesKey); quickMessagesVersion += 1 }
    }
    /// Bumped on every edit so views re-read the stored list.
    var quickMessagesVersion = 0
    func resetQuickMessages() { UserDefaults.standard.removeObject(forKey: Self.quickMessagesKey); quickMessagesVersion += 1 }

    var resetOnQuit: Bool {
        get { UserDefaults.standard.bool(forKey: Self.resetOnQuitKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.resetOnQuitKey) }
    }

    /// V5: a newer verified version of a deck that is NOT live replaces it in
    /// place on its own. Default on; a live deck is never touched either way.
    private static let autoApplyDeckUpdatesKey = "autoApplyDeckUpdates"
    static var autoApplyDeckUpdates: Bool { (UserDefaults.standard.object(forKey: autoApplyDeckUpdatesKey) as? Bool) ?? true }
    var autoApplyDeckUpdates: Bool {
        get { Self.autoApplyDeckUpdates }
        set { UserDefaults.standard.set(newValue, forKey: Self.autoApplyDeckUpdatesKey) }
    }

    /// Console text size (ARCTheme.textScale reads it once at launch): 1.0, 1.15, 1.3.
    private static let consoleTextScaleKey = "consoleTextScale"
    var consoleTextScale: Double {
        get { let v = UserDefaults.standard.double(forKey: Self.consoleTextScaleKey); return v >= 0.9 && v <= 1.5 ? v : 1.0 }
        set { UserDefaults.standard.set(newValue, forKey: Self.consoleTextScaleKey) }
    }

    var timerWarningSeconds: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: Self.timerWarningSecondsKey)
            return stored > 0 ? stored : Self.defaultWarningSeconds
        }
        set { UserDefaults.standard.set(max(1, newValue), forKey: Self.timerWarningSecondsKey) }
    }

    var timerCriticalSeconds: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: Self.timerCriticalSecondsKey)
            return stored > 0 ? stored : Self.defaultCriticalSeconds
        }
        set { UserDefaults.standard.set(max(1, newValue), forKey: Self.timerCriticalSecondsKey) }
    }


    // MARK: - Confidence monitor layout (V4.1, 2026-09-16)
    //
    // Text size for the notes on the confidence monitor and the size of its
    // panes: the slide area's share of the width, and the NEXT / NOTES shares
    // of the right column (the timer takes what is left). Dragged on the
    // monitor itself or set in Preferences; both persist here.

    private static let notesFontSizeKey = "confidenceNotesFontSize"
    private static let notesModeFontSizeKey = "confidenceNotesFontSizeNotesLayout"
    private static let slideFractionKey = "confidenceSlideFraction"
    private static let rowFractionKey = "confidenceNotesRowFraction"
    private static let layoutModeKey = "confidenceLayoutMode"

    /// Bumped on every layout change so the monitor re-reads the stored values.
    var confidenceLayoutVersion = 0

    /// Which layout the monitor is in: SLIDES (the slide leads) or NOTES (the
    /// text leads, the slides are thumbnails). Set from the operator's MONITOR
    /// section, the menu, POST /monitor/layout (2026-09-17: "a control on
    /// the operator page to shift to a notes heavy layout").
    var confidenceLayoutMode: ConfidenceLayout.Mode {
        get { ConfidenceLayout.Mode(rawValue: UserDefaults.standard.string(forKey: Self.layoutModeKey) ?? "") ?? .slides }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Self.layoutModeKey); confidenceLayoutVersion += 1 }
    }

    /// Each layout keeps its own text size: going to NOTES is asking for bigger text, and coming back must not leave it oversized.
    private var fontKey: String { confidenceLayoutMode == .notes ? Self.notesModeFontSizeKey : Self.notesFontSizeKey }
    var confidenceNotesFontSize: Double {
        get { ConfidenceLayout.clampNotesFontSize(Self.read(fontKey, default: ConfidenceLayout.defaultNotesFontSize(confidenceLayoutMode))) }
        set { Self.write(fontKey, ConfidenceLayout.clampNotesFontSize(newValue)); confidenceLayoutVersion += 1 }
    }
    /// One step larger or smaller (the monitor's A- / A+, the menu keys, POST /notes/font).
    func stepNotesFont(_ direction: Int) { confidenceNotesFontSize += Double(direction) * ConfidenceLayout.notesFontStep }

    var confidenceSlideFraction: Double {
        get { Self.read(Self.slideFractionKey, default: ConfidenceLayout.defaultSlideFraction) }
        set { Self.write(Self.slideFractionKey, ConfidenceLayout.clampSlideFraction(newValue)); confidenceLayoutVersion += 1 }
    }
    /// NOTES layout: the share of the height the row of CURRENT, NEXT and TIMER takes.
    var confidenceNotesRowFraction: Double {
        get { Self.read(Self.rowFractionKey, default: ConfidenceLayout.defaultRowFraction) }
        set { Self.write(Self.rowFractionKey, ConfidenceLayout.clampRowFraction(newValue)); confidenceLayoutVersion += 1 }
    }
    // Which modules are on the monitor (2026-09-19: "fully customisable
    // and resizable using controls on the operator page"). Stored as what is
    // HIDDEN so a fresh install shows everything (UserDefaults reads 0 / false).
    private static let hiddenModulesKey = "confidenceHiddenModules"
    private static let logoHiddenKey = "confidenceTimerLogoHidden"
    private static let clockHiddenKey = "confidenceTimerClockHidden"

    var confidenceModules: ConfidenceLayout.Modules {
        get { ConfidenceLayout.Modules.all.subtracting(ConfidenceLayout.Modules(rawValue: UserDefaults.standard.integer(forKey: Self.hiddenModulesKey))) }
        set { UserDefaults.standard.set(ConfidenceLayout.Modules.all.subtracting(newValue).rawValue, forKey: Self.hiddenModulesKey); confidenceLayoutVersion += 1 }
    }
    func setModule(_ m: ConfidenceLayout.Modules, shown: Bool) {
        var v = confidenceModules
        if shown { v.formUnion(m) } else { v.subtract(m) }
        confidenceModules = v
    }
    /// The readouts under the timer's label. Stored as what is SHOWN: all off on a fresh install.
    private static let timerInfoKey = "confidenceTimerInfo"
    var confidenceTimerInfo: ConfidenceLayout.TimerInfo {
        get { ConfidenceLayout.TimerInfo(rawValue: UserDefaults.standard.integer(forKey: Self.timerInfoKey)).intersection(.all) }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Self.timerInfoKey); confidenceLayoutVersion += 1 }
    }
    func setTimerInfo(_ i: ConfidenceLayout.TimerInfo, shown: Bool) {
        var v = confidenceTimerInfo
        if shown { v.formUnion(i) } else { v.subtract(i) }
        confidenceTimerInfo = v
    }
    /// The logo at the right of the TIMER strip.
    var confidenceTimerLogo: Bool {
        get { !UserDefaults.standard.bool(forKey: Self.logoHiddenKey) }
        set { UserDefaults.standard.set(!newValue, forKey: Self.logoHiddenKey); confidenceLayoutVersion += 1 }
    }
    /// The time of day in the TIMER band.
    var confidenceTimerClock: Bool {
        get { !UserDefaults.standard.bool(forKey: Self.clockHiddenKey) }
        set { UserDefaults.standard.set(!newValue, forKey: Self.clockHiddenKey); confidenceLayoutVersion += 1 }
    }
    // The timer's and the notes' own sizes (2026-09-19: "adjust the timer
    // and notes view as well"). Absent (0) = AUTO, the remainder under the picture.
    private static let timerFractionKey = "confidenceTimerFraction"            // SLIDES: share of the left column's height
    private static let notesFractionKey = "confidenceNotesFraction"            // SLIDES: share of the right column's height
    private static let timerWidthFractionKey = "confidenceTimerWidthFraction"  // NOTES: share of the row's width

    private static func readOptional(_ key: String) -> Double? {
        let v = UserDefaults.standard.double(forKey: key)
        return v > 0 ? v : nil
    }
    private func writeOptional(_ key: String, _ value: Double?, clamp: (Double) -> Double) {
        // A value that is not finite is AUTO, not a range extreme (review, 2026-09-19: ?timerSize=nan collapsed the strip).
        if let value, value.isFinite { UserDefaults.standard.set(clamp(value), forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        confidenceLayoutVersion += 1
    }
    var confidenceTimerFraction: Double? {
        get { Self.readOptional(Self.timerFractionKey) }
        set { writeOptional(Self.timerFractionKey, newValue, clamp: ConfidenceLayout.clampTimerFraction) }
    }
    var confidenceNotesFraction: Double? {
        get { Self.readOptional(Self.notesFractionKey) }
        set { writeOptional(Self.notesFractionKey, newValue, clamp: ConfidenceLayout.clampNotesFraction) }
    }
    var confidenceTimerWidthFraction: Double? {
        get { Self.readOptional(Self.timerWidthFractionKey) }
        set { writeOptional(Self.timerWidthFractionKey, newValue, clamp: ConfidenceLayout.clampTimerWidthFraction) }
    }
    /// The timer's size for the layout in force (SLIDES: height share; NOTES: width share).
    var confidenceTimerSize: Double? {
        get { confidenceLayoutMode == .notes ? confidenceTimerWidthFraction : confidenceTimerFraction }
        set { if confidenceLayoutMode == .notes { confidenceTimerWidthFraction = newValue } else { confidenceTimerFraction = newValue } }
    }

    /// A grip's value, applied on the next pass of the run loop, one per pass. Applied inside
    /// the gesture's own event, SwiftUI laid the whole hosting view out synchronously per mouse
    /// event and the main thread fell 2 to 3 s behind (measured 2026-09-19, 24 events at 12 Hz;
    /// the same 24 values over the control route, which lands on the main actor between events,
    /// produced no lag at all).
    @ObservationIgnored private var pendingDrag: (ConfidenceLayout.Quantity, Double)?
    func dragQuantity(_ q: ConfidenceLayout.Quantity, _ value: Double) {
        let scheduled = pendingDrag != nil
        pendingDrag = (q, value)
        guard !scheduled else { return }
        DispatchQueue.main.async { [self] in
            guard let (q, v) = pendingDrag else { return }
            pendingDrag = nil
            setQuantity(q, v)
        }
    }

    /// One entry for every grip and slider: set a quantity for the layout in force.
    func setQuantity(_ q: ConfidenceLayout.Quantity, _ value: Double) {
        switch q {
        case .slide: confidenceSlideFraction = value
        case .row: confidenceNotesRowFraction = value
        case .timer: confidenceTimerSize = value
        case .notes: confidenceNotesFraction = value
        }
    }
    /// Whether a quantity is AUTO in the layout in force (the timer and the notes can be; the slide and the row never are).
    func isAuto(_ q: ConfidenceLayout.Quantity) -> Bool {
        switch q {
        case .slide, .row: return false
        case .timer: return confidenceTimerSize == nil
        case .notes: return confidenceNotesFraction == nil
        }
    }
    func setAuto(_ q: ConfidenceLayout.Quantity) {
        switch q {
        case .slide, .row: break
        case .timer: confidenceTimerSize = nil
        case .notes: confidenceNotesFraction = nil
        }
    }

    /// The monitor solved for a size: every view and the panel go through here so they agree.
    func solveConfidenceLayout(size: CGSize, aspect: Double) -> ConfidenceLayout.Frames {
        ConfidenceLayout.solve(size: size, mode: confidenceLayoutMode, slideFraction: confidenceSlideFraction, rowFraction: confidenceNotesRowFraction,
                               aspect: aspect, modules: confidenceModules, timerFraction: confidenceTimerSize, notesFraction: confidenceNotesFraction,
                               chrome: { ARCTheme.moduleChromeH(scale: $0) }, pad: { ARCTheme.modulePad * $0 })
    }

    func resetConfidenceLayout() {
        for k in [Self.notesFontSizeKey, Self.notesModeFontSizeKey, Self.slideFractionKey, Self.rowFractionKey,
                  Self.hiddenModulesKey, Self.logoHiddenKey, Self.clockHiddenKey, Self.timerInfoKey,
                  Self.timerFractionKey, Self.notesFractionKey, Self.timerWidthFractionKey] { UserDefaults.standard.removeObject(forKey: k) }
        confidenceLayoutVersion += 1
    }
    /// The whole layout as one JSON object (GET /monitor/layout, and every POST's answer).
    var monitorLayoutJSON: String {
        let m = confidenceModules
        return "{\"monitorLayout\":\"\(confidenceLayoutMode.rawValue)\",\"notesFontSize\":\(Int(confidenceNotesFontSize))"
            + ",\"slideFraction\":\((confidenceSlideFraction * 1000).rounded() / 1000),\"rowFraction\":\((confidenceNotesRowFraction * 1000).rounded() / 1000)"
            + ",\"next\":\(m.contains(.next)),\"timer\":\(m.contains(.timer)),\"notes\":\(m.contains(.notes))"
            + ",\"logo\":\(confidenceTimerLogo),\"clock\":\(confidenceTimerClock)"
            + ",\"cue\":\(confidenceTimerInfo.contains(.cue)),\"nextCue\":\(confidenceTimerInfo.contains(.nextCue)),\"ends\":\(confidenceTimerInfo.contains(.ends)),\"elapsed\":\(confidenceTimerInfo.contains(.elapsed))"
            + ",\"timerSize\":\(confidenceTimerSize.map { "\(($0 * 1000).rounded() / 1000)" } ?? "\"auto\""),\"notesSize\":\(confidenceNotesFraction.map { "\(($0 * 1000).rounded() / 1000)" } ?? "\"auto\"")}"
    }
    private static func read(_ key: String, default value: Double) -> Double {
        let stored = UserDefaults.standard.double(forKey: key)
        return stored > 0 ? stored : value
    }
    private static func write(_ key: String, _ value: Double) { UserDefaults.standard.set(value, forKey: key) }

    init() {
        loadLogo()
    }

    var hasCustomLogo: Bool {
        customLogoImage != nil
    }

    func setLogo(url: URL) {
        guard let bookmark = try? url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return }

        UserDefaults.standard.set(bookmark, forKey: Self.logoKey)
        customLogoURL = url
        customLogoImage = NSImage(contentsOf: url)
    }

    func clearLogo() {
        UserDefaults.standard.removeObject(forKey: Self.logoKey)
        customLogoURL = nil
        customLogoImage = nil
    }

    private func loadLogo() {
        guard let bookmark = UserDefaults.standard.data(forKey: Self.logoKey) else { return }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else { return }

        customLogoURL = url
        customLogoImage = NSImage(contentsOf: url)

        if stale, let newBookmark = try? url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            UserDefaults.standard.set(newBookmark, forKey: Self.logoKey)
        }
    }
}

/// The confidence monitor's two layouts, each solved in ONE place (layout
/// law: no accidental remainders; the text panel is the flexible one). Free
/// of UserDefaults, so it is tested.
///
/// SLIDES, given the share of the width the current slide takes. Left column:
/// CURRENT at the slide's exact aspect, the TIMER a wide short strip in what
/// is under it. Right column: NEXT at the same aspect, NOTES takes the rest,
/// tall, where PowerPoint's Presenter View has taught presenters to look.
/// First cut had the timer as the right column's remainder: "the timer is
/// taking up way too much space" (2026-09-17), then at 0.68 of the
/// width, "timer could be 20% smaller on this layout": the default share is
/// the one that makes it so, and the slide gets what the timer gave up.
///
/// NOTES, given the share of the HEIGHT a top row takes: CURRENT and NEXT as
/// thumbnails at the slide's aspect, the TIMER in what is left of the row,
/// and NOTES the full width of everything under it ("prioritizes text
/// readability with the current and next slides much smaller").
///
/// Modules (2026-09-19: "the presenter view fully customisable and
/// resizable using controls on the operator page"): NEXT, TIMER and NOTES
/// can each be taken off the monitor. A module that is off has a zero frame
/// and its room goes to its column-mate: no NEXT and the notes take the
/// whole right column; no NOTES and NEXT does; no TIMER and CURRENT has its
/// column's full height; nothing on the right and the slide has the width.
/// CURRENT is always there: a presenter's monitor without the slide is a
/// stage timer, and that is a different output.
///
/// Timer and notes sizes (same day: "adjust the timer and notes view
/// as well"): each is a remainder by default (`nil`, AUTO: the picture above
/// or beside it at its exact aspect, the module in what is left). Given a
/// share it is that share instead, and the picture gives way, letterboxed in
/// its box. SLIDES: the timer's share of the left column's height, the notes'
/// share of the right column's; NOTES: the timer's share of the row's width.
enum ConfidenceLayout {
    enum Mode: String, CaseIterable { case slides, notes }

    /// The modules the operator can take off the monitor. CURRENT is not one.
    struct Modules: OptionSet, Hashable {
        let rawValue: Int
        static let next  = Modules(rawValue: 1 << 0)
        static let timer = Modules(rawValue: 1 << 1)
        static let notes = Modules(rawValue: 1 << 2)
        static let all: Modules = [.next, .timer, .notes]
    }

    /// What the TIMER strip can say besides its digits (2026-09-19: "add more
    /// info to the timer block as options"). All off by default; each is a chip on the panel.
    struct TimerInfo: OptionSet, Hashable {
        let rawValue: Int
        static let cue     = TimerInfo(rawValue: 1 << 0)   // NOW: the selected cue's title and speakers
        static let nextCue = TimerInfo(rawValue: 1 << 1)   // NEXT: the cue after it
        static let ends    = TimerInfo(rawValue: 1 << 2)   // ENDS: the time of day a running countdown reaches zero
        static let elapsed = TimerInfo(rawValue: 1 << 3)   // ELAPSED: beside a countdown, how long it has run
        static let all: TimerInfo = [.cue, .nextCue, .ends, .elapsed]
    }

    /// The readout lines under the timer's label, in a fixed order, only those
    /// that are on AND have something to say (a line with nothing behind it is
    /// a hole on a stage monitor). Pure, so it is tested.
    static func timerLines(info: TimerInfo, cueTitle: String?, cueSpeakers: String?, nextTitle: String?,
                           endsAt: Date?, elapsed: String?, countingDown: Bool, now: Date = Date()) -> [(label: String, value: String)] {
        var lines: [(String, String)] = []
        func clean(_ s: String?) -> String? { let t = s?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""; return t.isEmpty ? nil : t }
        if info.contains(.cue), let t = clean(cueTitle) {
            lines.append(("NOW", clean(cueSpeakers).map { "\(t)  \u{00B7}  \($0)" } ?? t))
        }
        if info.contains(.nextCue), let t = clean(nextTitle) { lines.append(("NEXT", t)) }
        if info.contains(.ends), countingDown, let e = endsAt, e > now { lines.append(("ENDS", e.formatted(date: .omitted, time: .shortened))) }
        if info.contains(.elapsed), countingDown, let e = clean(elapsed) { lines.append(("ELAPSED", e)) }
        return lines
    }

    /// The quantities a layout is solved from; each is a grip on the monitor and a slider on the panel.
    enum Quantity: String, CaseIterable {
        case slide   // SLIDES: the slide's share of the width
        case row     // NOTES: the thumbnail row's share of the height
        case timer   // SLIDES: the timer's share of the left column's height; NOTES: its share of the row's width
        case notes   // SLIDES: the notes' share of the right column's height
    }

    // A stage monitor is read from metres away: 36 pt is the floor of comfortable, and A- / A+ move in steps of 4.
    static func defaultNotesFontSize(_ mode: Mode) -> Double { mode == .notes ? 52 : 36 }
    static let notesFontSizeRange: ClosedRange<Double> = 18...120
    static let notesFontStep: Double = 4
    static let defaultSlideFraction: Double = 0.735
    /// Narrower than 0.58 and the strip under the slide grows into a slab again; wider than 0.80 and the notes column is a ribbon.
    static let slideFractionRange: ClosedRange<Double> = 0.58...0.80
    static let defaultRowFraction: Double = 0.26
    /// Under 0.16 the thumbnails stop being readable as slides; over 0.40 it is not a notes layout any more.
    static let rowFractionRange: ClosedRange<Double> = 0.16...0.40
    /// SLIDES: the timer's share of its column. Under 0.08 the digits are a line; over 0.50 the slide is the thumbnail.
    static let timerFractionRange: ClosedRange<Double> = 0.08...0.50
    /// SLIDES: the notes' share of their column. Under 0.30 they are a caption; over 0.90 NEXT is a band.
    static let notesFractionRange: ClosedRange<Double> = 0.30...0.90
    /// NOTES: the timer's share of the row's width.
    static let timerWidthFractionRange: ClosedRange<Double> = 0.25...0.80

    // Swift's min/max pass NaN straight through (min(max(nan, lo), hi) == nan, checked 2026-09-19), and a
    // NaN reaching a CGRect is a SwiftUI trap. A value that is not finite is the default, over the route or anywhere.
    private static func clamp(_ v: Double, _ r: ClosedRange<Double>, default d: Double) -> Double { v.isFinite ? min(max(v, r.lowerBound), r.upperBound) : d }
    static func clampNotesFontSize(_ v: Double) -> Double { clamp(v, notesFontSizeRange, default: defaultNotesFontSize(.slides)) }
    static func clampSlideFraction(_ v: Double) -> Double { clamp(v, slideFractionRange, default: defaultSlideFraction) }
    static func clampRowFraction(_ v: Double) -> Double { clamp(v, rowFractionRange, default: defaultRowFraction) }
    static func clampTimerFraction(_ v: Double) -> Double { clamp(v, timerFractionRange, default: timerFractionRange.lowerBound) }
    static func clampNotesFraction(_ v: Double) -> Double { clamp(v, notesFractionRange, default: notesFractionRange.upperBound) }
    static func clampTimerWidthFraction(_ v: Double) -> Double { clamp(v, timerWidthFractionRange, default: timerWidthFractionRange.lowerBound) }

    /// The range a quantity's slider runs, per mode.
    static func range(of q: Quantity, mode: Mode) -> ClosedRange<Double> {
        switch (q, mode) {
        case (.slide, _): return slideFractionRange
        case (.row, _): return rowFractionRange
        case (.timer, .slides): return timerFractionRange
        case (.timer, .notes): return timerWidthFractionRange
        case (.notes, _): return notesFractionRange
        }
    }

    /// A grab area on the monitor: dragging it along its axis moves one quantity.
    struct Grip: Equatable {
        let quantity: Quantity
        let rect: CGRect
        /// Dragged left and right (a column boundary) or up and down (a row boundary).
        let sideways: Bool
    }

    /// Where each module goes, inside the monitor's outer padding (`gap` all round).
    /// A module that is off has a `.zero` frame.
    struct Frames: Equatable {
        let mode: Mode
        let modules: Modules
        /// Chrome scale against a 1080-line monitor (bands, titles, borders).
        let scale: CGFloat
        let gap: CGFloat
        /// The area inside the padding, that the shares are shares of.
        let content: CGSize
        let current: CGRect, next: CGRect, timer: CGRect, notes: CGRect
        /// The draggable boundaries. Empty when there is nothing to trade.
        let grips: [Grip]

        func shows(_ m: Modules) -> Bool { modules.contains(m) }
        /// The boundary between the columns (SLIDES) or under the row (NOTES), as it always was.
        var grip: CGRect { grips.first { $0.quantity == (mode == .slides ? .slide : .row) }?.rect ?? .zero }

        /// What a quantity is in this solution, explicit or AUTO: the value a slider shows and a drag starts from.
        func value(of q: Quantity) -> Double {
            let W = max(1, content.width), H = max(1, content.height)
            switch (q, mode) {
            case (.slide, _): return Double(current.width / max(1, W - gap))
            case (.row, _): return Double(current.height / H)
            case (.timer, .slides): return Double(timer.height / H)
            case (.timer, .notes): return Double(timer.width / W)
            case (.notes, _): return Double(notes.height / H)
            }
        }
    }

    /// `chrome(scale)` = what a module takes besides its content (band + padding), `pad(scale)` its side padding.
    /// `timerFraction` and `notesFraction` nil = AUTO (the remainder under the picture).
    static func solve(size: CGSize, mode: Mode = .slides, slideFraction: Double, rowFraction: Double = defaultRowFraction, aspect: Double,
                      modules: Modules = .all, timerFraction: Double? = nil, notesFraction: Double? = nil,
                      chrome: (CGFloat) -> CGFloat, pad: (CGFloat) -> CGFloat) -> Frames {
        let scale = min(max(size.height / 1080 * 1.5, 1), 3)
        let gap = (6 * scale).rounded()
        let a = CGFloat(aspect > 0.2 ? aspect : 16.0 / 9.0)
        let W = max(0, size.width - 2 * gap), H = max(0, size.height - 2 * gap)
        let c = chrome(scale), p = pad(scale)
        let showNext = modules.contains(.next), showTimer = modules.contains(.timer)
        let content = CGSize(width: W, height: H)
        switch mode {
        case .slides:
            let showNotes = modules.contains(.notes)
            let hasRight = showNext || showNotes
            let left = hasRight ? ((W - gap) * CGFloat(clampSlideFraction(slideFraction))).rounded() : W
            let right = hasRight ? max(0, W - gap - left) : 0
            // The timer strip always keeps room for its digits and NOTES for a few lines: the picture above them gives way (a 4:3 deck).
            let minTimer = c + 70 * scale, minNotes = c + 160 * scale
            let current: CGFloat
            if !showTimer { current = H }                                                        // no strip: the column's height
            else if let t = timerFraction { current = max(c, H - gap - (H * CGFloat(clampTimerFraction(t))).rounded()) }   // the strip's share, the slide in the rest
            else { current = min(c + max(0, left - 2 * p) / a, max(c, H - gap - minTimer)).rounded() }   // AUTO: the slide at its aspect, the strip in the rest
            let next: CGFloat
            if !showNext { next = 0 }
            else if !showNotes { next = H }                                                      // alone, NEXT is the column
            else if let n = notesFraction { next = max(c, H - gap - (H * CGFloat(clampNotesFraction(n))).rounded()) }
            else { next = min(c + max(0, right - 2 * p) / a, max(c, H - gap - minNotes)).rounded() }
            let nextGap: CGFloat = showNext && showNotes ? gap : 0
            var grips: [Grip] = []
            if hasRight { grips.append(Grip(quantity: .slide, rect: CGRect(x: left, y: 0, width: gap, height: H), sideways: true)) }
            if showTimer { grips.append(Grip(quantity: .timer, rect: CGRect(x: 0, y: current, width: left, height: gap), sideways: false)) }
            if showNext && showNotes { grips.append(Grip(quantity: .notes, rect: CGRect(x: left + gap, y: next, width: right, height: gap), sideways: false)) }
            return Frames(mode: mode, modules: modules, scale: scale, gap: gap, content: content,
                          current: CGRect(x: 0, y: 0, width: left, height: current),
                          next: showNext ? CGRect(x: left + gap, y: 0, width: right, height: next) : .zero,
                          timer: showTimer ? CGRect(x: 0, y: current + gap, width: left, height: max(0, H - gap - current)) : .zero,
                          notes: showNotes ? CGRect(x: left + gap, y: next + nextGap, width: right, height: max(0, H - nextGap - next)) : .zero,
                          grips: grips)
        case .notes:
            // NOTES mode is the notes: the module cannot be off here (the panel disables it).
            let row = (H * CGFloat(clampRowFraction(rowFraction))).rounded()
            let n: CGFloat = showNext ? 2 : 1
            let thumb: CGFloat
            if !showTimer {
                // No timer: the thumbnails share the row's width; the pictures letterbox inside.
                thumb = ((W - (n - 1) * gap) / n).rounded()
            } else if let t = timerFraction {
                // The timer's share of the row; the thumbnails share the rest and letterbox inside.
                let timerW = (W * CGFloat(clampTimerWidthFraction(t))).rounded()
                thumb = max(0, ((W - timerW - n * gap) / n).rounded())
            } else {
                // AUTO: the thumbnails as wide as the row's height makes them; a very wide slide gives way so the timer keeps its digits.
                let minTimer = 300 * scale
                thumb = min(((max(0, row - c)) * a + 2 * p).rounded(), max(0, ((W - n * gap - minTimer) / n).rounded()))
            }
            let timerX = n * (thumb + gap)
            var grips: [Grip] = [Grip(quantity: .row, rect: CGRect(x: 0, y: row, width: W, height: gap), sideways: false)]
            if showTimer { grips.append(Grip(quantity: .timer, rect: CGRect(x: timerX - gap, y: 0, width: gap, height: row), sideways: true)) }
            return Frames(mode: mode, modules: modules.union(.notes), scale: scale, gap: gap, content: content,
                          current: CGRect(x: 0, y: 0, width: thumb, height: row),
                          next: showNext ? CGRect(x: thumb + gap, y: 0, width: showTimer ? thumb : max(0, W - thumb - gap), height: row) : .zero,
                          timer: showTimer ? CGRect(x: timerX, y: 0, width: max(0, W - timerX), height: row) : .zero,
                          notes: CGRect(x: 0, y: row + gap, width: W, height: max(0, H - gap - row)),
                          grips: grips)
        }
    }

    /// Sizes the notes are tried at, largest first: a presenter cannot scroll
    /// a stage monitor, so text that overflows at the chosen size shrinks to
    /// fit, down to 55 % of it, before it scrolls.
    static func notesFitSizes(chosen: Double) -> [Double] {
        [1.0, 0.88, 0.77, 0.66, 0.55].map { max(14, (chosen * $0).rounded()) }   // 14 pt: the floor of readable on a stage monitor
    }
}

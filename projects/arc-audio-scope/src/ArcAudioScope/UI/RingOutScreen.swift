//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import ScopeKit
import SwiftUI

/// The window: header, then the layout the show is set to.
struct RootScreen: View {
    @EnvironmentObject private var model: MeterModel

    var body: some View {
        VStack(spacing: ARCTheme.paddingSmall) {
            ScopeHeader()
            switch model.show.scope.layout {
            case .ringOut: RingOutScreen()
            case .align: AlignScreen()
            case .spl: SPLScreen()
            }
        }
        .padding(ARCTheme.paddingSmall)
        // Anything too tall for the window is cut at the bottom. The header never leaves the top.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(ARCTheme.background)
        .overlay { if model.showPanelOpen { ShowPanel() } }
        .coordinateSpace(name: "root")
    }
}

/// Title, layout switch, the level and the mic input's health, and the interface status.
struct ScopeHeader: View {
    @EnvironmentObject private var model: MeterModel

    var body: some View {
        let mic = model.snapshot.inputs[min(model.micChannel, model.snapshot.inputs.count - 1)]
        let dead = model.mode == .none || mic.state == .dead
        HStack(spacing: ARCTheme.paddingMedium) {
            Text("ARC AUDIO SCOPE").font(ARCTheme.headerBar).foregroundStyle(ARCTheme.text0).fixedSize()
            ARCBank(ScopeSettings.Layout.allCases.map { l in
                ARCBankItem(l.rawValue, on: model.show.scope.layout == l) { model.updateScope { $0.layout = l } }
            })
            .frame(width: 290)
            Text(model.mode.rawValue)
                .font(ARCTheme.statusBadge)
                .foregroundStyle(ARCTheme.ink)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(model.mode == .none ? ARCTheme.text2 : ARCTheme.secBlue, in: RoundedRectangle(cornerRadius: 3))
            if model.generatorOn {
                Text("GENERATOR ON")
                    .font(ARCTheme.statusBadge).foregroundStyle(ARCTheme.ink)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(ARCTheme.warn, in: RoundedRectangle(cornerRadius: 3))
            }
            if model.referenceClipped {
                Text("REF CLIPPED")
                    .font(ARCTheme.statusBadge).foregroundStyle(ARCTheme.text0)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(ARCTheme.arcRed, in: RoundedRectangle(cornerRadius: 3))
            }
            if model.distortionSuspected {
                Text("DISTORTION?")
                    .font(ARCTheme.statusBadge).foregroundStyle(ARCTheme.ink)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(ARCTheme.warn, in: RoundedRectangle(cornerRadius: 3))
            }
            if model.show.scope.layout != .spl {
                Text(dead ? "--.-" : String(format: "%.1f", model.displayLevel))
                    .font(ARCTheme.mono(24)).monospacedDigit()
                    .foregroundStyle(mic.state == .clipping ? ARCTheme.arcRed : ARCTheme.text0)
                Text("\(model.calibration != nil ? "dB SPL" : "dBFS") \(model.weighting.rawValue) \(model.response.rawValue)")
                    .font(ARCTheme.mono(11)).foregroundStyle(ARCTheme.text1)
                Text(dead ? "MIC DEAD" : mic.state == .clipping ? "MIC CLIP" : String(format: "HEADROOM %.0f dB", mic.headroomDB))
                    .font(ARCTheme.mono(11))
                    .foregroundStyle(dead || mic.state == .clipping ? ARCTheme.arcRed : mic.headroomDB < 6 ? ARCTheme.warn : ARCTheme.text1)
            }
            Spacer()
            ARCBank([ARCBankItem("SHOW", on: model.showPanelOpen) { model.showPanelOpen.toggle() }]).frame(width: 70)
            Text(model.status)
                .font(ARCTheme.caption)
                .foregroundStyle(model.statusIsError ? ARCTheme.arcRed : ARCTheme.text1)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, ARCTheme.paddingMedium)
        .frame(height: 44)
        .background(ARCTheme.surface, in: RoundedRectangle(cornerRadius: ARCTheme.cornerRadius))
    }
}

/// RING OUT: the RTA bars over the waterfall on one frequency axis, the ring time trace between
/// them, and the controls and the ring-out log down the right.
struct RingOutScreen: View {
    @EnvironmentObject private var model: MeterModel
    @EnvironmentObject private var scope: ScopeModel

    var body: some View {
        HStack(alignment: .top, spacing: ARCTheme.paddingSmall) {
            GeometryReader { geo in
                VStack(spacing: 0) {
                    SpectrumPlot().frame(height: (geo.size.height - RingTimeStrip.height) * 0.42)
                    RingTimeStrip().frame(height: RingTimeStrip.height)
                    WaterfallPanel()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: ARCTheme.cornerRadius))
            .overlay(alignment: .bottom) {
                if model.testSignal {
                    Text("TEST SIGNAL, NOT THE MICROPHONE")
                        .font(ARCTheme.mono(12)).foregroundStyle(ARCTheme.ink)
                        .padding(.horizontal, 10).padding(.vertical, 3)
                        .background(ARCTheme.warn, in: RoundedRectangle(cornerRadius: 3))
                        .padding(.bottom, 6)
                }
            }
            VStack(spacing: ARCTheme.paddingSmall) {
                ViewControls()
                // SETUP lays the once-a-show settings over the ring panels until it is closed.
                // A panel in the page, not a system popover: that one would not open reliably.
                ZStack(alignment: .top) {
                    VStack(spacing: ARCTheme.paddingSmall) {
                        RingControls()
                        RingLog()
                    }
                    if model.setupOpen {
                        VStack(spacing: ARCTheme.paddingSmall) {
                            RTAControls()
                            WaterfallControls()
                            ARCBank([ARCBankItem("CLOSE SETUP") { model.setupOpen = false }])
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(ARCTheme.background)
                    }
                }
            }
            .frame(width: 330)
        }
        // Keys, hidden so they work wherever the pointer is. Spacebar: "I hear a ring".
        .background {
            let span = model.show.scope.spanSeconds
            Group {
                Button("Mark ring") { model.markRing() }.keyboardShortcut(.space, modifiers: [])
                Button("Freeze") { scope.setFrozen(!scope.isFrozen) }.keyboardShortcut("f", modifiers: [])
                Button("Live") { scope.setFrozen(false) }.keyboardShortcut("l", modifiers: [])
                Button("Older") { scope.setFrozen(true); scope.scrub(to: scope.scrubSeconds + 1, span: span) }.keyboardShortcut(.leftArrow, modifiers: [])
                Button("Newer") { scope.setFrozen(true); scope.scrub(to: scope.scrubSeconds - 1, span: span) }.keyboardShortcut(.rightArrow, modifiers: [])
                Button("Much older") { scope.setFrozen(true); scope.scrub(to: scope.scrubSeconds + 10, span: span) }.keyboardShortcut(.upArrow, modifiers: [])
                Button("Much newer") { scope.setFrozen(true); scope.scrub(to: scope.scrubSeconds - 10, span: span) }.keyboardShortcut(.downArrow, modifiers: [])
            }
            .opacity(0).allowsHitTesting(false).accessibilityHidden(true)
        }
    }
}

/// One line for what a marked sound was doing.
func markVerdict(_ c: RingAnalysis.Candidate) -> (word: String, detail: String, color: Color) {
    if c.faint { return ("FAINT", "Far under the rest of the sound. Probably not what you heard.", ARCTheme.text1) }
    switch c.kind {
    case .growing: return ("GROWING", String(format: "+%.0f dB a second. Feedback building.", c.slopeDBPerSecond), ARCTheme.arcRed)
    case .held: return ("HELD", String(format: "Steady for %.1f s. Feedback at its limit, or a tone.", c.heardSeconds), ARCTheme.arcRed)
    case .dying: return ("DYING", String(format: "%.0f dB a second. A ring after a hit.", c.slopeDBPerSecond), ARCTheme.warn)
    case .note: return ("NOTE", "Has harmonics. A played or sung note.", ARCTheme.text1)
    }
}

func row<V: View>(_ label: String, @ViewBuilder _ content: () -> V) -> some View {
    HStack(spacing: 8) {
        Text(label).font(ARCTheme.mono(11)).foregroundStyle(ARCTheme.text1).frame(width: 52, alignment: .leading)
        content()
    }
}

private struct RTAControls: View {
    @EnvironmentObject private var model: MeterModel

    var body: some View {
        let s = model.show.scope
        VStack(spacing: 6) {
            row("BANDS") {
                ARCBank(BandLayout.fractions.map { f in ARCBankItem("1/\(f)", on: s.fraction == f) { model.updateScope { $0.fraction = f } } })
            }
            row("AVG") {
                ARCBank(SpectrumAveraging.allCases.map { a in ARCBankItem(a.rawValue, on: s.averaging == a) { model.updateScope { $0.averaging = a } } })
            }
            row("WEIGHT") {
                ARCBank(Weighting.allCases.map { w in ARCBankItem(w.rawValue, on: model.weighting == w) { model.set(weighting: w) } })
            }
            row("PEAK") {
                ARCBank([ARCBankItem("HOLD", on: s.peakHold) { model.updateScope { $0.peakHold.toggle() } },
                         ARCBankItem("RESET") { model.resetTraces() }])
            }
            row("DRAW") {
                ARCBank([ARCBankItem("BARS", on: s.style == .bars) { model.updateScope { $0.style = .bars } },
                         ARCBankItem("LINE", on: s.style == .line) { model.updateScope { $0.style = .line } },
                         ARCBankItem("DIFF", on: model.showingDifference, enabled: model.referenceTrace != nil) {
                             model.updateScope { $0.difference.toggle() }
                         }])
            }
        }
        .arcModule(title: "RTA", tint: ARCTheme.secBlue)
    }
}

/// What gets touched during a ring out stays on the page: freeze, peak reset, the traces. The
/// settings chosen once a show (banding, averaging, weighting, span, colours) sit behind SETUP.
private struct ViewControls: View {
    @EnvironmentObject private var model: MeterModel
    @EnvironmentObject private var scope: ScopeModel

    var body: some View {
        let s = model.show.scope
        VStack(spacing: 6) {
            row("VIEW") {
                ARCBank([ARCBankItem(scope.isFrozen ? "FROZEN" : "FREEZE", on: scope.isFrozen) { scope.setFrozen(!scope.isFrozen) },
                         ARCBankItem("SETUP", on: model.setupOpen) { model.setupOpen.toggle() }], tint: ARCTheme.warn)
            }
            row("PEAKS") { ARCBank([ARCBankItem("RESET") { model.resetTraces() }]) }
            row("TRACES") { TraceSlots() }
            Text("1/\(s.fraction)   \(s.averaging.rawValue)   \(model.weighting.rawValue) WEIGHTED   \(Int(s.spanSeconds)) S   \(s.colorMap.rawValue)")
                .font(ARCTheme.mono(11)).foregroundStyle(ARCTheme.text0).lineLimit(1).minimumScaleFactor(0.6)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("KEYS   SPACE mark   F freeze   L live\nSCROLL  LEFT RIGHT 1 s  UP DOWN 10 s")
                .font(ARCTheme.mono(10)).foregroundStyle(ARCTheme.text1).lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .arcModule(title: "VIEW", tint: ARCTheme.secBlue)
    }
}

/// Eight slots. Tap an empty one to capture the bars into it, tap a filled one to show or hide
/// it. Right click or long press: make it the reference for DIFF, or delete it.
private struct TraceSlots: View {
    @EnvironmentObject private var model: MeterModel

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<Trace.limit, id: \.self) { slot in
                let trace = model.show.traces.first { $0.slot == slot }
                let isReference = trace != nil && trace?.id == model.show.scope.referenceTrace
                Text(isReference ? "R\(slot + 1)" : "\(slot + 1)")
                    .font(ARCTheme.mono(12))
                    .foregroundStyle(trace == nil ? ARCTheme.text2 : trace!.visible ? ARCTheme.ink : traceColors[slot])
                    .frame(maxWidth: .infinity, minHeight: 26)
                    .background(trace != nil && trace!.visible ? traceColors[slot] : ARCTheme.moduleBg, in: RoundedRectangle(cornerRadius: 3))
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(trace == nil ? ARCTheme.line : traceColors[slot], lineWidth: 1))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if let trace { model.toggleTrace(trace.id) } else { model.captureTrace(slot: slot) }
                    }
                    .contextMenu {
                        if let trace {
                            Button(isReference ? "Stop using as reference" : "Use as reference for DIFF") { model.setReference(isReference ? nil : trace.id) }
                            Button("Delete trace \(slot + 1)", role: .destructive) { model.deleteTrace(trace.id) }
                        } else {
                            Button("Capture into \(slot + 1)") { model.captureTrace(slot: slot) }
                        }
                    }
            }
        }
    }
}

private struct WaterfallControls: View {
    @EnvironmentObject private var model: MeterModel
    @EnvironmentObject private var scope: ScopeModel

    var body: some View {
        let s = model.show.scope
        let cal = model.calibration?.offsetDB ?? 0
        VStack(spacing: 6) {
            row("SPAN") {
                ARCBank(ScopeSettings.spans.map { t in ARCBankItem("\(Int(t)) S", on: s.spanSeconds == t) { model.updateScope { $0.spanSeconds = t } } })
            }
            row("MAP") {
                ARCBank(ScopeSettings.ColorMap.allCases.map { m in ARCBankItem(m.rawValue, on: s.colorMap == m) { model.updateScope { $0.colorMap = m } } })
            }
            row("RANGE") {
                Text(String(format: "FLOOR %.0f   CEILING %.0f", s.floorDB + cal, s.ceilingDB + cal))
                    .font(ARCTheme.mono(12)).foregroundStyle(ARCTheme.text0)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .arcModule(title: "WATERFALL", tint: ARCTheme.secOrange)
    }
}

private struct RingControls: View {
    @EnvironmentObject private var model: MeterModel
    @EnvironmentObject private var scope: ScopeModel

    var body: some View {
        VStack(spacing: 6) {
            // RINGS leaves out a tail that has harmonics (a played note). ALL flags those too.
            row("DETECT") {
                let s = model.show.scope
                ARCBank([ARCBankItem("OFF", on: !s.ringDetect) { model.updateScope { $0.ringDetect = false } },
                         ARCBankItem("RINGS", on: s.ringDetect && s.harmonicCheck) { model.updateScope { $0.ringDetect = true; $0.harmonicCheck = true } },
                         ARCBankItem("+ NOTES", on: s.ringDetect && !s.harmonicCheck) { model.updateScope { $0.ringDetect = true; $0.harmonicCheck = false } }],
                        tint: ARCTheme.secCrimson)
            }
            row("SOURCE") {
                ARCBank([ARCBankItem("MIC", on: !model.testSignal) { model.setTestSignal(false) },
                         ARCBankItem("TEST SIGNAL", on: model.testSignal) { model.setTestSignal(true) }],
                        tint: model.testSignal ? ARCTheme.warn : ARCTheme.secBlue)
            }
            row("EAR") {
                ARCBank([ARCBankItem(model.marking ? "ANALYSING" : scope.isFrozen ? "ANALYSE THIS MOMENT  (SPACE)" : "MARK  (SPACEBAR)", enabled: !model.marking) { model.markRing() }],
                        tint: ARCTheme.warn)
            }
            if let m = model.lastMark {
                VStack(alignment: .leading, spacing: 2) {
                    if let c = m.candidates.first {
                        let v = markVerdict(c)
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("\(hzText(c.frequency)) Hz").font(ARCTheme.mono(30)).foregroundStyle(ARCTheme.warn)
                            Text("GEQ \(BandLayout.thirdOctaveNames[BandLayout.reference.index(of: c.frequency)])")
                                .font(ARCTheme.mono(16)).foregroundStyle(ARCTheme.text0)
                            Text(v.word).font(ARCTheme.mono(16)).foregroundStyle(v.color)
                        }
                        Text(v.detail).font(ARCTheme.mono(12)).foregroundStyle(ARCTheme.text1)
                        let a = RingAnalysis.advice(c)
                        if a.cut {
                            Text(String(format: "CUT %.0f dB   PEQ \(hzText(a.peqHz)) Hz, narrowest width", a.depthDB))
                                .font(ARCTheme.mono(16)).foregroundStyle(ARCTheme.text0)
                            Text(a.betweenFaders ? "It sits between GEQ faders, so the PEQ is the cleaner cut. Then mark again."
                                                 : "or GEQ \(BandLayout.thirdOctaveNames[a.thirdOctave]) fader. Then mark again to check.")
                                .font(ARCTheme.mono(12)).foregroundStyle(ARCTheme.text1)
                        } else {
                            Text(c.faint ? "NO CUT. Nothing here to hear." : "NO CUT. It is a note, not a ring.").font(ARCTheme.mono(16)).foregroundStyle(ARCTheme.text0)
                        }
                        if let p = m.previous {
                            let cal = model.calibration?.offsetDB ?? 0
                            Text(String(format: "BEFORE %.0f dB \(p.verdict?.rawValue.uppercased() ?? "")   NOW %.0f dB   (%+.0f dB)",
                                        p.levelDB + cal, c.levelDB + cal, c.levelDB - p.levelDB))
                                .font(ARCTheme.mono(12)).foregroundStyle(c.levelDB < p.levelDB - 1 ? ARCTheme.live : ARCTheme.warn)
                        }
                        if m.detectorFlagged == false {
                            Text("The detector had not flagged this one.").font(ARCTheme.mono(10)).foregroundStyle(ARCTheme.text1)
                        }
                        if m.nothingWherePointed {
                            Text("Nothing narrow where you clicked. Strongest line shown.")
                                .font(ARCTheme.mono(10)).foregroundStyle(ARCTheme.warn)
                        }
                        if m.candidates.count > 1 {
                            Text("ALSO  " + m.candidates.dropFirst().map { "\(hzText($0.frequency)) Hz \(markVerdict($0).word)" }.joined(separator: "   "))
                                .font(ARCTheme.mono(10)).foregroundStyle(ARCTheme.text1)
                        }
                    } else {
                        Text(String(format: "No narrow line in the last %.0f seconds.", m.seconds))
                            .font(ARCTheme.mono(12)).foregroundStyle(ARCTheme.text0)
                    }
                }
                .lineLimit(1).minimumScaleFactor(0.5)
                .frame(maxWidth: .infinity, alignment: .leading)
                #if os(macOS)
                // On the iPad the only output is the interface feeding the PA, so no playback there.
                if model.canPlayMark {
                    row("HEAR IT") {
                        ARCBank([ARCBankItem("PLAY THOSE 4 SECONDS") { model.playMark() }])
                    }
                    ARCModuleCaption(m.clip != nil ? "Plays on this Mac's own output, turned up. Saved with the show."
                                                   : "Plays on this Mac's own output, turned up.")
                }
                #endif
            }
        }
        .arcModule(title: "RING DETECT", tint: ARCTheme.secCrimson)
    }
}

/// Every hit at one frequency, as one line: what the tech needs is the fader, not the history.
private struct RingGroup: Identifiable {
    var id: Int
    var frequency: Double
    var geqBand: String
    var count: Int
    var marked: Int
    var worst: String
    var color: Color
    var levelDB: Double
    var last: Date
    var rank: Double

    static func make(_ log: [RingLogEntry]) -> [RingGroup] {
        var groups: [[RingLogEntry]] = []
        for e in log.sorted(by: { $0.band < $1.band }) {
            if let last = groups.last?.last, e.band - last.band <= 1 { groups[groups.count - 1].append(e) } else { groups.append([e]) }
        }
        return groups.map { g in
            let newest = g.max { $0.date < $1.date }!
            let open = g.contains { $0.open }, growing = g.contains { $0.verdict == .growing }
            let held = g.contains { $0.sustained || $0.verdict == .held }
            let excess = g.map(\.excessMs).max() ?? 0
            let worst = open ? "RINGING" : growing ? "GROWING" : held ? "HELD" : excess > 0 ? String(format: "%.0f ms", excess)
                : (newest.verdict?.rawValue.uppercased() ?? "MARKED")
            return RingGroup(id: g[0].band, frequency: newest.frequency, geqBand: newest.geqBand, count: g.count,
                             marked: g.filter(\.marked).count, worst: worst,
                             color: open || growing || held ? ARCTheme.arcRed : g.count >= 3 ? ARCTheme.warn : ARCTheme.text0,
                             levelDB: g.map(\.levelDB).max() ?? 0, last: newest.date,
                             rank: (open ? 1000 : 0) + (growing ? 500 : 0) + (held ? 300 : 0) + Double(g.count) * 10 + min(excess / 100, 9))
        }
        .sorted { $0.rank > $1.rank }
    }
}

private struct RingLog: View {
    @EnvironmentObject private var model: MeterModel
    @AppStorage("ringLogEveryHit") private var everyHit = false
    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        let log = model.visibleRingLog
        let cal = model.calibration?.offsetDB ?? 0
        let groups = RingGroup.make(log)
        VStack(spacing: 4) {
            if everyHit { hits(log, cal) } else { faders(groups, cal) }
            HStack(spacing: 6) {
                ARCBank([ARCBankItem("BY FREQUENCY", on: !everyHit) { everyHit = false },
                         ARCBankItem("EVERY HIT", on: everyHit) { everyHit = true }], tint: ARCTheme.secCrimson)
                ARCBank([ARCBankItem("CLEAR", enabled: !log.isEmpty) { model.clearRingLog() }]).frame(width: 70)
            }
        }
        .frame(maxHeight: .infinity)
        .arcModule(title: model.testSignal ? "RING-OUT LOG (TEST, NOT SAVED)" : "RING-OUT LOG", tint: ARCTheme.secCrimson)
    }

    /// One line per frequency, the one to deal with first at the top.
    @ViewBuilder private func faders(_ groups: [RingGroup], _ cal: Double) -> some View {
        HStack(spacing: 4) {
            Text("HZ").frame(width: 56, alignment: .leading)
            Text("GEQ").frame(width: 44, alignment: .trailing)
            Text("WORST").frame(width: 70, alignment: .trailing)
            Text("DB").frame(width: 34, alignment: .trailing)
            Text("HITS").frame(width: 38, alignment: .trailing)
            Text("LAST").frame(minWidth: 40, maxWidth: .infinity, alignment: .trailing)
        }
        .font(ARCTheme.mono(10)).foregroundStyle(ARCTheme.text1)
        ScrollView {
            LazyVStack(spacing: 3) {
                ForEach(groups) { g in
                    HStack(spacing: 4) {
                        Text(hzText(g.frequency)).font(ARCTheme.mono(17)).frame(width: 56, alignment: .leading).foregroundStyle(g.color)
                        Text(g.geqBand).frame(width: 44, alignment: .trailing).foregroundStyle(ARCTheme.warn)
                        Text(g.worst).frame(width: 70, alignment: .trailing).foregroundStyle(g.color)
                        Text(String(format: "%.0f", g.levelDB + cal)).frame(width: 34, alignment: .trailing)
                        Text("\(g.count)").frame(width: 38, alignment: .trailing)
                            .foregroundStyle(g.count >= 3 ? ARCTheme.arcRed : ARCTheme.text0)
                        Text(Self.clock.string(from: g.last)).frame(minWidth: 40, maxWidth: .infinity, alignment: .trailing)
                            .foregroundStyle(g.marked > 0 ? ARCTheme.warn : ARCTheme.text1)
                    }
                    .font(ARCTheme.mono(13, .regular)).foregroundStyle(ARCTheme.text0).lineLimit(1).minimumScaleFactor(0.7)
                }
            }
        }
        .frame(maxHeight: .infinity)
        ARCModuleCaption(groups.isEmpty ? "No rings flagged." : "\(groups.count) \(groups.count == 1 ? "frequency" : "frequencies"), \(groups.reduce(0) { $0 + $1.count }) \(groups.reduce(0) { $0 + $1.count } == 1 ? "hit" : "hits"). Top = deal with first. Yellow time = marked by hand.")
    }

    @ViewBuilder private func hits(_ log: [RingLogEntry], _ cal: Double) -> some View {
        HStack(spacing: 4) {
            Text("TIME").frame(width: 62, alignment: .leading)
            Text("HZ").frame(width: 52, alignment: .trailing)
            Text("GEQ").frame(width: 46, alignment: .trailing)
            Text("EXCESS").frame(width: 62, alignment: .trailing)
            Text("DB").frame(width: 38, alignment: .trailing)
            Text("X").frame(minWidth: 18, maxWidth: .infinity, alignment: .trailing)
        }
        .font(ARCTheme.mono(10)).foregroundStyle(ARCTheme.text1)
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(log.reversed()) { e in
                    HStack(spacing: 4) {
                        Text(Self.clock.string(from: e.date))
                            .frame(width: 62, alignment: .leading).lineLimit(1).minimumScaleFactor(0.6)
                            .foregroundStyle(e.marked ? ARCTheme.warn : ARCTheme.text0)
                        Text(hzText(e.frequency)).frame(width: 52, alignment: .trailing)
                        Text(e.geqBand).frame(width: 46, alignment: .trailing).foregroundStyle(ARCTheme.warn)
                        Text(e.marked ? (e.verdict?.rawValue.uppercased() ?? "MARKED")
                             : e.open ? "RINGING" : e.sustained ? "HELD" : String(format: "%.0f ms", e.excessMs))
                            .frame(width: 62, alignment: .trailing).lineLimit(1).minimumScaleFactor(0.7)
                            .foregroundStyle(e.marked ? ARCTheme.warn : e.open || e.sustained ? ARCTheme.arcRed : ARCTheme.text0)
                        Text(String(format: "%.0f", e.levelDB + cal)).frame(width: 38, alignment: .trailing)
                        let times = log.filter { abs($0.band - e.band) <= 1 }.count
                        Text("\(times)").frame(minWidth: 18, maxWidth: .infinity, alignment: .trailing)
                            .foregroundStyle(times >= 3 ? ARCTheme.arcRed : ARCTheme.text1)
                    }
                    .font(ARCTheme.mono(12, .regular)).foregroundStyle(ARCTheme.text0)
                }
            }
        }
        .frame(maxHeight: .infinity)
        ARCModuleCaption(log.isEmpty ? "No rings flagged." : "\(log.count) hits, newest first. X = repeats. Yellow = marked by hand.")
    }
}

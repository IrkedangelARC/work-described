//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import AVFoundation
import Foundation
import ScopeKit
import SwiftUI
import Synchronization

/// What the screen draws, replaced whole about 20 times a second.
struct MeterSnapshot: Equatable {
    var level = LevelReading()
    var inputs = [InputStatus(), InputStatus()]
    var dropped = 0
    /// Per input: samples drained since the engine started, and how many of them were not exact zero.
    var received = [0, 0]
    var nonZero = [0, 0]
    /// True when inputs 1 and 2 have carried the very same samples for a second: the interface is
    /// mixing them (AMS-24 mode switch on STREAMING), so there is no separate reference.
    var inputsIdentical = false
    /// Times the reference input was found already clipped upstream, and where its tops were cut.
    var referenceClips = 0
    var referenceCeilingDB = 0.0
}

/// SINGLE = one input (RTA, waterfall, SPL). DUAL = mic + reference (adds transfer function).
enum ScopeMode: String { case none = "NO INPUT", single = "SINGLE", dual = "DUAL" }

/// Drains the rings and runs the detectors. Lives on its own queue; nothing here is touched
/// from the audio thread or the main thread.
private final class MeterProcessor {
    private let rings: [SPSCRing]
    private var meter: SPLMeter
    /// The mic response correction as a filter, ahead of the level meter only (the scope applies
    /// the same curve per band when it draws).
    private var correction: FIRFilter?
    private var corrected = [Float](repeating: 0, count: 16_384)
    func setCorrection(_ taps: [Float]?) { correction = taps.map { FIRFilter(taps: $0) } }
    private var monitors: [InputMonitor]
    private var scratch = [Float](repeating: 0, count: 16_384)
    private var received = [0, 0]
    private var nonZero = [0, 0]
    private var second = [Float](repeating: 0, count: 16_384)
    private var identicalSamples = 0
    private let sampleRate: Double
    var micChannel = 0
    /// The RTA, waterfall and ring detector. Fed the mic input only.
    let scope: ScopeEngine
    /// The transfer function and delay finder (ALIGN). Reference = the generator, or the other input.
    let transfer: TransferEngine
    var referenceIsGenerator = true { didSet { if referenceIsGenerator != oldValue { transfer.restart() } } }
    private let generatorRing: SPSCRing
    /// Clip tier 2, on the input that is not the mic.
    private let flatTop: FlatTopDetector
    private var referenceClips = 0, referenceCeilingDB = 0.0
    private var played = [Float](repeating: 0, count: 16_384)

    init(rings: [SPSCRing], generatorRing: SPSCRing, sampleRate: Double, weighting: Weighting, history: SliceHistory) {
        self.rings = rings
        self.generatorRing = generatorRing
        transfer = TransferEngine(sampleRate: sampleRate)
        self.sampleRate = sampleRate
        scope = ScopeEngine(sampleRate: sampleRate, history: history)
        meter = SPLMeter(sampleRate: sampleRate, weighting: weighting)
        monitors = rings.map { _ in InputMonitor(sampleRate: sampleRate) }
        flatTop = FlatTopDetector(sampleRate: sampleRate)
    }

    func setWeighting(_ w: Weighting) { meter.setWeighting(w) }
    func resetLevels() { meter.reset() }
    func resetInputs() { monitors.forEach { $0.reset() } }

    func tick(channels: Int) -> MeterSnapshot {
        let count = min(channels, rings.count)
        scratch.withUnsafeMutableBufferPointer { a in
            second.withUnsafeMutableBufferPointer { b in
                let bufs = [a.baseAddress!, b.baseAddress!]
                while true {
                    var got = [0, 0]
                    for c in 0..<count {
                        let n = rings[c].read(into: bufs[c], max: a.count)
                        got[c] = n
                        guard n > 0 else { continue }
                        received[c] += n
                        for i in 0..<n where bufs[c][i] != 0 { nonZero[c] += 1 }
                        monitors[c].process(bufs[c], count: n)
                        if c == micChannel {
                            if let correction {
                                corrected.withUnsafeMutableBufferPointer { out in
                                    correction.process(bufs[c], into: out.baseAddress!, count: n)
                                    meter.process(out.baseAddress!, count: n)
                                }
                            } else {
                                meter.process(bufs[c], count: n)
                            }
                            // A clipped block is not ring data: the detector sits it out.
                            scope.process(bufs[c], count: n, blanked: monitors[c].status.blockClipped)
                            transfer.push(measurement: bufs[c], count: n)
                        } else {
                            if let clip = flatTop.process(bufs[c], count: n) {
                                referenceClips += 1
                                referenceCeilingDB = clip.ceilingDBFS
                            }
                            if !referenceIsGenerator { transfer.push(reference: bufs[c], count: n) }
                        }
                    }
                    // Always drained, so the ring never fills while ALIGN is not in use.
                    let g = played.withUnsafeMutableBufferPointer { p -> Int in
                        let g = generatorRing.read(into: p.baseAddress!, max: p.count)
                        if g > 0, referenceIsGenerator { transfer.push(reference: p.baseAddress!, count: g) }
                        return g
                    }
                    transfer.run()
                    // Both rings are filled by the same callback, so equal counts are the same moments.
                    if count == 2, got[0] > 0, got[0] == got[1] {
                        let same = memcmp(bufs[0], bufs[1], got[0] * MemoryLayout<Float>.size) == 0
                        let silent = monitors[0].status.peakDB == -.infinity
                        if same && !silent { identicalSamples += got[0] } else if !same { identicalSamples = 0 }
                    }
                    if got[0] == 0 && got[1] == 0 && g == 0 { break }
                }
            }
        }
        return MeterSnapshot(level: meter.reading, inputs: monitors.map(\.status), dropped: rings.reduce(0) { $0 + $1.dropped },
                             received: received, nonZero: nonZero,
                             inputsIdentical: Double(identicalSamples) >= sampleRate,
                             referenceClips: referenceClips, referenceCeilingDB: referenceCeilingDB)
    }
}

/// The meter's own model. High-rate data stays off any wider app model (karaoke's rule:
/// one ObservableObject per high-rate stream).
/// What MARK found: the lines in the seconds before the key, most likely first.
struct RingMarkResult: Equatable {
    /// When the sound happened (earlier than `made` when marked scrolled back).
    var date: Date
    var made: Date
    var candidates: [RingAnalysis.Candidate]
    var seconds: Double
    var source: String
    /// Whether the detector had flagged the top line too. Nil when nothing was found.
    var detectorFlagged: Bool?
    /// The last hand mark at this frequency, for before and after a cut.
    var previous: RingLogEntry?
    /// The frequency clicked on the waterfall, and whether nothing narrow was found there.
    var pointedAt: Double?
    var nothingWherePointed = false
    /// Where the analysed seconds were saved, if they were.
    var clip: URL?
}

@MainActor
final class MeterModel: ObservableObject {
    @Published private(set) var snapshot = MeterSnapshot()
    @Published private(set) var devices: [AudioInputDevice] = []
    @Published private(set) var mode = ScopeMode.none
    @Published private(set) var status = "STARTING"
    @Published private(set) var statusIsError = false
    @Published private(set) var sampleRate = 48_000.0
    @Published private(set) var show = ShowFile()
    /// TEST SIGNAL: a known scene feeds the scope in place of the microphone. Never saved.
    @Published private(set) var testSignal = false
    /// Rings flagged while the test signal runs. They never enter the show file.
    @Published private(set) var testRingLog: [RingLogEntry] = []
    /// What the last MARK (spacebar) found in the seconds before it.
    @Published private(set) var lastMark: RingMarkResult?
    @Published private(set) var marking = false
    /// The four seconds the last MARK analysed, for playing back.
    private var lastMarkSamples: [Float] = []
    private var lastMarkRate = 48_000.0
    private var markPlayer: AVAudioPlayer?
    /// RTA and waterfall settings pop up (set once a show, so off the page).
    @Published var setupOpen = false

    /// The RING OUT screen's 20 Hz data (its own ObservableObject).
    let scope = ScopeModel()
    /// The ALIGN screen's data.
    let align = AlignModel()
    /// The generator is playing. Never saved: it is off at every launch and every engine start.
    @Published private(set) var generatorOn = false
    /// The show that is open, by name (its file is in ShowLibrary.folder).
    @Published private(set) var showName = ShowLibrary.defaultName
    /// The SHOW panel (shows, notes, export, events) is up.
    @Published var showPanelOpen = false
    /// What the last export wrote, or why it did not.
    @Published private(set) var exportMessage = ""
    /// The transfer function says the system may be distorting (clip tier 3).
    @Published private(set) var distortionSuspected = false
    private var referenceClippedAt: Date?
    /// True for five seconds after the reference input was found clipped upstream (clip tier 2).
    var referenceClipped: Bool { referenceClippedAt.map { Date().timeIntervalSince($0) < 5 } ?? false }
    private var lastReferenceClips = 0
    private var lastDistortionEvent = Date.distantPast
    var generatorAvailable: Bool { engine.generator != nil }

    private let engine = AudioEngine()
    private let queue = DispatchQueue(label: "com.example.arc.ArcAudioScope.dsp", qos: .userInteractive)
    private var processor: MeterProcessor?
    private var timer: DispatchSourceTimer?
    private var lastClipCounts = [0, 0]
    private var started = false
    private var restarting = false
    private var control: ControlServer?
    private var engineGeneration = 0
    /// Ring flag id (per engine run) to its line in the log.
    private var flagEntries: [Int: UUID] = [:]
    private var pendingSave: DispatchWorkItem?

    var showURL: URL { ShowLibrary.url(showName) }

    // MARK: settings (all live in the show file)

    var deviceName: String { show.deviceName }
    var weighting: Weighting { show.weighting }
    var response: TimeResponse { show.response }
    var micChannel: Int { show.micChannel }

    var calibrationKey: String { ShowFile.calibrationKey(device: show.deviceName, channel: show.micChannel) }
    var calibration: Calibration? { show.calibrations[calibrationKey] }

    /// The level on the big readout: dB SPL when calibrated, dBFS when not.
    var displayLevel: Double {
        let dbfs = snapshot.level.level(show.response)
        return calibration?.spl(dbfs) ?? dbfs
    }
    func display(_ dbfs: Double) -> Double { calibration?.spl(dbfs) ?? dbfs }

    // MARK: scope

    private static let layouts = BandLayout.fractions.map { BandLayout(fraction: $0) }
    var fractionIndex: Int { BandLayout.fractions.firstIndex(of: show.scope.fraction) ?? 3 }
    /// The banding the bars and the waterfall are drawn at.
    var scopeLayout: BandLayout { Self.layouts[fractionIndex] }

    private var offsetCache: [String: [Float]] = [:]
    /// Per band dB the chosen weighting adds, at the current banding. The stored slices stay unweighted.
    var bandOffsets: [Float] {
        let key = "\(show.weighting.rawValue)\(show.scope.fraction)"
        if let o = offsetCache[key] { return o }
        let mic = show.micCorrection
        let o = scopeLayout.centers.map { Float(max(WeightingDesign.standardDB(show.weighting, at: $0), -200) + (mic?.correctionDB(at: $0) ?? 0)) }
        offsetCache[key] = o
        return o
    }

    var waterfallDisplay: WaterfallDisplay {
        let s = show.scope
        return WaterfallDisplay(fractionIndex: fractionIndex, floorDB: Float(s.floorDB), ceilingDB: Float(s.ceilingDB),
                                spanSlices: Float(s.spanSeconds / scope.sliceInterval),
                                head: scope.isFrozen ? scope.headSlice : nil, map: s.colorMap, offsets: bandOffsets,
                                axisLo: Float(s.axisLo), axisHi: Float(s.axisHi))
    }

    var visibleRingLog: [RingLogEntry] { testSignal ? testRingLog : show.ringLog }

    /// Change the scope settings. The floor and ceiling are kept apart and on the scale.
    func updateScope(_ change: (inout ScopeSettings) -> Void) {
        var s = show.scope
        change(&s)
        if !BandLayout.fractions.contains(s.fraction) { s.fraction = show.scope.fraction }
        if !ScopeSettings.spans.contains(s.spanSeconds) { s.spanSeconds = show.scope.spanSeconds }
        s.floorDB = min(max(s.floorDB, SpectrumPlot.bottom), SpectrumPlot.top - ScopeSettings.minimumRangeDB)
        s.ceilingDB = min(max(s.ceilingDB, s.floorDB + ScopeSettings.minimumRangeDB), SpectrumPlot.top)
        if !(s.axisLo.isFinite && s.axisHi.isFinite) { s.axisLo = 0; s.axisHi = 1 }
        s.clampAxis()
        guard s != show.scope else { return }
        show.scope = s
        applyScope()
        scope.scrub(to: scope.scrubSeconds, span: s.spanSeconds)
        saveSoon()
    }

    private func applyScope() {
        applyAlign()
        guard let p = processor else { return }
        let s = show.scope, index = fractionIndex, test = testSignal
        queue.async {
            p.scope.fractionIndex = index
            p.scope.averaging = s.averaging
            p.scope.ringDetect = s.ringDetect
            p.scope.harmonicCheck = s.harmonicCheck
            p.scope.testSignal = test
        }
    }

    // MARK: align (transfer function, delay, generator)

    func updateAlign(_ change: (inout AlignSettings) -> Void) {
        var a = show.align
        change(&a)
        if !AlignSettings.averages.contains(a.averagingSeconds) { a.averagingSeconds = show.align.averagingSeconds }
        if !TransferResult.smoothings.contains(a.smoothing) { a.smoothing = show.align.smoothing }
        a.coherenceThreshold = min(max(a.coherenceThreshold, 0), 0.95)
        a.celsius = min(max(a.celsius, -20), 50)
        a.generator.levelDBFS = a.generator.clampedLevel
        a.generator.frequency = min(max(a.generator.frequency, 20), 20_000)
        guard a != show.align else { return }
        let delayChanged = a.delaySamples != show.align.delaySamples
        show.align = a
        applyAlign()
        if delayChanged { let p = processor, d = a.delaySamples; queue.async { p?.transfer.setDelay(d) } }
        saveSoon()
    }

    private func applyAlign() {
        let a = show.align
        engine.generator?.settings = a.generator
        engine.route.mode.store(AlignSettings.Output.allCases.firstIndex(of: a.output) ?? 0, ordering: .relaxed)
        guard let p = processor else { return }
        let on = show.scope.layout == .align
        if !on { align.clear(); distortionSuspected = false }
        queue.async {
            p.referenceIsGenerator = a.reference == .generator
            p.transfer.track = a.track
            p.transfer.averagingSeconds = a.averagingSeconds
            p.transfer.enabled = on
        }
    }

    func setGenerator(_ on: Bool) {
        guard let g = engine.generator else { generatorOn = false; return }
        g.settings = show.align.generator
        g.running = on
        generatorOn = on
    }

    /// Measure the delay afresh and use it.
    func findDelay() { let p = processor; queue.async { p?.transfer.find() } }

    private func receive(_ f: TransferFrame, _ generation: Int) {
        guard generation == engineGeneration, processor != nil, show.scope.layout == .align else { return }
        align.receive(f)
        // The delay finder moved the delay (FIND, or tracking): the show keeps what is in use.
        if f.appliedSamples != show.align.delaySamples { show.align.delaySamples = f.appliedSamples; saveSoon() }
        let suspected = f.distortion?.suspected ?? false
        if suspected, !distortionSuspected, Date().timeIntervalSince(lastDistortionEvent) > 30, let v = f.distortion {
            lastDistortionEvent = Date()
            log(ScopeEvent(kind: .systemDistortion, channel: show.micChannel,
                           detail: String(format: "possible system distortion, coherence %.0f%% with the reference at %.0f dBFS and %.0f%% when quieter",
                                          v.loudCoherence * 100, v.loudLevelDB, v.quietCoherence * 100)))
        }
        distortionSuspected = suspected
    }

    /// The transfer function as the plots draw it: smoothed as the show is set.
    var displayedTransfer: TransferResult { align.frame.result.smoothed(fraction: show.align.smoothing) }

    /// What 0 dB on the magnitude plot stands for: the middle of the live curve, or of the first
    /// captured trace on screen when nothing is being measured.
    func transferZero(_ r: TransferResult) -> Float {
        if r.valid.contains(true) { return Self.magnitudeCentre(r, threshold: show.align.coherenceThreshold) }
        return show.transferTraces.first(where: \.visible)?.zeroDB ?? 0
    }

    /// Capture the transfer function on screen into a slot (the first free one when nil).
    @discardableResult
    func captureTransfer(slot: Int? = nil) -> Bool {
        let r = displayedTransfer
        let threshold = Float(show.align.coherenceThreshold)
        guard r.frequencies.indices.contains(where: { r.valid[$0] && r.coherence[$0] >= threshold }) else { return false }
        let used = Set(show.transferTraces.map(\.slot))
        guard let s = slot ?? (0..<TransferTrace.limit).first(where: { !used.contains($0) }), (0..<TransferTrace.limit).contains(s) else { return false }
        show.transferTraces.removeAll { $0.slot == s }
        show.transferTraces.append(TransferTrace(name: "\(s + 1)", slot: s, result: r, threshold: threshold,
                                                 delaySamples: show.align.delaySamples, zeroDB: transferZero(r)))
        show.transferTraces.sort { $0.slot < $1.slot }
        save()
        return true
    }

    func toggleTransferTrace(_ id: UUID) {
        guard let i = show.transferTraces.firstIndex(where: { $0.id == id }) else { return }
        show.transferTraces[i].visible.toggle()
        save()
    }

    func deleteTransferTrace(_ id: UUID) {
        show.transferTraces.removeAll { $0.id == id }
        save()
    }

    /// 0 dB on the magnitude plot: the middle of the trusted points, so the curve sits on the
    /// zero line whatever the gain between reference and mic.
    static func magnitudeCentre(_ r: TransferResult, threshold: Double) -> Float {
        let trusted = r.magnitudeDB.indices.filter { r.valid[$0] && Double(r.coherence[$0]) >= threshold && r.frequencies[$0] >= 100 && r.frequencies[$0] <= 10_000 }
            .map { r.magnitudeDB[$0] }.sorted()
        return trusted.isEmpty ? 0 : trusted[trusted.count / 2]
    }

    private func alignState() -> [String: Any] {
        let a = show.align, f = align.frame
        var delay: [String: Any] = ["appliedSamples": a.delaySamples, "appliedMs": num(Double(a.delaySamples) / sampleRate * 1000),
                                    "track": a.track, "finding": f.finding, "blocks": f.blocks, "celsius": a.celsius]
        if let e = f.estimate {
            delay["measured"] = ["samples": num(e.samples), "ms": num(e.milliseconds), "metres": num(e.metres(celsius: a.celsius)),
                                 "feet": num(e.metres(celsius: a.celsius) / 0.3048), "peakToNoiseDB": num(e.peakToNoiseDB),
                                 "inverted": e.inverted, "found": e.found] as [String: Any]
        }
        return ["active": show.scope.layout == .align, "reference": a.reference.rawValue, "averagingSeconds": a.averagingSeconds,
                "coherenceThreshold": a.coherenceThreshold, "referenceDBFS": num(f.referenceDB), "measurementDBFS": num(f.measurementDB),
                "delay": delay,
                "generator": ["available": generatorAvailable, "on": generatorOn, "signal": a.generator.signal.rawValue,
                              "levelDBFS": a.generator.levelDBFS, "hz": a.generator.frequency, "output": a.output.rawValue] as [String: Any]]
    }

    private func transferState() -> [String: Any] {
        let r = displayedTransfer, t = show.align.coherenceThreshold
        var out = alignState()
        let centre = transferZero(r)
        out["smoothing"] = "1/\(show.align.smoothing)"
        out["unwrap"] = show.align.unwrap
        out["distortionSuspected"] = distortionSuspected
        if let v = align.frame.distortion {
            out["distortion"] = ["loudCoherence": num(v.loudCoherence), "quietCoherence": num(v.quietCoherence), "loudLevelDBFS": num(v.loudLevelDB)]
        }
        out["traces"] = show.transferTraces.map { ["slot": $0.slot + 1, "visible": $0.visible, "trustedPoints": $0.trusted.filter { $0 }.count,
                                                   "delaySamples": $0.delaySamples] as [String: Any] }
        out["zeroDB"] = num(Double(centre))
        out["centersHz"] = r.frequencies.map { num($0) }
        out["magnitudeDB"] = r.magnitudeDB.indices.map { r.valid[$0] ? num(Double(r.magnitudeDB[$0] - centre)) : NSNull() }
        out["phaseDegrees"] = r.phaseDegrees.indices.map { r.valid[$0] ? num(Double(r.phaseDegrees[$0])) : NSNull() }
        out["coherence"] = r.coherence.indices.map { r.valid[$0] ? num(Double(r.coherence[$0])) : NSNull() }
        out["trustedPoints"] = r.coherence.indices.filter { r.valid[$0] && Double(r.coherence[$0]) >= t }.count
        return out
    }

    // MARK: captured traces

    var referenceTrace: Trace? { show.traces.first { $0.id == show.scope.referenceTrace } }
    /// True when the bars are showing live minus the reference.
    var showingDifference: Bool { show.scope.difference && referenceTrace != nil }

    /// Keep the bars as they are now. `slot` nil = the first free one. False when all eight are used.
    @discardableResult
    func captureTrace(slot: Int? = nil) -> Bool {
        let f = scope.frame
        guard f.thirds.count == 31, f.fine.count == 248, f.slices > 0 else { return false }
        let used = Set(show.traces.map(\.slot))
        guard let s = slot ?? (0..<Trace.limit).first(where: { !used.contains($0) }), (0..<Trace.limit).contains(s), !used.contains(s) else { return false }
        show.traces.append(Trace(name: "T\(s + 1)", slot: s, thirds: f.thirds, fine: f.fine))
        show.traces.sort { $0.slot < $1.slot }
        save()
        return true
    }

    func toggleTrace(_ id: UUID) {
        guard let i = show.traces.firstIndex(where: { $0.id == id }) else { return }
        show.traces[i].visible.toggle()
        save()
    }

    func deleteTrace(_ id: UUID) {
        show.traces.removeAll { $0.id == id }
        if show.scope.referenceTrace == id { show.scope.referenceTrace = nil; show.scope.difference = false }
        save()
    }

    func setReference(_ id: UUID?) {
        show.scope.referenceTrace = show.traces.contains { $0.id == id } ? id : nil
        if show.scope.referenceTrace == nil { show.scope.difference = false }
        save()
    }

    // MARK: mic response correction

    /// Load the measurement mic's response file. Returns what went wrong, or nil.
    @discardableResult
    func loadMicCorrection(from url: URL) -> String? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return "That file could not be read." }
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: Unicode.ASCII.self)
        guard let c = try? MicCorrection.parse(text, name: url.lastPathComponent) else {
            return "No response data in that file. It needs lines of frequency in Hz and level in dB."
        }
        show.micCorrection = c
        applyMicCorrection()
        save()
        return nil
    }

    func clearMicCorrection() {
        show.micCorrection = nil
        applyMicCorrection()
        save()
    }

    private func applyMicCorrection() {
        offsetCache = [:]
        guard let p = processor else { return }
        let mic = show.micCorrection, rate = sampleRate
        queue.async {
            // Designed here, off the main thread: a few thousand taps take a moment.
            p.setCorrection(mic?.fir(sampleRate: rate))
            p.resetLevels()
        }
    }

    func resetTraces() { let p = processor; queue.async { p?.scope.resetTraces() } }

    func setTestSignal(_ on: Bool) {
        guard on != testSignal else { return }
        testSignal = on
        testRingLog = []
        closeOpenRings()
        scope.sourceChanged(test: on)
        applyScope()
        resetTraces()
    }

    func clearRingLog() {
        if testSignal { testRingLog = [] } else { show.ringLog = []; save() }
        flagEntries = [:]
    }

    /// The tech heard a ring and hit the key: go back over four seconds of sound and name what
    /// was in it. Live, the four seconds before the key. Frozen, the four seconds ending at the
    /// top of the waterfall, so a ring heard late can be scrolled back to and analysed.
    /// The best line that is not a note goes in the log and on the waterfall.
    /// `slice` and `focus`: a spot clicked on the frozen waterfall. The four seconds are then
    /// centred on that slice, and a line near that frequency is put first.
    func markRing(atSlice slice: Int? = nil, focus: Double? = nil) {
        guard let p = processor, !marking else { return }
        marking = true
        let half = Int((ScopeEngine.markSeconds / 2 / scope.sliceInterval).rounded())
        let head: Int? = slice.map { $0 + half } ?? (scope.isFrozen ? scope.headSlice : nil)
        let time = slice.map { Double($0) * scope.sliceInterval } ?? (scope.isFrozen ? scope.headTime : scope.frame.time)
        let pressed = Date().addingTimeInterval(time - scope.frame.time), test = testSignal
        queue.async {
            let samples = p.scope.samples(endingAt: head), rate = p.scope.sampleRate
            DispatchQueue.global(qos: .userInitiated).async {
                let report = RingAnalysis.analyze(samples, sampleRate: rate, focus: focus)
                Task { @MainActor in
                    self.lastMarkSamples = samples
                    self.lastMarkRate = rate
                    self.marked(report, pressed, time, test, focus)
                }
            }
        }
    }

    private func marked(_ report: RingAnalysis.Report, _ date: Date, _ time: Double, _ test: Bool, _ focus: Double?) {
        marking = false
        let first = report.candidates.first
        let band = first.map { Self.layouts[3].index(of: $0.frequency) }
        let log = test ? testRingLog : show.ringLog
        // Had the detector caught it too, and was this frequency marked before (the cut's before and after)?
        let flagged = band.map { b in
            scope.openFlags.contains { abs($0.band - b) <= 1 }
                || log.contains { !$0.marked && abs($0.band - b) <= 1 && abs($0.date.timeIntervalSince(date)) < 10 }
        }
        let previous = band.flatMap { b in log.last { $0.marked && abs($0.band - b) <= 1 && $0.date < date } }
        let missed = focus.map { f in !(first.map { abs(log2($0.frequency / f)) <= 1.0 / 6 } ?? false) } ?? false
        lastMark = RingMarkResult(date: date, made: Date(), candidates: report.candidates, seconds: report.seconds,
                                  source: test ? "TEST SIGNAL" : "MIC", detectorFlagged: flagged, previous: previous,
                                  pointedAt: focus, nothingWherePointed: missed)
        scope.markManual(time: time, frequency: first?.frequency)
        // Logged against the source it was heard on, even if the switch moved while it was analysed.
        // A faint line is shown, but it is not a finding: not logged, not saved.
        guard let c = first, let band, test == testSignal, !c.faint else { return }
        var entry = RingLogEntry(marked: c, band: band, thirdOctave: BandLayout.reference.index(of: c.frequency), date: date)
        entry.detectorFlagged = flagged
        if !test { lastMark?.clip = saveMarkClip(c, date) }
        func add(_ log: inout [RingLogEntry]) {
            // A moment scrolled back to goes in where it happened, not at the end.
            let at = log.lastIndex { $0.date <= entry.date }.map { $0 + 1 } ?? 0
            log.insert(entry, at: at)
            if log.count > 500 { log.removeFirst(log.count - 500) }
        }
        if test { add(&testRingLog) } else { add(&show.ringLog); save() }
    }

    /// The analysed seconds, kept beside the show as a 24 bit WAV at the level they were heard.
    private func saveMarkClip(_ c: RingAnalysis.Candidate, _ date: Date) -> URL? {
        guard !lastMarkSamples.isEmpty else { return nil }
        let folder = showURL.appendingPathComponent("Marks")
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd_HHmmss"
        let url = folder.appendingPathComponent("\(stamp.string(from: date))_\(Int(c.frequency.rounded()))Hz_\(c.kind.rawValue).wav")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try WAV.data(lastMarkSamples, sampleRate: lastMarkRate, bits: 24).write(to: url)
            return url
        } catch {
            return nil
        }
    }

    var canPlayMark: Bool { !lastMarkSamples.isEmpty }

    /// Play the analysed seconds on the computer's own output, brought up to a level that can be
    /// heard. Returns false when there is nothing to play or the player would not start.
    @discardableResult func playMark() -> Bool {
        guard !lastMarkSamples.isEmpty else { return false }
        let gain = WAV.normalizingGain(lastMarkSamples)
        markPlayer?.stop()
        markPlayer = try? AVAudioPlayer(data: WAV.data(lastMarkSamples, sampleRate: lastMarkRate, bits: 16, gain: gain))
        return markPlayer?.play() ?? false
    }

    private func ring(_ flag: RingFlag, _ date: Date) {
        func apply(_ log: inout [RingLogEntry]) {
            if let id = flagEntries[flag.id], let i = log.lastIndex(where: { $0.id == id }) {
                log[i].update(flag)
            } else if !flag.final {
                let entry = RingLogEntry(flag, date: date)
                flagEntries[flag.id] = entry.id
                log.append(entry)
                if log.count > 500 { log.removeFirst(log.count - 500) }
            }
            if flag.final { flagEntries[flag.id] = nil }
        }
        if testSignal { apply(&testRingLog) } else { apply(&show.ringLog); save() }
    }

    /// Lines left "ringing" by an engine that has stopped will never be closed by it.
    private func closeOpenRings() {
        flagEntries = [:]
        for i in show.ringLog.indices where show.ringLog[i].open { show.ringLog[i].open = false }
        for i in testRingLog.indices where testRingLog[i].open { testRingLog[i].open = false }
    }

    // MARK: lifecycle

    func begin() {
        guard !started else { return }
        started = true
        showName = ShowLibrary.launchName()
        ShowLibrary.lastName = showName
        if let saved = try? ShowFile.load(from: showURL) { show = saved }
        closeOpenRings()
        scope.onRing = { [weak self] flag, date in self?.ring(flag, date) }
        let server = ControlServer { [weak self] path, query in
            MainActor.assumeIsolated { self?.control(path, query) }
        }
        server.start()
        control = server
        DeviceCatalog.onDevicesChanged { [weak self] in
            Task { @MainActor in self?.devicesChanged() }
        }
        // The engine stops itself when its device is reconfigured (rate change, another app taking it).
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.restarting else { return }
                self.note("engine configuration changed, restarting")
                self.devicesChanged()
                if self.devices.contains(where: { $0.name == self.show.deviceName }) { self.startEngine() }
            }
        }
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            Task { @MainActor in
                if granted {
                    self.devicesChanged()
                } else {
                    self.fail("MICROPHONE ACCESS DENIED. Allow ARC Audio Scope in System Settings, Privacy & Security, Microphone.")
                }
            }
        }
    }

    /// Every change of interface or engine restart, with what caused it (read at /state "deviceLog").
    private var deviceLog: [String] = []
    private func note(_ what: String) {
        deviceLog.append("\(Date().formatted(date: .omitted, time: .standard))  \(what)")
        if deviceLog.count > 40 { deviceLog.removeFirst(deviceLog.count - 40) }
    }

    private func devicesChanged() {
        devices = DeviceCatalog.inputDevices()
        if show.deviceName.isEmpty {
            // First launch only: prefer the AMS-24, then the system default input.
            let pick = devices.first(where: { $0.name.contains("AMS-24") })?.name
                ?? DeviceCatalog.defaultInputName().flatMap { n in devices.first(where: { $0.name == n })?.name }
                ?? devices.first?.name
            guard let pick else { fail("NO INPUT DEVICE"); return }
            show.deviceName = pick
            note("first launch, chose \(pick)")
        }
        // The chosen interface is never swapped for another one behind the operator's back: a
        // measurement through the wrong box is worse than no measurement.
        guard devices.contains(where: { $0.name == show.deviceName }) else {
            if engine.isRunning || !statusIsError { note("\(show.deviceName) left the device list, engine stopped") }
            stopEngine()
            fail("\(show.deviceName) IS NOT CONNECTED. Plug it in or pick another interface.")
            return
        }
        if !engine.isRunning || engine.deviceName != show.deviceName {
            note("device list changed, starting \(show.deviceName)")
            startEngine()
        }
    }

    private func startEngine() {
        restarting = true
        defer { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.restarting = false } }
        stopEngine()
        guard let device = devices.first(where: { $0.name == show.deviceName }) else { fail("NO INPUT DEVICE"); return }
        do {
            try engine.start(device: device)
        } catch {
            fail("\(device.name) did not start. \(error.localizedDescription)")
            return
        }
        sampleRate = engine.sampleRate
        show.sampleRate = engine.sampleRate
        let channels = engine.channelCount
        if show.micChannel >= channels { show.micChannel = 0 }
        mode = channels >= 2 ? .dual : .single
        lastClipCounts = [0, 0]
        lastReferenceClips = 0

        let p = MeterProcessor(rings: engine.rings, generatorRing: engine.generatorRing, sampleRate: engine.sampleRate,
                               weighting: show.weighting, history: scope.history)
        p.micChannel = show.micChannel
        p.transfer.setDelay(show.align.delaySamples)
        generatorOn = false
        processor = p
        engineGeneration += 1
        let generation = engineGeneration
        closeOpenRings()
        scope.engineStarted(sliceInterval: p.scope.sliceInterval, latency: p.scope.latencySeconds)
        applyScope()
        applyMicCorrection()
        var tick = 0
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.025, repeating: 0.025, leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in
            let snap = p.tick(channels: channels)
            tick += 1
            guard tick % 2 == 0 else { return }   // drain at 40 Hz, draw at 20 Hz
            let frame = p.scope.frame()
            let transfer = tick % 4 == 0 && p.transfer.enabled ? p.transfer.frame() : nil
            DispatchQueue.main.async {
                self?.receive(snap, frame, generation)
                if let transfer { self?.receive(transfer, generation) }
            }
        }
        t.resume()
        timer = t
        status = "\(device.name), \(Int(engine.sampleRate)) Hz, \(channels) in"
        statusIsError = false
        save()
    }

    private func stopEngine() {
        timer?.cancel()
        timer = nil
        processor = nil
        engine.stop()
        generatorOn = false
        align.clear()
        mode = .none
        closeOpenRings()
        scope.engineStopped()
    }

    private func fail(_ message: String) {
        status = message
        statusIsError = true
        snapshot = MeterSnapshot()
    }

    private func receive(_ snap: MeterSnapshot, _ frame: ScopeFrame, _ generation: Int) {
        guard generation == engineGeneration, processor != nil else { return }
        scope.receive(frame)
        for c in 0..<min(snap.inputs.count, lastClipCounts.count) where snap.inputs[c].clipEvents > lastClipCounts[c] {
            log(ScopeEvent(kind: .inputClip, channel: c, detail: "input \(c + 1) clipped"))
            if c == show.micChannel, !testSignal { scope.markClip() }
        }
        lastClipCounts = snap.inputs.map(\.clipEvents)
        if snap.referenceClips > lastReferenceClips {
            referenceClippedAt = Date()
            log(ScopeEvent(kind: .referenceClip, channel: show.micChannel == 0 ? 1 : 0,
                           detail: String(format: "reference arrived clipped, tops cut at %.1f dBFS", snap.referenceCeilingDB)))
        }
        lastReferenceClips = snap.referenceClips
        snapshot = snap
    }

    private func log(_ event: ScopeEvent) {
        show.events.append(event)
        if show.events.count > 500 { show.events.removeFirst(show.events.count - 500) }
        save()
    }

    // MARK: shows

    var showNames: [String] { ShowLibrary.names() }

    func setNotes(_ text: String) {
        guard text != show.notes else { return }
        show.notes = text
        saveSoon()
    }

    /// Put another show on the bench. The engine restarts, since the interface may differ.
    private func switchShow(_ next: ShowFile, name: String) {
        save()
        showName = name
        ShowLibrary.lastName = name
        show = next
        flagEntries = [:]
        closeOpenRings()
        exportMessage = ""
        save()
        if devices.contains(where: { $0.name == show.deviceName }) { startEngine() } else { devicesChanged() }
    }

    /// A new show on the same rig. Returns what went wrong, or nil.
    func newShow(named raw: String) -> String? {
        guard let name = ShowLibrary.clean(raw) else { return "Give the show a name." }
        guard !ShowLibrary.exists(name) else { return "There is already a show called \(name)." }
        switchShow(show.fresh(), name: name)
        return nil
    }

    /// This show, logs and traces and all, under another name. The old one stays as it is.
    func saveShowAs(_ raw: String) -> String? {
        guard let name = ShowLibrary.clean(raw) else { return "Give the show a name." }
        guard !ShowLibrary.exists(name) else { return "There is already a show called \(name)." }
        switchShow(show, name: name)
        return nil
    }

    func openShow(_ name: String) -> String? {
        guard name != showName else { return nil }
        save()
        guard let next = try? ShowFile.load(from: ShowLibrary.url(name)) else { return "\(name) could not be opened." }
        switchShow(next, name: name)
        return nil
    }

    // MARK: export

    /// Write the show out for a spreadsheet and a report: the bars and traces, the ring-out log,
    /// the events, the transfer function, the notes and the screen. Returns the folder and files.
    @discardableResult
    func export(reveal: Bool = false) -> (folder: URL, files: [String])? {
        let folder = ShowLibrary.exportFolder(show: showName, date: Date())
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) } catch {
            exportMessage = "Export failed. \(error.localizedDescription)"
            return nil
        }
        var files: [String] = []
        func write(_ name: String, _ data: Data?) {
            guard let data, (try? data.write(to: folder.appendingPathComponent(name), options: .atomic)) != nil else { return }
            files.append(name)
        }
        let cal = calibration?.offsetDB ?? 0, unit = calibration != nil ? "dB SPL" : "dBFS"
        let layout = scopeLayout, offsets = bandOffsets, f = scope.frame
        func drawn(_ v: [Float]) -> [Float] {
            v.count == layout.count ? v.enumerated().map { i, x in x <= BandAverager.floorDB ? -200 : x + offsets[i] + Float(cal) } : []
        }
        var columns: [(name: String, levels: [Float])] = [("live", drawn(f.levels)), ("peak hold", drawn(f.peaks)), ("max", drawn(f.maxes))]
        for t in show.traces { columns.append(("trace \(t.slot + 1)", drawn(t.levels(fraction: show.scope.fraction)))) }
        write("rta 1-\(show.scope.fraction) octave.csv", Export.spectrum(layout: layout, unit: "\(unit) \(show.weighting.rawValue)", columns: columns).data(using: .utf8))
        write("ring out log.csv", Export.ringLog(show.ringLog, offsetDB: cal, unit: unit).data(using: .utf8))
        write("events.csv", Export.events(show.events).data(using: .utf8))
        let r = displayedTransfer
        if r.valid.contains(true) || !show.transferTraces.isEmpty {
            var live = r
            if live.frequencies.isEmpty {
                live.frequencies = BandLayout(fraction: 24).centers
                live.magnitudeDB = [Float](repeating: 0, count: live.frequencies.count)
                live.phaseDegrees = live.magnitudeDB; live.coherence = live.magnitudeDB
                live.valid = [Bool](repeating: false, count: live.frequencies.count)
            }
            write("transfer function.csv", Export.transfer(live, zeroDB: Double(transferZero(r)), threshold: Float(show.align.coherenceThreshold),
                                                           traces: show.transferTraces).data(using: .utf8))
        }
        let c = calibration
        let l = snapshot.level
        var lines = ["Show  \(showName)", "Exported  \(Date().formatted(date: .abbreviated, time: .standard))",
                     "Interface  \(show.deviceName), \(Int(sampleRate)) Hz, mic on input \(show.micChannel + 1)",
                     c.map { String(format: "Calibration  dB SPL = dBFS %+.1f, set %@", $0.offsetDB, $0.date.formatted(date: .abbreviated, time: .shortened)) + ($0.note.isEmpty ? "" : ", gain \($0.note)") }
                        ?? "Calibration  none, levels are dBFS",
                     "Mic file  \(show.micCorrection?.name ?? "none")",
                     String(format: "Level  %@ %@  Leq %.1f  max %.1f  C peak %.1f  over %.0f s", show.weighting.rawValue, unit,
                            display(l.leq), display(l.maxFast), display(l.peakC), l.seconds),
                     "Rings flagged  \(show.ringLog.count)", "Events  \(show.events.count)", "", "Notes", show.notes]
        if show.notes.isEmpty { lines.removeLast(3) }
        write("show.txt", lines.joined(separator: "\n").data(using: .utf8))
        if let png = ScreenCapture.png(scope: scope, display: waterfallDisplay, waterfall: show.scope.layout == .ringOut) {
            write("screen.png", png)
            if ShowLibrary.writePDF(png: png, to: folder.appendingPathComponent("screen.pdf")) { files.append("screen.pdf") }
        }
        exportMessage = "Exported \(files.count) files to \(folder.path)"
        #if os(macOS)
        if reveal { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
        #endif
        return (folder, files)
    }

    private func save() {
        pendingSave?.cancel()
        pendingSave = nil
        try? show.save(to: showURL)
    }

    /// For settings that change many times a second while a handle is dragged.
    private func saveSoon() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    // MARK: operator actions

    func select(device name: String, source: String = "picker") {
        guard name != show.deviceName else { return }
        note("\(source) chose \(name) (was \(show.deviceName))")
        show.deviceName = name
        startEngine()
    }

    func set(weighting w: Weighting) {
        show.weighting = w
        let p = processor
        queue.async { p?.setWeighting(w) }
        save()
    }

    func set(response r: TimeResponse) { show.response = r; save() }

    func set(micChannel c: Int) {
        show.micChannel = c
        let p = processor
        queue.async { p?.micChannel = c; p?.resetLevels() }
        save()
    }

    func resetLevels() { let p = processor; queue.async { p?.resetLevels() } }

    func resetInputs() {
        let p = processor
        queue.async { p?.resetInputs() }
        lastClipCounts = [0, 0]
    }

    /// Make the present Slow level read `targetSPL`. False when the mic input is silent.
    @discardableResult
    func calibrate(to targetSPL: Double, method: Calibration.Method, note: String) -> Bool {
        guard let offset = Calibration.offset(reading: snapshot.level.slow, targetSPL: targetSPL) else { return false }
        show.calibrations[calibrationKey] = Calibration(offsetDB: offset, method: method, note: note)
        save()
        return true
    }

    func clearCalibration() {
        show.calibrations[calibrationKey] = nil
        save()
    }

    // MARK: control API (see ControlServer)

    private func control(_ path: String, _ query: [String: String]) -> ControlServer.Reply? {
        switch path {
        case "/state": return .json(state())
        case "/spectrum": return .json(spectrum())
        case "/rings": return .json(rings())
        case "/reset": resetLevels(); resetInputs(); resetTraces(); return .json(["ok": true])
        case "/clearlog": clearRingLog(); return .json(rings())
        case "/playmark":
            if query["stop"] == "1" { markPlayer?.stop(); return .json(["playing": false]) }
            return .json(["playing": playMark(), "seconds": num(markPlayer?.duration ?? 0)])
        case "/mark":
            // back = seconds before the newest slice, hz = the frequency pointed at (a click on the waterfall).
            let slice = query["back"].flatMap { Double($0) }.map { scope.history.state.total - Int(($0 / scope.sliceInterval).rounded()) }
            markRing(atSlice: slice, focus: query["hz"].flatMap { Double($0) })
            return .json(["ok": processor != nil, "note": "analysing the last 4 seconds, result in /rings lastMark"])
        case "/traces": return .json(tracesState())
        case "/capture":
            let ok = captureTrace(slot: query["slot"].flatMap { Int($0) }.map { $0 - 1 })
            var out = tracesState()
            out["captured"] = ok
            return .json(out)
        case "/trace":
            // /trace?slot=N&visible=0|1  &reference=1  &delete=1
            guard let n = query["slot"].flatMap({ Int($0) }), let t = show.traces.first(where: { $0.slot == n - 1 }) else {
                return .json(["error": "no trace in that slot"])
            }
            if let v = query["visible"], (v == "1") != t.visible { toggleTrace(t.id) }
            if query["reference"] == "1" { setReference(t.id) }
            if query["delete"] == "1" { deleteTrace(t.id) }
            return .json(tracesState())
        case "/miccorrection":
            // /miccorrection?path=<file>  or  ?clear=1
            var problem: String?
            if query["clear"] == "1" { clearMicCorrection() }
            if let path = query["path"] { problem = loadMicCorrection(from: URL(fileURLWithPath: path)) }
            var out: [String: Any] = ["loaded": show.micCorrection?.name ?? NSNull(), "points": show.micCorrection?.frequencies.count ?? 0]
            if let c = show.micCorrection {
                out["correctionDB"] = Dictionary(uniqueKeysWithValues: [20.0, 100, 1000, 10_000, 20_000].map { ("\(Int($0))", num(c.correctionDB(at: $0))) })
            }
            if let problem { out["error"] = problem }
            return .json(out)
        case "/restart": startEngine(); return .json(state())
        case "/tf": return .json(transferState())
        case "/tfcapture":
            let ok = captureTransfer(slot: query["slot"].flatMap { Int($0) }.map { $0 - 1 })
            var out = transferState()
            out["captured"] = ok
            return .json(out)
        case "/tftrace":
            // /tftrace?slot=N&visible=0|1  &delete=1
            guard let n = query["slot"].flatMap({ Int($0) }), let t = show.transferTraces.first(where: { $0.slot == n - 1 }) else {
                return .json(["error": "no transfer trace in that slot"])
            }
            if let v = query["visible"], (v == "1") != t.visible { toggleTransferTrace(t.id) }
            if query["delete"] == "1" { deleteTransferTrace(t.id) }
            return .json(transferState())
        case "/show":
            // /show  or  ?new=NAME | saveas=NAME | open=NAME  &notes=TEXT  &panel=0|1
            var problem: String?
            if let v = query["new"] { problem = newShow(named: v) }
            if let v = query["saveas"] { problem = saveShowAs(v) }
            if let v = query["open"] { problem = ShowLibrary.exists(v) ? openShow(v) : "There is no show called \(v)." }
            if let v = query["notes"] { setNotes(v) }
            if let v = query["panel"] { showPanelOpen = v == "1" }
            var out: [String: Any] = ["show": showName, "shows": showNames, "notes": show.notes, "file": showURL.path,
                                      "ringLogEntries": show.ringLog.count, "events": show.events.count, "traces": show.traces.count,
                                      "transferTraces": show.transferTraces.count]
            if let problem { out["error"] = problem }
            return .json(out)
        case "/export":
            guard let done = export() else { return .json(["error": exportMessage]) }
            return .json(["folder": done.folder.path, "files": done.files])
        case "/events":
            let stamp = ISO8601DateFormatter()
            return .json(["referenceClipped": referenceClipped, "distortionSuspected": distortionSuspected,
                          "events": show.events.suffix(100).map { ["time": stamp.string(from: $0.date), "kind": $0.kind.rawValue, "input": $0.channel + 1, "detail": $0.detail] as [String: Any] }])
        case "/delay":
            // /delay?find=1  or  samples=N | ms=X (sets it and stops tracking)  or  track=0|1
            if let v = query["track"] { updateAlign { $0.track = ["1", "true", "on"].contains(v.lowercased()) } }
            if let n = query["samples"].flatMap({ Int($0) }) ?? query["ms"].flatMap({ Double($0) }).map({ Int(($0 / 1000 * sampleRate).rounded()) }) {
                updateAlign { $0.track = false; $0.delaySamples = min(max(n, -TransferFunction.maxDelaySamples), TransferFunction.maxDelaySamples) }
            }
            if query["find"] == "1" { findDelay() }
            return .json(alignState())
        case "/generator":
            // /generator?on=0|1&signal=PINK|WHITE|SINE|SWEEP&level=<dBFS>&hz=<sine frequency>&out=1|2|both
            updateAlign { a in
                if let v = query["signal"], let s = GeneratorSignal(rawValue: v.uppercased()) { a.generator.signal = s }
                if let v = query["level"].flatMap({ Double($0) }) { a.generator.levelDBFS = v }
                if let v = query["hz"].flatMap({ Double($0) }) { a.generator.frequency = v }
                if let v = query["out"] { a.output = v == "1" ? .one : v == "2" ? .two : .both }
            }
            if let v = query["on"] { setGenerator(["1", "true", "on"].contains(v.lowercased())) }
            return .json(alignState())
        case "/waterfall.png":
            let w = query["w"].flatMap { Int($0) } ?? 1200, h = query["h"].flatMap { Int($0) } ?? 600
            guard let renderer = scope.renderer else { return .json(["error": WaterfallRenderer.failure]) }
            renderer.display = waterfallDisplay
            guard let image = renderer.image(width: min(max(w, 16), 4096), height: min(max(h, 16), 4096)), let png = pngData(image) else {
                return .json(["error": "the waterfall did not render"])
            }
            return .data(png, type: "image/png")
        case "/screen.png":
            // The waterfall is laid in over the capture, so not while the show panel covers it.
            guard let png = ScreenCapture.png(scope: scope, display: waterfallDisplay, waterfall: show.scope.layout == .ringOut && !showPanelOpen) else { return .json(["error": "no window to capture"]) }
            return .data(png, type: "image/png")
        case "/set":
            if let v = query["weighting"], let w = Weighting(rawValue: v.uppercased()) { set(weighting: w) }
            if let v = query["response"], let r = TimeResponse(rawValue: v.uppercased()) { set(response: r) }
            if let v = query["mic"], let c = Int(v), (1...2).contains(c) { set(micChannel: c - 1) }
            if let v = query["device"], devices.contains(where: { $0.name == v }) { select(device: v, source: "api") }
            func flag(_ key: String) -> Bool? { query[key].map { ["1", "true", "on", "yes"].contains($0.lowercased()) } }
            updateScope { s in
                if let v = query["layout"] {
                    let name = v.uppercased().replacingOccurrences(of: " ", with: "")
                    if let l = ScopeSettings.Layout.allCases.first(where: { $0.rawValue.replacingOccurrences(of: " ", with: "") == name }) { s.layout = l }
                }
                if let v = query["bands"].flatMap({ Int($0) }) { s.fraction = v }
                if let v = query["avg"], let a = SpectrumAveraging(rawValue: v.uppercased()) { s.averaging = a }
                if let v = flag("peakhold") { s.peakHold = v }
                if let v = query["floor"].flatMap({ Double($0) }) { s.floorDB = v }
                if let v = query["ceiling"].flatMap({ Double($0) }) { s.ceilingDB = v }
                if let v = query["span"].flatMap({ Double($0) }) { s.spanSeconds = v }
                if let v = query["map"], let m = ScopeSettings.ColorMap(rawValue: v.uppercased()) { s.colorMap = m }
                if let v = flag("ring") { s.ringDetect = v }
                if let v = flag("harmonic") { s.harmonicCheck = v }
                // fmin and fmax in Hz set the part of the axis on screen. zoom=reset shows it all.
                let ref = BandLayout.reference
                if let v = query["fmin"].flatMap({ Double($0) }), v > 0 { s.axisLo = ref.position(of: v) }
                if let v = query["fmax"].flatMap({ Double($0) }), v > 0 { s.axisHi = ref.position(of: v) }
                if query["zoom"] == "reset" { s.axisLo = 0; s.axisHi = 1 }
                // cursor=<Hz> puts the readout cursor there (as a pointer would), cursor=off removes it.
                if let v = query["cursor"] {
                    if let hz = Double(v), hz > 0 {
                        let at = (ref.position(of: hz) - s.axisLo) / max(s.axisHi - s.axisLo, ScopeSettings.minimumAxisSpan)
                        scope.cursor = (0...1).contains(at) ? at : nil
                    } else { scope.cursor = nil }
                }
                if let v = query["style"], let st = ScopeSettings.Style(rawValue: v.uppercased()) { s.style = st }
                if let v = flag("diff") { s.difference = v && s.referenceTrace != nil }
            }
            updateAlign { a in
                if let v = query["ref"] { a.reference = v.uppercased().hasPrefix("IN") ? .input : .generator }
                if let v = query["tfavg"].flatMap({ Double($0) }) { a.averagingSeconds = v }
                if let v = query["coh"].flatMap({ Double($0) }) { a.coherenceThreshold = v > 1 ? v / 100 : v }
                if let v = query["temp"].flatMap({ Double($0) }) { a.celsius = v }
                if let v = query["tfsmooth"].flatMap({ Int($0) }) { a.smoothing = v }
                if let v = flag("unwrap") { a.unwrap = v }
            }
            if let v = flag("test") { setTestSignal(v) }
            if let v = flag("freeze") { scope.setFrozen(v) }
            if let v = query["setup"] { setupOpen = v == "1" }
            if let v = query["scrub"].flatMap({ Double($0) }) { scope.setFrozen(true); scope.scrub(to: v, span: show.scope.spanSeconds) }
            return .json(state())
        default: return nil
        }
    }

    private func num(_ v: Double) -> Any { v.isFinite ? (v * 100).rounded() / 100 : NSNull() }

    /// The bars as drawn: weighting and calibration applied.
    private func spectrum() -> [String: Any] {
        let f = scope.frame, layout = scopeLayout, offsets = bandOffsets
        let cal = calibration?.offsetDB ?? 0
        let ok = f.levels.count == layout.count
        func shown(_ v: [Float]) -> [Any] {
            v.count == layout.count ? v.enumerated().map { i, x in x <= BandAverager.floorDB ? NSNull() : num(Double(x + offsets[i]) + cal) } : []
        }
        var loudest: [String: Any] = [:]
        if ok, let i = f.levels.indices.max(by: { f.levels[$0] + offsets[$0] < f.levels[$1] + offsets[$1] }) {
            loudest = ["hz": num(layout.centers[i]), "level": num(Double(f.levels[i] + offsets[i]) + cal),
                       "geqBand": BandLayout.thirdOctaveNames[BandLayout.reference.index(of: layout.centers[i])]]
        }
        return ["bands": "1/\(show.scope.fraction)", "bandCount": layout.count, "unit": calibration != nil ? "dB SPL" : "dBFS",
                "weighting": show.weighting.rawValue, "averaging": show.scope.averaging.rawValue, "source": testSignal ? "TEST SIGNAL" : "MIC",
                "slices": f.slices, "seconds": num(f.time), "centersHz": layout.centers.map { num($0) },
                "levels": shown(f.levels), "peaks": shown(f.peaks), "max": shown(f.maxes), "loudest": loudest,
                "ringTimeMs24": f.ringTimeMs.map { num(Double($0)) }]
    }

    private func tracesState() -> [String: Any] {
        let cal = calibration?.offsetDB ?? 0, offsets = bandOffsets, fraction = show.scope.fraction
        return ["style": show.scope.style.rawValue, "difference": showingDifference,
                "reference": referenceTrace.map { $0.slot + 1 } ?? NSNull(),
                "traces": show.traces.map { t in
                    let l = t.levels(fraction: fraction)
                    return ["slot": t.slot + 1, "name": t.name, "visible": t.visible,
                            "levels": l.count == offsets.count ? l.enumerated().map { i, x in num(Double(x + offsets[i]) + cal) } : []] as [String: Any]
                }]
    }

    private func rings() -> [String: Any] {
        let cal = calibration?.offsetDB ?? 0
        let log = visibleRingLog
        let stamp = ISO8601DateFormatter()
        var counts: [Int: Int] = [:]
        for e in log { counts[e.thirdOctave, default: 0] += 1 }
        return ["detect": show.scope.ringDetect, "skipNotes": show.scope.harmonicCheck,
                "repeats": counts.filter { $0.value >= 2 }.sorted { $0.value > $1.value }
                    .map { ["geqBand": BandLayout.thirdOctaveNames[min(max($0.key, 0), 30)], "times": $0.value] as [String: Any] },
                "source": testSignal ? "TEST SIGNAL" : "MIC",
                "lastMark": lastMark.map { m in
                    ["time": stamp.string(from: m.date), "detectorFlaggedIt": m.detectorFlagged ?? NSNull() as Any,
                     "nothingWherePointed": m.nothingWherePointed, "clip": m.clip?.path ?? NSNull() as Any,
                     "advice": m.candidates.first.map { c -> Any in
                         let a = RingAnalysis.advice(c)
                         return ["cut": a.cut, "peqHz": num(a.peqHz), "depthDB": a.depthDB,
                                 "geqFader": BandLayout.thirdOctaveNames[a.thirdOctave], "betweenFaders": a.betweenFaders] as [String: Any]
                     } ?? NSNull(),
                     "markedHereBefore": m.previous.map { ["time": stamp.string(from: $0.date), "level": num($0.levelDB + cal),
                                                           "doing": $0.verdict?.rawValue ?? ""] as [String: Any] } ?? NSNull() as Any,
                     "secondsBeforeTheKey": num(m.made.timeIntervalSince(m.date)), "secondsAnalysed": num(m.seconds), "source": m.source,
                     "found": m.candidates.map { c in
                         ["hz": num(c.frequency), "faint": c.faint, "geqBand": BandLayout.thirdOctaveNames[BandLayout.reference.index(of: c.frequency)],
                          "doing": c.kind.rawValue, "dbPerSecond": num(c.slopeDBPerSecond), "level": num(c.levelDB + cal),
                          "aboveSurroundingsDB": num(c.prominenceDB), "heardSeconds": num(c.heardSeconds),
                          "startedSecondsAgo": num(c.startedSecondsAgo)] as [String: Any] }] as [String: Any]
                } ?? NSNull() as Any,
                "ringingNow": scope.openFlags.map { ["hz": num($0.frequency), "geqBand": BandLayout.thirdOctaveNames[min(max($0.thirdOctave, 0), 30)],
                                                     "level": num($0.levelDB + cal)] as [String: Any] },
                "log": log.map { e in
                    ["time": stamp.string(from: e.date), "hz": num(e.frequency), "band24": e.band, "geqBand": e.geqBand,
                     "level": num(e.levelDB + cal), "neighbourMs": num(e.neighbourMs), "tailMs": num(e.tailMs),
                     "decayMsPer20dB": e.decayMs.map { num($0) } ?? NSNull(), "excessMs": num(e.excessMs),
                     "ringing": e.open, "sustained": e.sustained, "markedByHand": e.marked,
                     "doing": e.verdict?.rawValue ?? NSNull(), "dbPerSecond": e.slopeDBPerSecond.map { num($0) } ?? NSNull(),
                     "timesAtThisFrequency": log.filter { abs($0.band - e.band) <= 1 }.count] as [String: Any]
                }]
    }

    private func state() -> [String: Any] {
        let consent = ["notDetermined", "restricted", "denied", "authorized"][AVCaptureDevice.authorizationStatus(for: .audio).rawValue]
        let l = snapshot.level
        let inputs: [[String: Any]] = snapshot.inputs.enumerated().map { c, s in
            ["input": c + 1, "role": c == show.micChannel ? "MIC" : "REF", "state": s.state.rawValue,
             "peakDBFS": num(s.peakDB), "peakHoldDBFS": num(s.peakHoldDB), "maxPeakDBFS": num(s.maxPeakDB),
             "headroomDB": num(s.headroomDB), "clipEvents": s.clipEvents,
             "samplesReceived": snapshot.received[c], "samplesNonZero": snapshot.nonZero[c]]
        }
        return [
            "app": "ARC Audio Scope", "show": showName, "referenceClipped": referenceClipped, "distortionSuspected": distortionSuspected, "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
            "microphoneConsent": consent, "status": status, "statusIsError": statusIsError,
            "mode": mode.rawValue, "engineRunning": engine.isRunning, "sampleRate": sampleRate,
            "device": show.deviceName, "devices": devices.map { ["name": $0.name, "inputs": $0.inputChannels] },
            "weighting": show.weighting.rawValue, "response": show.response.rawValue, "micInput": show.micChannel + 1,
            "calibrated": calibration != nil, "calibrationOffsetDB": calibration.map { num($0.offsetDB) } ?? NSNull(),
            "unit": calibration != nil ? "dB SPL" : "dBFS", "micCorrection": show.micCorrection?.name ?? NSNull(),
            "level": ["display": num(displayLevel), "fast": num(display(l.fast)), "slow": num(display(l.slow)),
                      "leq": num(display(l.leq)), "maxFast": num(display(l.maxFast)), "peakC": num(display(l.peakC)),
                      "seconds": num(l.seconds)],
            "scope": ["layout": show.scope.layout.rawValue, "bands": show.scope.fraction, "averaging": show.scope.averaging.rawValue,
                      "peakHold": show.scope.peakHold, "floorDBFS": show.scope.floorDB, "ceilingDBFS": show.scope.ceilingDB,
                      "style": show.scope.style.rawValue, "difference": showingDifference, "traces": show.traces.count,
                      "spanSeconds": show.scope.spanSeconds, "map": show.scope.colorMap.rawValue, "ringDetect": show.scope.ringDetect,
                      "axisHz": [num(BandLayout.reference.frequency(at: show.scope.axisLo)), num(BandLayout.reference.frequency(at: show.scope.axisHi))],
                      "source": testSignal ? "TEST SIGNAL" : "MIC", "frozen": scope.isFrozen, "scrubSeconds": num(scope.scrubSeconds),
                      "slices": scope.frame.slices, "ringingNow": scope.openFlags.count, "ringLogEntries": visibleRingLog.count],
            "align": alignState(), "deviceLog": deviceLog, "inputs": inputs, "inputsIdentical": snapshot.inputsIdentical, "droppedSamples": snapshot.dropped, "clipLogEntries": show.events.count,
        ]
    }
}

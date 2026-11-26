//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation

/// Level calibration of one input: dB SPL = dBFS RMS + `offsetDB`.
///
/// The offset is only true at the preamp gain it was set at. The AMS-24 gain is an analog
/// knob the app cannot read, so `note` carries the knob position the operator wrote down.
public struct Calibration: Codable, Equatable, Sendable {
    public enum Method: String, Codable, Sendable {
        case calibrator94, calibrator114, matched
    }
    public var offsetDB: Double
    public var method: Method
    public var date: Date
    public var note: String

    public init(offsetDB: Double, method: Method, date: Date = Date(), note: String = "") {
        self.offsetDB = offsetDB; self.method = method; self.date = date; self.note = note
    }

    /// The offset that makes a steady reading of `dbfs` display as `targetSPL`.
    /// Nil when the input is silent: a dead input cannot be calibrated.
    public static func offset(reading dbfs: Double, targetSPL: Double) -> Double? {
        dbfs.isFinite ? targetSPL - dbfs : nil
    }

    public func spl(_ dbfs: Double) -> Double { dbfs + offsetDB }
}

/// One entry of the shared event log (clip now, ring later).
public struct ScopeEvent: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case inputClip, referenceClip, systemDistortion, ring }
    public var date: Date
    public var kind: Kind
    public var channel: Int
    public var detail: String

    public init(date: Date = Date(), kind: Kind, channel: Int, detail: String = "") {
        self.date = date; self.kind = kind; self.channel = channel; self.detail = detail
    }
}

/// How the RING OUT screen is set. Lives in the show file so a show reopens as it was left.
public struct ScopeSettings: Codable, Equatable, Sendable {
    public enum Layout: String, Codable, CaseIterable, Sendable { case ringOut = "RING OUT", align = "ALIGN", spl = "SPL" }
    public enum ColorMap: String, Codable, CaseIterable, Sendable { case smaart = "SMAART", inferno = "INFERNO", grey = "GREY" }
    public static let spans = [5.0, 10, 20, 40]

    public var layout = Layout.ringOut
    /// Bands per octave on the bars and the waterfall: 3, 6, 12 or 24.
    public var fraction = 24
    public var averaging = SpectrumAveraging.fast
    public var peakHold = true
    /// Waterfall floor and ceiling in dBFS (before calibration). Below the floor is black, above the ceiling white.
    public var floorDB = -100.0
    public var ceilingDB = -40.0
    /// Seconds of history the waterfall shows top to bottom.
    public var spanSeconds = 10.0
    public var colorMap = ColorMap.smaart
    public var ringDetect = true
    public enum Style: String, Codable, CaseIterable, Sendable { case bars = "BARS", line = "LINE" }
    public var style = Style.bars
    /// Difference view: the bars show live minus the reference trace.
    public var difference = false
    public var referenceTrace: UUID?
    /// Ring detection leaves out a tail that has harmonics (a played note).
    public var harmonicCheck = true
    /// The part of the frequency axis on screen, as positions along it: 0 = 20 Hz end, 1 = 20 kHz end.
    public var axisLo = 0.0
    public var axisHi = 1.0
    /// Zoom stops at one octave across the screen (the axis is ten octaves).
    public static let minimumAxisSpan = 0.1

    public var zoomed: Bool { axisHi - axisLo < 0.999 }

    /// Keep the window on the axis and no narrower than the limit. The width wins over the position.
    public mutating func clampAxis() {
        let span = min(max(axisHi - axisLo, ScopeSettings.minimumAxisSpan), 1)
        axisLo = min(max(axisLo, 0), 1 - span)
        axisHi = axisLo + span
    }

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        layout = (try? c.decodeIfPresent(Layout.self, forKey: .layout)) ?? layout
        let f = try c.decodeIfPresent(Int.self, forKey: .fraction) ?? fraction
        fraction = BandLayout.fractions.contains(f) ? f : fraction
        averaging = (try? c.decodeIfPresent(SpectrumAveraging.self, forKey: .averaging)) ?? averaging
        peakHold = try c.decodeIfPresent(Bool.self, forKey: .peakHold) ?? peakHold
        floorDB = try c.decodeIfPresent(Double.self, forKey: .floorDB) ?? floorDB
        ceilingDB = try c.decodeIfPresent(Double.self, forKey: .ceilingDB) ?? ceilingDB
        if ceilingDB < floorDB + ScopeSettings.minimumRangeDB { ceilingDB = floorDB + ScopeSettings.minimumRangeDB }
        spanSeconds = try c.decodeIfPresent(Double.self, forKey: .spanSeconds) ?? spanSeconds
        colorMap = (try? c.decodeIfPresent(ColorMap.self, forKey: .colorMap)) ?? colorMap
        ringDetect = try c.decodeIfPresent(Bool.self, forKey: .ringDetect) ?? ringDetect
        style = (try? c.decodeIfPresent(Style.self, forKey: .style)) ?? style
        difference = (try? c.decodeIfPresent(Bool.self, forKey: .difference)) ?? difference
        referenceTrace = try? c.decodeIfPresent(UUID.self, forKey: .referenceTrace)
        harmonicCheck = (try? c.decodeIfPresent(Bool.self, forKey: .harmonicCheck)) ?? harmonicCheck
        axisLo = (try? c.decodeIfPresent(Double.self, forKey: .axisLo)) ?? axisLo
        axisHi = (try? c.decodeIfPresent(Double.self, forKey: .axisHi)) ?? axisHi
        if !(axisLo.isFinite && axisHi.isFinite) { axisLo = 0; axisHi = 1 }
        clampAxis()
    }

    /// The floor and ceiling never close to less than this.
    public static let minimumRangeDB = 6.0
}

/// How the ALIGN screen (transfer function, delay, generator) is set.
public struct AlignSettings: Codable, Equatable, Sendable {
    /// What the mic is compared against: the app's own generator, or the other input (a console feed).
    public enum Reference: String, Codable, CaseIterable, Sendable { case generator = "GENERATOR", input = "INPUT" }
    public enum Output: String, Codable, CaseIterable, Sendable { case both = "1+2", one = "OUT 1", two = "OUT 2" }
    /// Averaging choices in seconds. 0 = everything since the last reset.
    public static let averages = [1.0, 2, 4, 8, 0]

    public var reference = Reference.generator
    public var averagingSeconds = 2.0
    /// Follow the delay as it is measured, or hold the one set.
    public var track = true
    /// Reference delay in samples (measurement behind reference).
    public var delaySamples = 0
    /// Points below this coherence are not drawn.
    public var coherenceThreshold = 0.3
    /// Air temperature for the distance readout.
    public var celsius = 20.0
    public var generator = GeneratorSettings()
    public var output = Output.both
    /// The plots average each point over 1/`smoothing` octave. 24 = as measured.
    public var smoothing = 24
    /// Phase drawn with its wraps taken out.
    public var unwrap = false

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        reference = (try? c.decodeIfPresent(Reference.self, forKey: .reference)) ?? reference
        let a = (try? c.decodeIfPresent(Double.self, forKey: .averagingSeconds)) ?? averagingSeconds
        averagingSeconds = AlignSettings.averages.contains(a) ? a : averagingSeconds
        track = (try? c.decodeIfPresent(Bool.self, forKey: .track)) ?? track
        delaySamples = (try? c.decodeIfPresent(Int.self, forKey: .delaySamples)) ?? delaySamples
        coherenceThreshold = min(max((try? c.decodeIfPresent(Double.self, forKey: .coherenceThreshold)) ?? coherenceThreshold, 0), 0.95)
        celsius = (try? c.decodeIfPresent(Double.self, forKey: .celsius)) ?? celsius
        generator = (try? c.decodeIfPresent(GeneratorSettings.self, forKey: .generator)) ?? generator
        output = (try? c.decodeIfPresent(Output.self, forKey: .output)) ?? output
        let s = (try? c.decodeIfPresent(Int.self, forKey: .smoothing)) ?? smoothing
        smoothing = TransferResult.smoothings.contains(s) ? s : smoothing
        unwrap = (try? c.decodeIfPresent(Bool.self, forKey: .unwrap)) ?? unwrap
    }
}

/// One line of the RING-OUT LOG.
public struct RingLogEntry: Codable, Equatable, Sendable, Identifiable {
    public var id = UUID()
    public var date: Date
    public var frequency: Double
    /// 1/24 octave band index, and the 1/3 octave (GEQ) band it sits in.
    public var band: Int
    public var thirdOctave: Int
    /// dBFS when flagged (calibration is applied when shown).
    public var levelDB: Double
    public var neighbourMs: Double
    public var tailMs: Double
    public var decayMs: Double?
    public var excessMs: Double
    /// Still ringing when last written.
    public var open: Bool
    /// Set when the tech marked it by hand (spacebar or MARK) and the last seconds of sound were
    /// analysed to name it. Optional so older show files still open.
    public var manual: Bool?
    /// What the marked line was doing: growing, held, dying or note.
    public var verdict: RingAnalysis.Kind?
    public var slopeDBPerSecond: Double?
    /// For a hand mark: whether the detector had flagged the same frequency around then.
    public var detectorFlagged: Bool?
    public var marked: Bool { manual ?? false }

    /// A ring the tech heard and marked. `band` is the 1/24 octave band, `thirdOctave` the GEQ band.
    public init(marked c: RingAnalysis.Candidate, band: Int, thirdOctave: Int, date: Date) {
        self.date = date
        frequency = c.frequency; self.band = band; self.thirdOctave = thirdOctave
        levelDB = c.levelDB; neighbourMs = 0; tailMs = c.heardSeconds * 1000
        decayMs = c.kind == .dying && c.slopeDBPerSecond < 0 ? 20_000 / -c.slopeDBPerSecond : nil
        excessMs = 0; open = false
        manual = true; verdict = c.kind; slopeDBPerSecond = c.slopeDBPerSecond
    }

    public init(_ flag: RingFlag, date: Date) {
        self.date = date
        frequency = flag.frequency; band = flag.band; thirdOctave = flag.thirdOctave
        levelDB = flag.levelDB; neighbourMs = flag.neighbourMs; tailMs = flag.tailMs
        decayMs = flag.decayMs; excessMs = flag.excessMs; open = !flag.final
    }

    public mutating func update(_ flag: RingFlag) {
        tailMs = flag.tailMs; decayMs = flag.decayMs; excessMs = flag.excessMs; open = !flag.final
    }

    /// The GEQ fader to reach for.
    public var geqBand: String { BandLayout.thirdOctaveNames[min(max(thirdOctave, 0), 30)] }
    public var sustained: Bool { decayMs == nil }
}

/// The `.arcscope` show file: a folder holding `show.json` (traces and recordings join it in
/// later steps). Unknown keys are ignored and every field has a default, so an older build
/// opens a newer file.
public struct ShowFile: Codable, Equatable, Sendable {
    public static let fileExtension = "arcscope"
    public static let currentVersion = 1

    public var version = ShowFile.currentVersion
    public var created = Date()
    public var notes = ""
    public var deviceName = ""
    public var sampleRate = 48_000.0
    public var micChannel = 0
    public var referenceChannel: Int? = 1
    public var weighting = Weighting.a
    public var response = TimeResponse.fast
    /// Keyed "device name / input N".
    public var calibrations: [String: Calibration] = [:]
    public var events: [ScopeEvent] = []
    public var scope = ScopeSettings()
    public var align = AlignSettings()
    public var ringLog: [RingLogEntry] = []
    public var traces: [Trace] = []
    /// Captured transfer functions (ALIGN).
    public var transferTraces: [TransferTrace] = []
    /// The measurement mic's response file, if one is loaded.
    public var micCorrection: MicCorrection?

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? version
        created = try c.decodeIfPresent(Date.self, forKey: .created) ?? created
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? notes
        deviceName = try c.decodeIfPresent(String.self, forKey: .deviceName) ?? deviceName
        sampleRate = try c.decodeIfPresent(Double.self, forKey: .sampleRate) ?? sampleRate
        micChannel = try c.decodeIfPresent(Int.self, forKey: .micChannel) ?? micChannel
        referenceChannel = try c.decodeIfPresent(Int.self, forKey: .referenceChannel)
        weighting = (try? c.decodeIfPresent(Weighting.self, forKey: .weighting)) ?? weighting
        response = (try? c.decodeIfPresent(TimeResponse.self, forKey: .response)) ?? response
        calibrations = try c.decodeIfPresent([String: Calibration].self, forKey: .calibrations) ?? [:]
        events = try c.decodeIfPresent([ScopeEvent].self, forKey: .events) ?? []
        scope = (try? c.decodeIfPresent(ScopeSettings.self, forKey: .scope)) ?? scope
        align = (try? c.decodeIfPresent(AlignSettings.self, forKey: .align)) ?? align
        ringLog = (try? c.decodeIfPresent([RingLogEntry].self, forKey: .ringLog)) ?? []
        traces = (try? c.decodeIfPresent([Trace].self, forKey: .traces)) ?? []
        transferTraces = (try? c.decodeIfPresent([TransferTrace].self, forKey: .transferTraces)) ?? []
        micCorrection = try? c.decodeIfPresent(MicCorrection.self, forKey: .micCorrection)
    }

    /// A new show on the same rig: the interface, the calibration, the mic file and how the
    /// screens are set carry over. The logs, the captured traces and the notes do not.
    public func fresh() -> ShowFile {
        var s = self
        s.created = Date()
        s.notes = ""
        s.events = []; s.ringLog = []; s.traces = []; s.transferTraces = []
        s.scope.referenceTrace = nil; s.scope.difference = false
        return s
    }

    public static func calibrationKey(device: String, channel: Int) -> String { "\(device) / input \(channel + 1)" }

    public func save(to package: URL) throws {
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(self).write(to: package.appendingPathComponent("show.json"), options: .atomic)
    }

    public static func load(from package: URL) throws -> ShowFile {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try dec.decode(ShowFile.self, from: Data(contentsOf: package.appendingPathComponent("show.json")))
    }
}

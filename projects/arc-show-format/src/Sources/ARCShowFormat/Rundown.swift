//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation

// Moved from ARC Presenter (Engine/Rundown.swift) into the format package 2026-09-19: ARC Capture writes the
// rundown from an agenda deck, Presenter runs it. ONE shape, one file: state/rundown.json.

/// A show's rundown: the cues the stage timer runs, in order, with who is on
/// and for how long (the stage timer inside Presenter, phase 1,
/// `docs/PLAN_stage_timer_merge.md`).
///
/// This is ARC Stage Timer's `Show` and `Cue` brought across as plain Codable
/// values. It lives in the show folder as `state/rundown.json`, so it travels
/// with the show between machines the way the decks do (decision A).
///
/// The file format Stage Timer already exports, "ROS" (run of show) JSON with
/// `event_name` and `sessions[]`, is read and written here too, so a rundown
/// can come in from the old app, from an intake export, or by hand.
public struct Rundown: Codable, Equatable {
    public var version: Int = 1
    public var name: String
    public var arcNumber: String?
    /// yyyy-MM-dd, as the show folder writes dates.
    public var date: String?
    public var venue: String?
    public var notes: String?
    public var cues: [RundownCue] = []

    public init(name: String, arcNumber: String? = nil, date: String? = nil, venue: String? = nil, notes: String? = nil, cues: [RundownCue] = []) {
        self.name = name; self.arcNumber = arcNumber; self.date = date; self.venue = venue; self.notes = notes; self.cues = cues
    }

    public var totalSeconds: Int { cues.reduce(0) { $0 + $1.durationSeconds } }

    /// A rundown someone made to try the app, wearing a real show's name: an
    /// ARC-TEST or 0001 number, or placeholder people. The old timer's
    /// store on the workstation holds one named after a real client meeting,
    /// with three cues and 11 minutes for a two-day meeting (2026-09-18).
    /// Everything around it on show day is real, so it must not look whole.
    ///
    /// Provenance, settled the same evening: the old timer's `tools/review.sh`
    /// builds those shows through `Automation.defaultTestShow`, under any name
    /// it is given. What it always writes is the real tell, and it survives a
    /// renamed show and a plausible ARC number: venue "Mac Studio", the notes
    /// line, the subtitle on cue one, and durations 65, 20, 600, 300, 900, 120
    /// in that order (685 s for three cues).
    public static let reviewDurationPattern = [65, 20, 600, 300, 900, 120]
    public var looksLikeTestData: Bool {
        if let n = arcNumber?.uppercased(), n.contains("TEST") || n == "ARC-" + "0001" { return true }
        if venue?.lowercased() == "mac studio" { return true }
        if let no = notes?.lowercased(), no.contains("automation bridge") || no.contains("style review") { return true }
        if cues.contains(where: { ($0.subtitle ?? "").lowercased().contains("short on purpose") }) { return true }
        if cues.count >= 3, cues.map(\.durationSeconds) == Array(Self.reviewDurationPattern.prefix(cues.count)) { return true }
        let words = cues.flatMap { [$0.title, $0.speakers ?? ""] }.joined(separator: " ").lowercased()
        return words.contains("speaker one") || words.contains("speaker two") || words.contains("test show")
    }

    /// The rundown names a job and the folder is not that job.
    public func belongs(toFolderNamed folder: String) -> Bool {
        guard let n = arcNumber, !n.isEmpty, !n.uppercased().contains("TEST") else { return true }
        let digits = n.filter(\.isNumber)
        return digits.isEmpty || folder.contains(digits)
    }

    /// "1:23:45" or "23:45".
    public static func clock(_ seconds: Int) -> String {
        let s = max(0, seconds)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: - The show folder

    public static let fileName = "rundown.json"
    public static func fileURL(in folder: URL) -> URL { folder.appendingPathComponent("state").appendingPathComponent(fileName) }

    /// nil when the folder has no rundown yet. Throws only on a file that is
    /// there and will not decode: that is worth hearing about, not hiding.
    public static func load(from folder: URL) throws -> Rundown? {
        let url = fileURL(in: folder)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try dec.decode(Rundown.self, from: try Data(contentsOf: url))
    }

    /// Atomic, so a crash mid-write leaves the previous file.
    public func save(to folder: URL) throws {
        let dir = folder.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(self).write(to: Self.fileURL(in: folder), options: .atomic)
    }

    // MARK: - ROS (run of show) JSON, Stage Timer's file format

    /// Stage Timer wrote and read this shape (`ROSDocument` / `ROSSession`,
    /// snake_case with camelCase accepted). `duration_seconds`,
    /// `warning_seconds`, `danger_seconds` and `overtime_allowed` are this
    /// app's additions so a round trip keeps the seconds and thresholds a
    /// minutes-only file cannot; a plain ROS file without them still imports.
    public struct ROS: Codable {
        public var event_name: String?
        public var arc_number: String?
        public var event_date: String?
        public var venue: String?
        public var notes: String?
        public var sessions: [Session]?

        public struct Session: Codable {
            public var time_range: String?
            public var session_title: String?
            public var subtitle: String?
            public var speakers: String?
            public var format: String?
            public var duration_minutes: Int?
            public var duration_seconds: Int?
            public var mic_count: Int?
            public var notes: String?
            public var is_break: Bool?
            public var is_transition: Bool?
            public var warning_seconds: Int?
            public var danger_seconds: Int?
            public var overtime_allowed: Bool?
        }
    }

    public enum ROSError: LocalizedError {
        case noSessions
        public var errorDescription: String? {
            switch self { case .noSessions: "the file has no sessions to make cues from" }
        }
    }

    public static func fromROS(_ data: Data) throws -> Rundown {
        let doc = try JSONDecoder().decode(ROS.self, from: data)   // the keys are spelled snake_case in the struct
        guard let sessions = doc.sessions, !sessions.isEmpty else { throw ROSError.noSessions }
        var r = Rundown(name: doc.event_name ?? "Untitled Show", arcNumber: doc.arc_number, date: doc.event_date, venue: doc.venue, notes: doc.notes)
        r.cues = sessions.map { s in
            let seconds = s.duration_seconds ?? (s.duration_minutes.map { $0 * 60 }) ?? RundownCue.defaultDurationSeconds
            var c = RundownCue(title: s.session_title ?? "Untitled", durationSeconds: seconds)
            c.subtitle = s.subtitle
            c.speakers = s.speakers
            c.timeRange = s.time_range
            c.notes = s.notes
            c.micCount = s.mic_count
            c.format = s.is_break == true ? .breakTime
                     : s.is_transition == true ? .transition
                     : RundownCue.Format(rundownString: s.format)
            if let w = s.warning_seconds { c.warningSeconds = w }
            if let d = s.danger_seconds { c.dangerSeconds = d }
            if let o = s.overtime_allowed { c.overtimeAllowed = o }
            c.clampThresholds()
            return c
        }
        return r
    }

    public func rosData() throws -> Data {
        let sessions = cues.map { c in
            ROS.Session(time_range: c.timeRange, session_title: c.title, subtitle: c.subtitle, speakers: c.speakers,
                        format: c.format.rawValue, duration_minutes: Int((Double(c.durationSeconds) / 60).rounded()),
                        duration_seconds: c.durationSeconds, mic_count: c.micCount, notes: c.notes,
                        is_break: c.format == .breakTime ? true : nil, is_transition: c.format == .transition ? true : nil,
                        warning_seconds: c.warningSeconds, danger_seconds: c.dangerSeconds, overtime_allowed: c.overtimeAllowed)
        }
        let doc = ROS(event_name: name, arc_number: arcNumber, event_date: date, venue: venue, notes: notes, sessions: sessions)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(doc)
    }
}

/// One cue of the rundown: a talk, a panel, a break.
public struct RundownCue: Codable, Equatable, Identifiable {
    /// Stage Timer's `CueFormat`, the same raw values so its files read back.
    public enum Format: String, Codable, CaseIterable {
        case fireside, panel, keynote, lightning, remarks, social, transition
        case breakTime = "break"
        case greenRoom, other

        public var label: String {
            switch self {
            case .fireside: "Fireside"; case .panel: "Panel"; case .keynote: "Keynote"; case .lightning: "Lightning"
            case .remarks: "Remarks"; case .social: "Social"; case .transition: "Transition"; case .breakTime: "Break"
            case .greenRoom: "Green Room"; case .other: "Other"
            }
        }

        /// A ROS file's `format` string, loosely: "Panel Discussion" is a panel.
        public init(rundownString: String?) {
            guard let s = rundownString?.lowercased().trimmingCharacters(in: .whitespaces), !s.isEmpty else { self = .other; return }
            if let exact = Format(rawValue: s) { self = exact; return }
            if s.contains("break") || s.contains("lunch") || s.contains("coffee") { self = .breakTime }
            else if s.contains("panel") { self = .panel }
            else if s.contains("keynote") { self = .keynote }
            else if s.contains("lightning") { self = .lightning }
            else if s.contains("fireside") { self = .fireside }
            else if s.contains("remark") || s.contains("welcome") || s.contains("closing") { self = .remarks }
            else if s.contains("social") || s.contains("reception") || s.contains("networking") { self = .social }
            else if s.contains("transition") || s.contains("changeover") { self = .transition }
            else if s.contains("green") { self = .greenRoom }
            else { self = .other }
        }
    }

    public static let defaultDurationSeconds = 15 * 60
    /// Remaining time at which the stage goes to warning, then danger. Stage
    /// Timer's per-cue thresholds, carried here; phase 2's engine reads them.
    /// Derived from the length so the order holds at every length: a fixed
    /// one-minute danger under a 20 % warning went red before amber on any
    /// talk shorter than five minutes (docs/AGENDA_TEMPLATE.md, Thresholds).
    /// Invariant: 0 < danger < warning < allocated.
    public static func defaultThresholds(for seconds: Int) -> (warning: Int, danger: Int) {
        let warning = max(2, min(seconds / 5, 300))
        let danger = max(1, min(60, warning / 2))
        return (min(warning, max(2, seconds - 1)), danger)
    }

    public var id: UUID = UUID()
    public var title: String
    public var subtitle: String?
    public var format: Format = .other
    public var speakers: String?
    /// "10:00 - 10:30" as an agenda writes it; kept as text, the engine
    /// computes real start times from the run.
    public var timeRange: String?
    public var durationSeconds: Int
    public var warningSeconds: Int = 120
    public var dangerSeconds: Int = 60
    public var overtimeAllowed: Bool = true
    public var micCount: Int?
    public var notes: String?

    public init(title: String, durationSeconds: Int = RundownCue.defaultDurationSeconds) {
        self.title = title
        self.durationSeconds = durationSeconds
        let d = Self.defaultThresholds(for: durationSeconds)
        warningSeconds = d.warning; dangerSeconds = d.danger
        clampThresholds()
    }

    /// Thresholds cannot exceed the cue, meet, or invert: a 90 s transition
    /// with a 120 s warning would be born in warning, and a danger equal to
    /// the warning has no amber at all. 0 < danger < warning < allocated.
    public mutating func clampThresholds() {
        warningSeconds = max(1, min(warningSeconds, max(1, durationSeconds - 1)))
        if dangerSeconds >= warningSeconds { dangerSeconds = max(1, warningSeconds / 2) }
        dangerSeconds = max(1, min(dangerSeconds, warningSeconds - 1 > 0 ? warningSeconds - 1 : 1))
        if durationSeconds <= 2 { warningSeconds = 1; dangerSeconds = 1 }   // nothing to count down
    }

    public var durationClock: String { Rundown.clock(durationSeconds) }
}

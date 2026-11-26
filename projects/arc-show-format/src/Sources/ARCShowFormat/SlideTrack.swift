//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation
import Network

/// The SLIDE TRACK (ARC Slide Log, plan section 3, 2026-10-23): what was on
/// the program output at a show, with timing, without a recording of it, so
/// an edit can put the exact slide back under the camera.
///
/// One folder per session (`reports/slide-track/<show>_<date>_<time>/` in a
/// show folder): `header.json` says who wrote it and how its clocks relate,
/// `track.jsonl` holds one event per line, appended live so a crash loses
/// nothing but the line in flight. Three writers share the format: ARC
/// Presenter (path A, the deck is ours, every change is known), ARC Slide
/// Log on a capture device (path B, we watch the HDMI feed) or on this Mac's
/// display (path C). The importer in arc-talk-edit reads all three alike.
///
/// Times: `t_mono` (seconds since the session started, monotonic) is the
/// authority for intervals; `t_wall` (ISO 8601 with milliseconds and the
/// local offset) anchors the session to the day. A clock change during a
/// show moves `t_wall` and leaves `t_mono` alone.
///
/// Reading is lenient, as everything in this package is: an unknown kind
/// reads as `.other`, unknown keys are ignored, a bad line is skipped and
/// reported, never thrown.
public enum SlideTrack {
    public static let folderName = "slide-track"
    public static let trackFile = "track.jsonl"
    public static let headerFile = "header.json"
    public static let formatVersion = 1

    /// What happened. Path A writes HOLD, MOTION_START, MOTION_END, BLACK,
    /// DECK_OPEN, DECK_CLOSE, TAKE, PROGRAM, OUTPUT and the session pair;
    /// paths B and C add NOSOURCE, SIGNAL_LOST, SIGNAL_BACK; TALK and MARK
    /// come from an operator on any path.
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// The output rests on a still: a slide, a build state, a paused frame.
        case hold = "HOLD"
        /// A clip or an animation started playing (ends with MOTION_END or the next HOLD).
        case motionStart = "MOTION_START"
        case motionEnd = "MOTION_END"
        /// `black` says on or off.
        case black = "BLACK"
        /// The room system's own "no source" screen (B).
        case noSource = "NOSOURCE"
        case signalLost = "SIGNAL_LOST"
        case signalBack = "SIGNAL_BACK"
        /// A talk boundary; `note` carries the presenter or item name.
        case talk = "TALK"
        /// An operator mark; `note` carries the text.
        case mark = "MARK"
        /// A click impulse from the clicker, keyboard or mouse (C): `note` names the key (pagedown, right,
        /// space, mouse-left), `source` is key or mouse, `app` the app in front when it landed.
        case click = "CLICK"
        case deckOpen = "DECK_OPEN"
        case deckClose = "DECK_CLOSE"
        /// Preview became live (A).
        case take = "TAKE"
        /// What feeds the program output changed (A): `program` is deck, powerpoint, window, zoom.
        case program = "PROGRAM"
        /// The program output itself opened or closed (A); `note` names the display.
        case output = "OUTPUT"
        case sessionStart = "SESSION_START"
        case sessionEnd = "SESSION_END"
        /// A kind a newer writer invented: the line is kept, not dropped.
        case other = "OTHER"
        public init(from decoder: Decoder) throws { self = Kind(rawValue: try String(from: decoder)) ?? .other }
    }

    /// Which capture path wrote the session.
    public enum Path: String, Codable, Sendable {
        /// ARC Presenter: the deck is ours.
        case presenter = "A"
        /// A capture device on the program feed.
        case capture = "B"
        /// This Mac's program display under another presentation app.
        case display = "C"
        case other
        public init(from decoder: Decoder) throws { self = Path(rawValue: try String(from: decoder)) ?? .other }
    }

    /// `header.json`: who wrote the session and how its clocks relate.
    public struct Header: Codable, Equatable, Sendable {
        public var format: Int = SlideTrack.formatVersion
        public var app: String
        public var appVersion: String
        public var path: Path
        /// The show's name, when a show folder is open.
        public var show: String?
        /// The session folder's name.
        public var session: String
        public var machine: String
        public var system: String
        /// A: the program display; C: the captured display.
        public var display: String?
        /// B: the capture device.
        public var device: String?
        public var width: Int?
        public var height: Int?
        /// Frames per second analysed (B, C).
        public var rate: Double?
        public var startWall: Date
        /// The monotonic clock's reading at `startWall`, seconds; events count from it.
        public var startMono: Double
        public var timeZone: String
        public var utcOffsetSeconds: Int
        /// Server minus this Mac, milliseconds, when the probe answered.
        public var ntpOffsetMsStart: Double?
        public var ntpOffsetMsEnd: Double?
        /// How the importer is expected to line this up with the cameras: none, scratch-audio, ltc, ntp.
        public var syncMethod: String
        /// Relative path of the scratch audio file, when one was recorded.
        public var scratchAudio: String?
        /// `t_mono` of the scratch audio's first sample, so an offset found against it maps onto the track.
        public var scratchAudioStartMono: Double?
        /// Relative path of the continuous low-resolution proxy of the program output (C: `proxy.mov`): every
        /// frame is stamped with the capture clock, so frame time plus `proxyStartMono` is `t_mono`. With the
        /// deck in hand this is the whole record of what was up and when; the deck supplies the pixels.
        public var proxy: String?
        /// Windows only: the proxy's sound in its own file next to `proxy` (`proxy-audio.m4a`), on the same
        /// timeline (its first sample is at `proxyStartMono`). Absent on the Mac, where `proxy.mov` carries both.
        public var proxyAudio: String?
        public var proxyWidth: Int?
        public var proxyHeight: Int?
        public var proxyRate: Double?
        public var proxyStartMono: Double?
        public var agendaFile: String?
        public var endWall: Date?
        public var endMono: Double?
        /// Events written, set at the end.
        public var events: Int?

        public init(app: String, appVersion: String, path: Path, show: String? = nil, session: String,
                    machine: String = Host.current().localizedName ?? "?",
                    system: String = ProcessInfo.processInfo.operatingSystemVersionString,
                    display: String? = nil, device: String? = nil, width: Int? = nil, height: Int? = nil, rate: Double? = nil,
                    startWall: Date = Date(), startMono: Double = SlideTrack.monotonicSeconds(),
                    timeZone: TimeZone = .current, syncMethod: String = "none", scratchAudio: String? = nil, agendaFile: String? = nil) {
            self.app = app; self.appVersion = appVersion; self.path = path; self.show = show; self.session = session
            self.machine = machine; self.system = system; self.display = display; self.device = device
            self.width = width; self.height = height; self.rate = rate
            self.startWall = startWall; self.startMono = startMono
            self.timeZone = timeZone.identifier; self.utcOffsetSeconds = timeZone.secondsFromGMT(for: startWall)
            self.syncMethod = syncMethod; self.scratchAudio = scratchAudio; self.agendaFile = agendaFile
        }
    }

    /// One line of `track.jsonl`: the state of the output after the change.
    /// Keys are snake_case on disk (`t_wall`, `is_video`, `deck_file`).
    public struct Event: Codable, Equatable, Sendable {
        public var tWall: Date
        /// Seconds since the session started, monotonic.
        public var tMono: Double
        public var kind: Kind
        /// The image the audience saw: A, a still inside the deck (`stills/slide_012_s01.png`,
        /// or `slides.pdf#12` for a page with no build stills); B and C, a file under `stills/`.
        public var still: String?
        /// The clip playing or paused: A, a file inside the deck; B, a file under `clips/`.
        public var clip: String?
        /// Seconds into `clip`.
        public var clipPosition: Double?
        /// A: the deck's id for this run (stable across events, unique per open). C: what the app says it has
        /// open (a file path, a Google presentation id), the same string for the whole talk.
        public var deck: String?
        public var deckFile: String?
        /// Manifest version of the deck.
        public var deckVersion: Int?
        /// `DeckInfo.sourceHash`: the source the deck was captured from.
        public var deckHash: String?
        /// 1-based.
        public var page: Int?
        public var pages: Int?
        /// Clicks consumed on the page / clicks the page answers (A).
        public var segment: Int?
        public var segments: Int?
        /// Build state shown / build states the page has (A, version 3 decks).
        public var build: Int?
        public var builds: Int?
        public var black: Bool?
        public var isVideo: Bool?
        /// Who asked: A key, tap, api, auto; C powerpoint, keynote, preview, googleslides, screen; B capture.
        public var source: String?
        /// C: the bundle id of the app on the program display (com.microsoft.Powerpoint, com.google.Chrome).
        public var app: String?
        /// C: the URL on screen when the app is a browser (a Google Slides present URL carries the slide id).
        public var url: String?
        /// What feeds the output: deck, powerpoint, window, zoom.
        public var program: String?
        /// The detector's change score (B, C), for tuning.
        public var score: Double?
        public var note: String?

        public init(tWall: Date, tMono: Double, kind: Kind) {
            self.tWall = tWall; self.tMono = tMono; self.kind = kind
        }
    }

    // MARK: Clocks

    /// Seconds on a clock that only goes forward and keeps counting through sleep.
    public static func monotonicSeconds() -> Double {
        Double(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000
    }

    /// `<show>_<yyyy-MM-dd>_<HHmmss>`, safe as a folder name.
    public static func sessionName(show: String?, at date: Date = Date(), timeZone: TimeZone = .current) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        let stamp = f.string(from: date)
        guard let show, !show.isEmpty else { return stamp }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let safe = show.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        return String(safe).trimmingCharacters(in: CharacterSet(charactersIn: "-")) + "_" + stamp
    }

    /// Server time minus this Mac's, in milliseconds, by one SNTP exchange; nil
    /// when nothing answered in `timeout` seconds (no network, a firewall). Best
    /// effort: the primary sync is scratch audio, this only sharpens time of day.
    public static func ntpOffsetMs(host: String = "time.apple.com", timeout: TimeInterval = 2) async -> Double? {
        await withCheckedContinuation { (cont: CheckedContinuation<Double?, Never>) in
            let lock = NSLock()
            var done = false
            let queue = DispatchQueue(label: "arc.slidetrack.ntp")
            let conn = NWConnection(host: NWEndpoint.Host(host), port: 123, using: .udp)
            func finish(_ v: Double?) {
                lock.lock(); defer { lock.unlock() }
                guard !done else { return }
                done = true
                conn.cancel()
                cont.resume(returning: v)
            }
            let packet = Data([0x23] + [UInt8](repeating: 0, count: 47))   // LI 0, version 4, mode 3 (client)
            let t1 = Date().timeIntervalSince1970
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    conn.send(content: packet, completion: .contentProcessed { error in
                        if error != nil { finish(nil) }
                    })
                    conn.receiveMessage { data, _, _, _ in
                        let t4 = Date().timeIntervalSince1970
                        guard let data, data.count >= 48 else { finish(nil); return }
                        let b = [UInt8](data)
                        func stamp(_ o: Int) -> Double {
                            let s = b[o..<o + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
                            let f = b[o + 4..<o + 8].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
                            return Double(s) - 2_208_988_800 + Double(f) / 4_294_967_296
                        }
                        let t2 = stamp(32), t3 = stamp(40)
                        guard t2 > 0, t3 > 0 else { finish(nil); return }
                        finish(((t2 - t1) + (t3 - t4)) / 2 * 1000)
                    }
                case .failed, .cancelled:
                    finish(nil)
                default:
                    break
                }
            }
            conn.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { finish(nil) }
        }
    }

    // MARK: Coding

    static let wallFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = .current
        return f
    }()
    private static let wallParser: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let wallParserWhole: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()

    static func parseWall(_ s: String) -> Date? { wallParser.date(from: s) ?? wallParserWhole.date(from: s) }

    /// One event per line: sorted snake_case keys, nil keys omitted, no pretty printing.
    public static func lineEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .custom { date, enc in
            var c = enc.singleValueContainer(); try c.encode(wallFormatter.string(from: date))
        }
        return e
    }
    public static func headerEncoder() -> JSONEncoder {
        let e = lineEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
        return e
    }
    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .custom { dec in
            let c = try dec.singleValueContainer()
            let s = try c.decode(String.self)
            guard let date = parseWall(s) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "not an ISO 8601 date: \(s)")
            }
            return date
        }
        return d
    }

    // MARK: Reading

    public struct Loaded: Sendable {
        public var header: Header?
        public var events: [Event]
        public var warnings: [String]
    }

    /// Read a session folder. Never throws: a missing header is nil, a bad line is a warning.
    public static func read(folder: URL) -> Loaded {
        let dec = decoder()
        var warnings: [String] = []
        var header: Header?
        let headerURL = folder.appendingPathComponent(headerFile)
        if let data = try? Data(contentsOf: headerURL) {
            do { header = try dec.decode(Header.self, from: data) }
            catch { warnings.append("\(headerFile): \(error.localizedDescription)") }
        } else {
            warnings.append("\(headerFile) missing")
        }
        var events: [Event] = []
        if let data = try? Data(contentsOf: folder.appendingPathComponent(trackFile)) {
            let text = String(decoding: data, as: UTF8.self)
            for (i, raw) in text.split(separator: "\n", omittingEmptySubsequences: true).enumerated() {
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty else { continue }
                do { events.append(try dec.decode(Event.self, from: Data(line.utf8))) }
                catch { warnings.append("\(trackFile) line \(i + 1) skipped: \(error.localizedDescription)") }
            }
        } else {
            warnings.append("\(trackFile) missing")
        }
        return Loaded(header: header, events: events, warnings: warnings)
    }
}

/// Writes one session: creates the folder and `header.json`, appends events to
/// `track.jsonl` as they come (its own serial queue, the file handle kept
/// open), keeps a ring of the last lines for a control API, and closes the
/// session with SESSION_END and the header's end fields.
public final class SlideTrackWriter: @unchecked Sendable {
    public let folder: URL
    public private(set) var header: SlideTrack.Header
    public let ringCapacity: Int

    private let queue: DispatchQueue
    private let encoder = SlideTrack.lineEncoder()
    private var handle: FileHandle?
    private var ring: [String] = []
    private var _count = 0
    private var ended = false
    /// Mirror each line (NSLog, a test).
    public var mirror: ((String) -> Void)?

    /// Creates `folder` (and its parents), writes the header, opens the track for
    /// appending (an existing track is continued, never truncated) and logs SESSION_START.
    public init(folder: URL, header: SlideTrack.Header, ringCapacity: Int = 200) throws {
        self.folder = folder
        self.header = header
        self.ringCapacity = ringCapacity
        self.queue = DispatchQueue(label: "arc.slidetrack.\(folder.lastPathComponent)")
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try SlideTrack.headerEncoder().encode(header).write(to: folder.appendingPathComponent(SlideTrack.headerFile), options: .atomic)
        let track = folder.appendingPathComponent(SlideTrack.trackFile)
        if !fm.fileExists(atPath: track.path) { fm.createFile(atPath: track.path, contents: nil) }
        handle = try FileHandle(forWritingTo: track)
        handle?.seekToEndOfFile()
        append(event(.sessionStart))
    }

    public var trackURL: URL { folder.appendingPathComponent(SlideTrack.trackFile) }
    public var headerURL: URL { folder.appendingPathComponent(SlideTrack.headerFile) }
    public var count: Int { queue.sync { _count } }
    public var isEnded: Bool { queue.sync { ended } }

    /// A new event stamped now, on both clocks.
    public func event(_ kind: SlideTrack.Kind) -> SlideTrack.Event {
        SlideTrack.Event(tWall: Date(), tMono: SlideTrack.monotonicSeconds() - header.startMono, kind: kind)
    }

    /// Stamp and write in one: `fill` sets the rest.
    public func record(_ kind: SlideTrack.Kind, _ fill: (inout SlideTrack.Event) -> Void = { _ in }) {
        var e = event(kind)
        fill(&e)
        append(e)
    }

    public func append(_ e: SlideTrack.Event) {
        guard let data = try? encoder.encode(e) else { return }
        let line = String(decoding: data, as: UTF8.self)
        mirror?(line)
        queue.async { [self] in
            guard !ended else { return }
            _count += 1
            ring.append(line)
            if ring.count > ringCapacity { ring.removeFirst(ring.count - ringCapacity) }
            handle?.write(Data((line + "\n").utf8))
        }
    }

    public func tail(_ n: Int) -> [String] { queue.sync { Array(ring.suffix(n)) } }

    /// Update header fields mid-session (the display assigned, a sync method chosen) and rewrite header.json.
    public func updateHeader(_ change: (inout SlideTrack.Header) -> Void) {
        queue.sync {
            change(&header)
            try? SlideTrack.headerEncoder().encode(header).write(to: headerURL, options: .atomic)
        }
    }

    /// SESSION_END, the header's end fields and count, the handle closed. Idempotent.
    public func end(ntpOffsetMs: Double? = nil) {
        append(event(.sessionEnd))
        queue.sync {
            guard !ended else { return }
            ended = true
            header.endWall = Date()
            header.endMono = SlideTrack.monotonicSeconds() - header.startMono
            header.events = _count
            if let ntpOffsetMs { header.ntpOffsetMsEnd = ntpOffsetMs }
            try? SlideTrack.headerEncoder().encode(header).write(to: headerURL, options: .atomic)
            try? handle?.synchronize()
            try? handle?.close()
            handle = nil
        }
    }

    /// Wait for every queued line to reach the file (tests, quit).
    public func flush() { queue.sync { try? handle?.synchronize() } }

    deinit { try? handle?.close() }
}

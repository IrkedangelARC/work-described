//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation

/// `manifest.json` inside an `.arcdeck`, typed. Version 2 (ARC Capture
/// 2026-09-12): one clip per page with a time mark per click. Version 3
/// (2026-09-17, arc-presenter docs/PLAN_per_build_clips.md): a slide's builds
/// are one clip EACH, owned by the slide, with a still of every build state,
/// so the presenter sets the pace and can back up one build. Additive: a
/// version 2 deck reads as before. Unknown keys are ignored on read so a newer writer never breaks an
/// older reader; a broken file yields warnings, never a thrown error, so a
/// deck always loads at least as stills (Presenter's rule since 2.x).
public struct DeckManifest: Codable, Equatable, Sendable {
    public static let currentVersion = 3
    /// What a manifest with no per-build clips declares: it IS a version 2 deck.
    public static let continuousClipVersion = 2

    public enum SlideType: String, Codable, Sendable { case image, video }

    /// One build of a slide: the clip that animates state n-1 into state n,
    /// and the still of state n (what is on screen once it has played).
    ///
    /// `file` is nil for a build that is a CUT: PowerPoint's "Appear", 1 ms, the commonest build there is.
    /// Its recording held no animation (every frame the finished state) and playing it was a video swap and a
    /// third of a second of nothing for what is a cut between two stills (2026-09-17, on a deck of
    /// Appear builds: "these slides have simple builds yet they show 3.8 s of animation? i think this is the
    /// problem"). A reader that finds no clip cuts to `still`.
    public struct Build: Codable, Equatable, Sendable {
        public var file: String?
        public var still: String
        /// Seconds of the clip; nil for a cut.
        public var duration: Double?
        public init(file: String?, still: String, duration: Double? = nil) { self.file = file; self.still = still; self.duration = duration }
    }

    /// A media object on the SOURCE slide, as the capture found it. Presenter
    /// plays the recording either way; this is what the recording is OF
    /// (2026-09-17: "err on the side of capturing more info than less").
    public struct Media: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable {
            case video, audio, animatedImage, other
            /// A kind a newer writer invented reads as `other`: information must never cost a slide.
            public init(from decoder: Decoder) throws { self = Kind(rawValue: try String(from: decoder)) ?? .other }
        }
        public var kind: Kind
        /// File name inside the source (ppt/media/media3.mp4).
        public var name: String
        public var seconds: Double?
        public var width: Int?
        public var height: Int?
        public var videoCodec: String?
        public var audioCodec: String?
        public var hasAudio: Bool?
        /// Frames of an animated image.
        public var frames: Int?
        public var bytes: Int?
        // How the source PLACES it (2026-09-17, for using the movie itself instead of a recording of it).
        /// The movie's frame covers the whole slide.
        public var fillsSlide: Bool?
        /// PowerPoint's trim, seconds into the file; nil = untrimmed.
        public var trimStart: Double?
        public var trimEnd: Double?
        /// 0...1; nil = full.
        public var volume: Double?
        public var muted: Bool?
        /// An ONLINE video the slide links to (YouTube, Vimeo) rather than a file inside the source: `name` is
        /// then the download's file name in the deck, or a label when it was never fetched. Capture fetches it
        /// with ARC Grab and the page plays it locally (2026-09-19); a page carrying such a media entry without
        /// `sourceMovie` is one whose link could not be fetched.
        public var url: String?
        public init(kind: Kind, name: String, seconds: Double? = nil, width: Int? = nil, height: Int? = nil, videoCodec: String? = nil,
                    audioCodec: String? = nil, hasAudio: Bool? = nil, frames: Int? = nil, bytes: Int? = nil,
                    fillsSlide: Bool? = nil, trimStart: Double? = nil, trimEnd: Double? = nil, volume: Double? = nil, muted: Bool? = nil,
                    url: String? = nil) {
            self.kind = kind; self.name = name; self.seconds = seconds; self.width = width; self.height = height
            self.videoCodec = videoCodec; self.audioCodec = audioCodec; self.hasAudio = hasAudio; self.frames = frames; self.bytes = bytes
            self.fillsSlide = fillsSlide; self.trimStart = trimStart; self.trimEnd = trimEnd; self.volume = volume; self.muted = muted
            self.url = url
        }
    }

    /// How the slide's media starts in the source.
    public enum MediaStart: String, Codable, Sendable {
        case onEntry            // with the slide
        case inClickSequence    // the clicker's next click
        case whenClickedOn      // only a click ON the picture (an interactive sequence): a clicker cannot start it
        case unknown
        public init(from decoder: Decoder) throws { self = MediaStart(rawValue: try String(from: decoder)) ?? .unknown }
    }

    /// What the capture measured while it recorded the page.
    public struct Measured: Codable, Equatable, Sendable {
        public var settleMs: Int?
        public var motionFrames: Int?
        public var endedBy: String?
        public var capturedAt: Date?
        public var clipSeconds: Double?
        public init(settleMs: Int? = nil, motionFrames: Int? = nil, endedBy: String? = nil, capturedAt: Date? = nil, clipSeconds: Double? = nil) {
            self.settleMs = settleMs; self.motionFrames = motionFrames; self.endedBy = endedBy; self.capturedAt = capturedAt; self.clipSeconds = clipSeconds
        }
    }

    /// A page that is not a slide of the source.
    public enum Role: String, Codable, Sendable {
        case opening   // the logo page ahead of the deck
        case closing   // the logo page after it (it also gives the last slide's builds a page to be recorded against)
        case between   // in a combined deck, the logo page between two decks
        case other     // a role a newer writer invented: still not a slide of the source
        public init(from decoder: Decoder) throws { self = Role(rawValue: try String(from: decoder)) ?? .other }
    }

    /// The deck as a whole: what it was made from, by what, where and when.
    public struct DeckInfo: Codable, Equatable, Sendable {
        public var sourceName: String?
        public var sourceKind: String?
        public var sourceHash: String?
        public var sourceBytes: Int?
        public var sourceModified: Date?
        public var sourceSlideCount: Int?
        public var sourceHiddenSlides: [Int]?
        public var title: String?
        public var capturedAt: Date?
        public var captureApp: String?
        public var captureVersion: String?
        public var host: String?
        public var system: String?
        public var presentationApp: String?
        public var pixelWidth: Int?
        public var pixelHeight: Int?
        public var captureSeconds: Double?
        /// Does this deck hold the whole source? nil or true for a normal
        /// capture; false when the operator ended the show early and kept
        /// what had been captured (ARC Capture V3, plan 1.5). A false deck is
        /// sound and playable, it is simply short, so Presenter should load it
        /// and say so rather than refuse it.
        public var complete: Bool?
        public var warnings: [String]?
        /// A combined deck: the decks it was made from, in order, with the pages each one occupies.
        public var parts: [Part]?
        public struct Part: Codable, Equatable, Sendable {
            public var name: String
            public var firstPage: Int
            public var lastPage: Int
            public init(name: String, firstPage: Int, lastPage: Int) { self.name = name; self.firstPage = firstPage; self.lastPage = lastPage }
        }
        public init() {}
    }

    public struct Slide: Codable, Equatable, Sendable {
        /// 1-based slide number in slides.pdf.
        public var slide: Int
        public var type: SlideType
        /// Relative path of the clip (video slides).
        public var file: String?
        /// The way INTO the slide as its own clip (entry transition, on-entry movie).
        public var entryFile: String?
        /// Per-click times inside `file`, seconds; Presenter plays one segment per click.
        public var clicks: [Double]?
        /// Which click starts the movie on this slide.
        public var entryClick: Int?
        public var entryClicks: [Double]?
        /// Play again from `loopStart` until the operator advances.
        public var loop: Bool?
        public var loopStart: Double?
        /// Playback died here in the capture: wrap at this time.
        public var stopAt: Double?
        /// The clip is only the transition in.
        public var transition: Bool?
        /// The slide defines a transition although it sits inside this clip.
        public var transitionIn: Bool?
        /// Seconds after the clip and this delay, Presenter leaves the page by itself.
        public var autoAdvance: Double?
        /// PowerPoint's own slide number when it was asked.
        public var pptxSlide: Int?
        /// Show builder: the source file this slide came from, and its page.
        public var source: String?
        public var sourcePage: Int?
        /// Version 3: this slide's builds in click order. State 0 is
        /// `initialStill`, state n is `builds[n-1].still`, the last state is
        /// the page in slides.pdf.
        public var builds: [Build]?
        /// Version 3: the slide as it stands after its entry transition, before any build.
        public var initialStill: String?

        // What the source says and what the capture saw (all optional, none
        // needed to play the deck; kept for the versions of Presenter to come).
        /// nil = a slide of the source. Otherwise a logo page.
        public var role: Role?
        public var title: String?
        /// The source's own media on this slide.
        public var media: [Media]?
        public var mediaStart: MediaStart?
        /// The entry transition as the source names it ("fade", "prism", "prstTrans:curtains") and its declared length.
        public var transitionEffect: String?
        public var transitionSeconds: Double?
        /// Clicks the source's main sequence needs before it leaves the slide.
        public var sourceClicks: Int?
        public var hasNotes: Bool?
        public var measured: Measured?
        /// `file` IS the source's movie (copied out of the pptx), not a recording of PowerPoint playing it:
        /// perfect sync by construction. A recording of an on-entry movie carried its sound 350-590 ms ahead
        /// of its picture, drifting, on every machine measured (2026-09-17). `entryFile` is still recorded.
        public var sourceMovie: Bool?

        public init(slide: Int, type: SlideType, file: String? = nil, entryFile: String? = nil, clicks: [Double]? = nil,
                    entryClick: Int? = nil, entryClicks: [Double]? = nil, loop: Bool? = nil, loopStart: Double? = nil,
                    stopAt: Double? = nil, transition: Bool? = nil, transitionIn: Bool? = nil, autoAdvance: Double? = nil,
                    pptxSlide: Int? = nil, source: String? = nil, sourcePage: Int? = nil,
                    builds: [Build]? = nil, initialStill: String? = nil) {
            self.slide = slide; self.type = type; self.file = file; self.entryFile = entryFile; self.clicks = clicks
            self.entryClick = entryClick; self.entryClicks = entryClicks; self.loop = loop; self.loopStart = loopStart
            self.stopAt = stopAt; self.transition = transition; self.transitionIn = transitionIn; self.autoAdvance = autoAdvance
            self.pptxSlide = pptxSlide; self.source = source; self.sourcePage = sourcePage
            self.builds = builds; self.initialStill = initialStill
        }

        public var isVideo: Bool { type == .video && file != nil }
        /// Media files this slide references, relative to the bundle.
        public var mediaFiles: [String] { [file, entryFile].compactMap { $0 } + (builds ?? []).compactMap(\.file) }
        /// Still images this slide references (version 3 build states).
        public var stillFiles: [String] { [initialStill].compactMap { $0 } + (builds ?? []).map(\.still) }
        public var buildCount: Int { builds?.count ?? 0 }
    }

    public var version: Int
    /// About the deck as a whole.
    public var deck: DeckInfo?
    public var slides: [Slide]

    /// The version is what the content is, not what the writer could have
    /// written: 3 only when a slide carries per-build clips.
    public init(version: Int? = nil, deck: DeckInfo? = nil, slides: [Slide]) {
        self.deck = deck
        self.version = version ?? (slides.contains { !($0.builds ?? []).isEmpty } ? DeckManifest.currentVersion : DeckManifest.continuousClipVersion)
        self.slides = slides
    }

    public var videoSlideCount: Int { slides.filter(\.isVideo).count }
    public func slide(number: Int) -> Slide? { slides.first { $0.slide == number } }

    // MARK: Read, leniently

    public struct Loaded: Sendable {
        public var manifest: DeckManifest?
        public var warnings: [String]
        public var version: Int { manifest?.version ?? 1 }
    }

    /// Never throws. A missing file is version 1 with no slides (a stills-only
    /// deck); a corrupt file or a bad entry is reported and skipped.
    public static func load(from url: URL) -> Loaded {
        guard let data = try? Data(contentsOf: url) else { return Loaded(manifest: nil, warnings: []) }
        return decode(data, name: url.lastPathComponent)
    }

    public static func decode(_ data: Data, name: String = "manifest.json") -> Loaded {
        var warnings: [String] = []
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return Loaded(manifest: nil, warnings: ["\(name) is not a JSON object; deck loads as stills"])
        }
        let version = (raw["version"] as? Int) ?? 1
        var slides: [Slide] = []
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        for (i, entry) in ((raw["slides"] as? [Any]) ?? []).enumerated() {
            guard let dict = entry as? [String: Any], let entryData = try? JSONSerialization.data(withJSONObject: dict) else {
                warnings.append("slides[\(i)] is not an object; skipped"); continue
            }
            do { slides.append(try decoder.decode(Slide.self, from: entryData)) }
            catch { warnings.append("slides[\(i)] skipped: \(error.localizedDescription)") }
        }
        if raw["slides"] == nil { warnings.append("\(name) has no slides array") }
        var info: DeckInfo?
        if let d = raw["deck"] as? [String: Any], let data = try? JSONSerialization.data(withJSONObject: d) {
            let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
            info = try? dec.decode(DeckInfo.self, from: data)
            if info == nil { warnings.append("deck info unreadable; ignored") }
        }
        return Loaded(manifest: DeckManifest(version: version, deck: info, slides: slides), warnings: warnings)
    }

    // MARK: Write

    /// Pretty, sorted keys, nil keys omitted: byte-stable for diffs.
    public func encoded() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return try enc.encode(self)
    }

    public func write(to url: URL) throws {
        try encoded().write(to: url, options: .atomic)
    }
}

//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import AppKit
import AVFoundation
import ARCShowFormat

/// The SLIDE TRACK for path A (ARC Slide Log plan, 2026-10-23): every change
/// on the program output as one line of `track.jsonl`, stamped on the wall
/// clock and a monotonic clock, with the live deck's id, file, page, build
/// state, the still that is up (a file inside the .arcdeck) and the clip that
/// is playing. The edit reads it back with the deck's own files and puts the
/// exact slide under the camera at the exact time; no recording of the feed
/// is needed. The show log stays the human record; this is the machine one,
/// and it is never rotated away.
///
/// Where: `reports/slide-track/<show>_<date>_<time>/` in the open show
/// folder, else `~/Library/Logs/ARC Presenter/slide-track/`. A new session
/// starts when a show folder attaches or closes.
///
/// What writes it: DeckManager at the same points that write the show log
/// (page, build, take, black, deck open/close, a clip starting or settling),
/// SwitchEngine on TAKE/RETURN of PowerPoint or a window, DisplayManager when
/// PROGRAM opens or closes, the control API for MARK and TALK.
@MainActor
enum SlideTrackRecorder {
    static let logsDirectory: URL = ShowLog.directory.appendingPathComponent(SlideTrack.folderName, isDirectory: true)

    private(set) static var writer: SlideTrackWriter?
    /// The unit test host records nothing unless a test turns this off and starts a session itself.
    static var disabled = AppEnvironment.isTestHost
    /// The deck manager whose live state goes into every event (the app sets the shared one at launch).
    static var deckManager: DeckManager?
    /// The program display's name, for the header (the app points this at the shared DisplayManager).
    static var programDisplayName: () -> String? = { nil }
    /// Who asked for the change about to be recorded: LiveSource sets key, tap or api; the API handler
    /// sets api for its own routes; the auto-advance sets auto. Consumed by the next event.
    static var pendingSource: String?

    private static var endObserver: Any?
    private static var lastKind: SlideTrack.Kind?
    private static var lastMono: Double = -1

    static var folder: URL? { writer?.folder }
    static var isRecording: Bool { writer != nil }

    /// Start a session: in the show folder's reports/slide-track/ when one is given, else under the logs.
    /// Ends the session before it, if any.
    static func start(showFolder: URL?, show: String?) {
        guard !disabled else { return }
        end()
        let base = showFolder.map { $0.appendingPathComponent(ShowSpec.Folder.reports.rawValue, isDirectory: true).appendingPathComponent(SlideTrack.folderName, isDirectory: true) } ?? logsDirectory
        let name = SlideTrack.sessionName(show: show)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let header = SlideTrack.Header(app: "ARC Presenter", appVersion: version, path: .presenter, show: show, session: name,
                                       display: programDisplayName())
        do {
            let w = try SlideTrackWriter(folder: base.appendingPathComponent(name, isDirectory: true), header: header)
            writer = w
            lastKind = nil; lastMono = -1
            ShowLog.log("slide track: \(w.folder.path)")
            // Time of day against the network, best effort, off the main thread; the header gains it when it answers.
            Task.detached(priority: .utility) {
                guard let offset = await SlideTrack.ntpOffsetMs() else { return }
                await MainActor.run {
                    guard writer === w else { return }
                    w.updateHeader { $0.ntpOffsetMsStart = offset }
                }
            }
            installEndObserver()
        } catch {
            writer = nil
            ShowLog.error("slide track could not start in \(base.path): \(error.localizedDescription)")
        }
    }

    /// SESSION_END and the header's end fields. Idempotent.
    static func end() {
        guard let w = writer else { return }
        writer = nil
        w.end()
        w.flush()
    }

    // MARK: Events

    /// Record `kind` with the live deck's state filled in, then `fill`'s own fields on top.
    static func record(_ kind: SlideTrack.Kind, _ fill: (inout SlideTrack.Event) -> Void = { _ in }) {
        let source = pendingSource
        pendingSource = nil
        guard let w = writer else { return }
        var e = w.event(kind)
        if let dm = deckManager { fillLive(&e, from: dm) }
        e.source = source
        fill(&e)
        lastKind = kind
        lastMono = e.tMono
        w.append(e)
    }

    /// Run `body` with `source` as who asked; every event it records carries it, and nothing after it does.
    @discardableResult
    static func asking<T>(_ source: String, _ body: () -> T) -> T {
        pendingSource = source
        defer { pendingSource = nil }
        return body()
    }

    /// A deck opened or closed: that deck's identity, not the live one's page.
    static func recordDeck(_ kind: SlideTrack.Kind, _ deck: Deck, note: String? = nil) {
        record(kind) { e in
            e.deck = deck.id.uuidString; e.deckFile = deck.url.lastPathComponent
            e.deckVersion = deck.isArcDeck ? deck.manifestVersion : nil; e.deckHash = deck.deckInfo?.sourceHash
            e.pages = deck.pageCount
            e.page = nil; e.segment = nil; e.segments = nil; e.build = nil; e.builds = nil
            e.still = nil; e.clip = nil; e.clipPosition = nil; e.isVideo = nil; e.black = nil
            e.note = note
        }
    }

    /// The live page was entered (a move, a jump, a take). A HOLD, unless a clip started on the way in
    /// during this same call (playSegment or playBuild already wrote the MOTION_START).
    static func recordPageEntered(kind: SlideTrack.Kind = .hold) {
        guard let w = writer else { pendingSource = nil; return }
        if kind == .hold, lastKind == .motionStart, w.event(.hold).tMono - lastMono < 0.05 { pendingSource = nil; return }
        record(kind)
    }

    /// The live deck's state: deck, page, segment, build, still, clip.
    private static func fillLive(_ e: inout SlideTrack.Event, from dm: DeckManager) {
        guard let deck = dm.liveDeck else { return }
        let page = dm.liveEngine.currentIndex
        e.deck = deck.id.uuidString
        e.deckFile = deck.url.lastPathComponent
        e.deckVersion = deck.isArcDeck ? deck.manifestVersion : nil
        e.deckHash = deck.deckInfo?.sourceHash
        e.page = page + 1
        e.pages = deck.pageCount
        e.black = dm.liveEngine.isBlack
        e.isVideo = dm.liveEngine.currentPageIsVideo
        if deck.isArcDeck {
            e.segment = dm.liveSegment
            e.segments = dm.liveSegmentsTotal
            let k = dm.liveBuildCount
            if k > 0 { e.build = dm.liveBuild; e.builds = k }
            e.still = deck.stateStillPath(page: page, state: dm.liveBuild) ?? "slides.pdf#\(page + 1)"
        } else if deck.isVideo {
            e.still = nil
        } else {
            e.still = "\(deck.url.lastPathComponent)#\(page + 1)"
        }
        if let p = dm.liveEngine.presentedClip ?? dm.liveEngine.currentPlayer {
            e.clip = deck.clipPath(of: p)
            let t = p.currentTime().seconds
            if t.isFinite { e.clipPosition = (t * 1000).rounded() / 1000 }
            if deck.isVideo { e.clip = e.clip ?? deck.url.lastPathComponent }
        }
    }

    /// A clip playing on the output reached its end and holds its last frame: MOTION_END. A looping page
    /// wraps instead, and the way-in clip that hands over to its page's movie is followed by that movie's
    /// own MOTION_START, so neither is an end.
    private static func installEndObserver() {
        guard endObserver == nil else { return }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                guard writer != nil, let dm = deckManager, let item = note.object as? AVPlayerItem,
                      let playing = dm.liveEngine.presentedClip ?? dm.liveEngine.currentPlayer, playing.currentItem === item,
                      let deck = dm.liveDeck else { return }
                if deck.loopsAt(page: dm.liveEngine.currentIndex) { return }
                record(.motionEnd) { $0.clip = deck.clipPath(of: playing) }
            }
        }
    }

    /// For the control API: the session folder, the count, the last lines.
    static func json(lines n: Int) -> String {
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        guard let w = writer else { return "{\"recording\":false}" }
        let tail = w.tail(n).joined(separator: ",")
        return "{\"recording\":true,\"folder\":\"\(esc(w.folder.path))\",\"file\":\"\(esc(w.trackURL.path))\",\"session\":\"\(esc(w.header.session))\",\"show\":\(w.header.show.map { "\"\(esc($0))\"" } ?? "null"),\"events\":\(w.count),\"lines\":[\(tail)]}"
    }
}

extension Deck {
    /// A file of this deck as the slide track names it: relative to the bundle (`stills/slide_012_s01.png`).
    func trackPath(_ url: URL?) -> String? {
        guard let url else { return nil }
        let base = self.url.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : url.lastPathComponent
    }

    /// The still of a build state, deck-relative; nil for a page without builds.
    func stateStillPath(page: Int, state: Int) -> String? {
        guard buildCount(page: page) > 0, let urls = stateStillURLs[page], urls.indices.contains(state) else { return nil }
        return trackPath(urls[state])
    }

    /// Whichever clip `player` is, deck-relative (a page's movie, its way in, or one of its builds).
    func clipPath(of player: AVPlayer) -> String? {
        if let (i, _) = slideVideoPlayers.first(where: { $0.value === player }) { return trackPath(slideVideoURLs[i]) }
        if let (i, _) = entryPlayers.first(where: { $0.value === player }) { return trackPath(entryClipURLs[i]) }
        guard let name = clipName(of: player) else { return nil }
        for urls in buildClipURLs.values { if let u = urls.compactMap({ $0 }).first(where: { $0.lastPathComponent == name }) { return trackPath(u) } }
        return name
    }
}

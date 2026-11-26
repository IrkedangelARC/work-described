//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation
import PDFKit
import AppKit
import AVFoundation
import IOKit.pwr_mgt

@MainActor
@Observable
final class DeckManager {
    private(set) var decks: [Deck] = []
    private(set) var previewDeckID: UUID?
    private(set) var liveDeckID: UUID?
    private var isSyncing: Bool = false
    private var lastLiveIndex: Int = 0

    // Preview pair (operator view reads these)
    private let previewEngine: SlideEngine
    private let previewCache: PageCache

    // Live pair (program output + confidence monitor read these)
    let liveEngine: SlideEngine
    let liveCache: PageCache

    // Timer engine for auto-cue triggers
    private let timerEngine: TimerEngine

    // Sleep prevention (IOKit power assertion)
    private var sleepAssertionID: IOPMAssertionID = 0
    private var hasSleepAssertion: Bool = false

    init(previewEngine: SlideEngine, previewCache: PageCache,
         liveEngine: SlideEngine, liveCache: PageCache,
         timerEngine: TimerEngine) {
        self.previewEngine = previewEngine
        self.previewCache = previewCache
        self.liveEngine = liveEngine
        self.liveCache = liveCache
        self.timerEngine = timerEngine
        // Every navigation on either engine funnels into one playback
        // reconcile, so no path can orphan a playing clip.
        previewEngine.onNavigate = { [weak self] in self?.reconcilePlayback(); self?.reconcilePreviewStill() }
        liveEngine.onNavigate = { [weak self] in self?.reconcilePlayback() }
        liveEngine.managesPresentation = true
    }

    // MARK: - Playback Policy

    /// THE single source of truth for what may make sound: only the live
    /// deck's current clip (or the live single-video player). Everything
    /// else — every deck, every per-slide clip, on-screen or orphaned —
    /// gets paused. Called on navigation, tab switch, TAKE, and close.
    func reconcilePlayback() {
        // The presented clip, or (nothing presented) the live page's own clip:
        // a clip started on the live page by any path keeps its sound.
        let allowed = liveEngine.currentPlayer
            ?? (liveEngine.isArcDeck ? liveEngine.slideVideoPlayers[liveEngine.currentIndex] : nil)
        // Only what is PLAYING is paused. Pausing every player of every open deck on every click, paused or
        // not, held the main thread 60 to 175 ms per click with 16 decks open (measured 2026-09-17: /state
        // replies, CoreMedia "deferred transaction delayed by 0.127s", 167,000 log lines in 75 s): the stutter.
        for deck in decks {
            if let p = deck.player, p !== allowed, Self.isRunning(p) { p.pause() }
            for p in deck.allClipPlayers where p !== allowed && Self.isRunning(p) { p.pause() }
        }
    }

    static func isRunning(_ p: AVPlayer) -> Bool { p.rate != 0 || p.timeControlStatus != .paused }

    /// A clip goes ON SCREEN only once it stands where it starts. A build that has played before is parked on
    /// its LAST frame (the finished build); shown first and rewound after, the room saw the build appear, vanish
    /// and animate in again (2026-09-17: "the click put the next build on screen, removed it and then
    /// opened it again causing a stutter"). `token` drops a start that a later click has overtaken.
    private var startToken = 0
    /// How long a start waits on its rewind before it goes anyway. A zero-tolerance seek on a paused clip
    /// can simply never complete: on 2026-09-30 (5.5.0, slides 45/48/56) ten build starts sat on a seek with
    /// no SeekDidComplete until the next key or a back-step, and the click looked dead. Healthy seeks finish in 1 to 20 ms.
    private static let startSeekWatchdog: TimeInterval = 0.15
    /// `then` runs on the main actor right after the clip is presented and playing.
    private func start(_ player: AVPlayer, at seconds: Double, tolerance: Double = 0.02,
                       stillValid: @escaping () -> Bool, then: (() -> Void)? = nil) {
        startToken += 1
        let token = startToken
        let begin = { [weak self] in
            guard let self, token == self.startToken, stillValid() else { return }
            self.startToken += 1        // begun: a late seek completion or the watchdog does not begin it twice
            self.liveEngine.present(clip: player)
            self.reconcilePlayback()
            player.play()
            then?()
        }
        let from = player.currentTime().seconds
        if abs(from - seconds) > tolerance {
            let asked = Date()
            player.pause()
            player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { done in
                Task { @MainActor in
                    let ms = Int(Date().timeIntervalSince(asked) * 1000)
                    if ms > 50 { ShowLog.log("clip start waited \(ms) ms on its rewind (\(String(format: "%.3f", from)) -> \(seconds)\(done ? "" : ", cancelled"))") }
                    begin()
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.startSeekWatchdog) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, token == self.startToken, stillValid() else { return }
                    ShowLog.log("clip start: rewind \(String(format: "%.3f", from)) -> \(seconds) not done after \(Int(Self.startSeekWatchdog * 1000)) ms, starting anyway")
                    player.currentItem?.cancelPendingSeeks()
                    begin()
                }
            }
        } else {
            begin()
        }
    }

    /// Park a clip that a forward click will show next at its start, while it is still off screen.
    private func parkAtStart(_ player: AVPlayer?, at seconds: Double = 0) {
        guard let player, player !== liveEngine.presentedClip, abs(player.currentTime().seconds - seconds) > 0.02 else { return }
        player.pause()
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // MARK: - Computed

    var previewDeck: Deck? {
        guard let id = previewDeckID else { return nil }
        return decks.first { $0.id == id }
    }

    var liveDeck: Deck? {
        guard let id = liveDeckID else { return nil }
        return decks.first { $0.id == id }
    }

    var deckCount: Int { decks.count }
    var hasMultipleDecks: Bool { decks.count > 1 }

    // MARK: - Tab strip picks (DeckStripPicks has the rules)

    /// The two decks the operator keeps in the header strip beside the pinned LIVE tab.
    private(set) var stripPicks = DeckStripPicks()

    /// A deck's identity for the picks and the session: its standardized path, as `addDeck` dedups.
    nonisolated static func key(_ url: URL) -> String { url.standardizedFileURL.path }
    func key(_ deck: Deck) -> String { Self.key(deck.url) }
    private var openKeys: [String] { decks.map(key) }
    private var liveKey: String? { liveDeck.map(key) }

    /// The strip's tabs after the pinned live one: the picks, then the previewed deck if it is not picked.
    var stripDecks: [Deck] {
        let keys = stripPicks.strip(open: openKeys, live: liveKey, preview: previewDeck.map(key))
        return keys.compactMap { k in decks.first { key($0) == k } }
    }

    func isInStrip(_ deck: Deck) -> Bool { stripPicks.isPicked(key(deck)) }

    @discardableResult
    func toggleStrip(_ deckID: UUID) -> DeckStripPicks.ToggleResult {
        guard let deck = decks.first(where: { $0.id == deckID }) else { return .unpicked }
        return stripPicks.toggle(key(deck), live: liveKey)
    }

    /// Replace the picks by key (session restore, `POST /decks/strip`).
    func setStripPicks(_ keys: [String]) {
        stripPicks.set(keys, open: openKeys, live: liveKey)
    }

    var isPreviewingOffline: Bool {
        guard let preview = previewDeckID, let live = liveDeckID else { return false }
        return preview != live
    }

    var previewDeckName: String { previewDeck?.fileName ?? "" }
    var liveDeckName: String { liveDeck?.shownName ?? "" }

    // MARK: - Deck Management

    /// Newest content modification date for a deck URL. For an .arcdeck bundle,
    /// the newest of slides.pdf / manifest.json (the bundle folder's own mtime
    /// doesn't always bump on in-place edits); otherwise the file's mtime.
    static func contentModDate(of url: URL) -> Date? {
        let fm = FileManager.default
        func mod(_ u: URL) -> Date? {
            (try? fm.attributesOfItem(atPath: u.path)[.modificationDate]) as? Date
        }
        var isDir: ObjCBool = false
        let exists = fm.fileExists(atPath: url.path, isDirectory: &isDir)
        guard exists else { return nil }
        if isDir.boolValue {
            let candidates = [
                url.appendingPathComponent("slides.pdf"),
                url.appendingPathComponent("manifest.json"),
                url,
            ]
            return candidates.compactMap(mod).max()
        }
        return mod(url)
    }

    /// The PDF is parsed OFF the main thread, then the deck is added as usual
    /// (stability plan 2.4: `PDFDocument(url:)` on main was a hitch per deck
    /// during a restore). Same dedup and reload rules as `addDeck`.
    func loadDeck(url: URL, targetSize: CGSize, kind: DeckKind = .pdf) async -> Deck? {
        let pdfURL = kind == .arcdeck ? url.appendingPathComponent("slides.pdf") : (kind == .pdf ? url : nil)
        var preloaded: PDFDocument?
        if let pdfURL {
            preloaded = await Task.detached(priority: .userInitiated) { PDFDocument(url: pdfURL) }.value
        }
        return addDeck(url: url, targetSize: targetSize, kind: kind, preloaded: preloaded)
    }

    @discardableResult
    func addDeck(url: URL, targetSize: CGSize, kind: DeckKind = .pdf, preloaded: PDFDocument? = nil) -> Deck? {
        // Dedup by standardized path (raw URL == misses trailing-slash and
        // symlink differences on .arcdeck folder bundles, which produced
        // duplicate tabs). Opening a loaded deck focuses its tab and also
        // collapses duplicate session-restore entries.
        let key = url.standardizedFileURL
        if let idx = decks.firstIndex(where: { $0.url.standardizedFileURL == key }) {
            let existing = decks[idx]
            // If the file changed on disk since we loaded it (e.g. edited in the
            // Assimilator), reload in place so the operator sees the new deck —
            // preserving tab position and preview/live status.
            let current = Self.contentModDate(of: url)
            if let cm = current, let lm = existing.loadedModDate, cm > lm,
               let fresh = (kind == .arcdeck) ? Deck(arcdeckURL: url, preloaded: preloaded) : Deck(url: url, kind: kind, preloaded: preloaded) {
                let wasPreview = previewDeckID == existing.id
                let wasLive = liveDeckID == existing.id
                existing.player?.pause()
                existing.allClipPlayers.forEach { $0.pause() }
                existing.cancelBuild()
                fresh.loadedModDate = current
                decks[idx] = fresh
                if fresh.isVideo { fresh.loadVideoDuration() }
                fresh.buildCache(targetSize: targetSize) { [weak self] updated in
                    guard let self else { return }
                    if self.previewDeckID == updated.id { self.syncCacheToPreview(from: updated) }
                    if self.liveDeckID == updated.id { self.syncCacheToLive(from: updated) }
                }
                if wasPreview { previewDeckID = fresh.id; syncPreviewToEngine() }
                if wasLive {
                    liveDeckID = fresh.id
                    if fresh.isVideo { fresh.player?.isMuted = false }
                    // The old deck's paused clip frame stayed layered over the
                    // new still until the next click (audit R10).
                    liveEngine.present(clip: nil)
                    syncLiveToEngine(from: fresh)
                }
                muteIfSwitchIsLive(fresh)
                reconcilePlayback()
                return fresh
            }
            previewDeckID = existing.id
            syncPreviewToEngine()
            return existing
        }

        let deck: Deck?
        if kind == .arcdeck {
            deck = Deck(arcdeckURL: url, preloaded: preloaded)
        } else {
            deck = Deck(url: url, kind: kind, preloaded: preloaded)
        }
        guard let deck else { return nil }
        deck.loadedModDate = Self.contentModDate(of: url)
        decks.append(deck)
        muteIfSwitchIsLive(deck)
        ShowLog.log("deck opened \(deck.fileName): \(deck.pageCount) page\(deck.pageCount == 1 ? "" : "s"), \(kind)\(deck.isArcDeck ? ", \(deck.slideVideoPlayers.count) clips" : "")")
        SlideTrackRecorder.recordDeck(.deckOpen, deck)

        if deck.isVideo {
            deck.loadVideoDuration()
        }

        deck.buildCache(targetSize: targetSize) { [weak self] updatedDeck in
            guard let self else { return }
            if self.previewDeckID == updatedDeck.id {
                self.syncCacheToPreview(from: updatedDeck)
            }
            if self.liveDeckID == updatedDeck.id {
                self.syncCacheToLive(from: updatedDeck)
            }
        }

        if previewDeckID == nil {
            previewDeckID = deck.id
            syncPreviewToEngine()
        }
        if liveDeckID == nil {
            liveDeckID = deck.id
            preventSleep()
            // First deck is live, unmute video
            if deck.isVideo {
                deck.player?.isMuted = false
            }
            syncLiveToEngine()
        }
        stripPicks.opened(self.key(deck), live: liveKey)

        return deck
    }

    func previewDeckSwitch(to deckID: UUID) {
        guard deckID != previewDeckID else { return }
        guard decks.contains(where: { $0.id == deckID }) else { return }

        syncFromPreviewEngine()
        previewDeckID = deckID
        syncPreviewToEngine()
        // A previewed clip left playing must not survive the tab switch.
        reconcilePlayback()
    }

    func take() {
        syncFromPreviewEngine()

        // Fully silence the outgoing live deck: its single player AND every
        // arcdeck per-slide clip (the .player pause alone misses those).
        if liveDeckID != previewDeckID, let old = liveDeck {
            old.player?.isMuted = true
            old.player?.pause()
            old.allClipPlayers.forEach { $0.pause() }
            syncFromLiveEngine()
        }

        let oldLiveKey = liveKey
        liveDeckID = previewDeckID
        stripPicks.liveChanged(from: oldLiveKey, to: liveKey)

        guard let deck = liveDeck else { return }
        ShowLog.log("TAKE \(deck.fileName) slide \(deck.currentIndex + 1)")
        // Unmute the new live video
        if deck.isVideo {
            deck.player?.isMuted = false
        }
        syncLiveToEngine(from: deck)
        enterLivePage(liveEngine.currentIndex, forward: false, resume: true)
        reconcilePlayback()
        reconcilePreviewStill()
        SlideTrackRecorder.recordPageEntered(kind: .take)
    }

    func switchToNext() {
        guard let currentID = previewDeckID,
              let idx = decks.firstIndex(where: { $0.id == currentID }),
              idx + 1 < decks.count
        else { return }
        previewDeckSwitch(to: decks[idx + 1].id)
    }

    func switchToPrevious() {
        guard let currentID = previewDeckID,
              let idx = decks.firstIndex(where: { $0.id == currentID }),
              idx > 0
        else { return }
        previewDeckSwitch(to: decks[idx - 1].id)
    }

    func removeDeck(deckID: UUID) {
        guard let idx = decks.firstIndex(where: { $0.id == deckID }) else { return }

        let deck = decks[idx]
        ShowLog.log("deck closed \(deck.fileName)\(deck.id == liveDeckID ? " (was LIVE)" : "")")
        SlideTrackRecorder.recordDeck(.deckClose, deck, note: deck.id == liveDeckID ? "was live" : nil)
        // Pause the single-video player AND every per-slide arcdeck clip —
        // otherwise audio/video keeps playing after the deck is closed.
        // (Unconditional: a removed deck may never sound, even if live.)
        deck.player?.pause()
        deck.allClipPlayers.forEach { $0.pause() }
        deck.cancelBuild()
        decks.remove(at: idx)
        stripPicks.closed(key(deck))
        defer { reconcilePlayback() }

        if previewDeckID == deckID {
            if let next = decks.first {
                previewDeckID = next.id
                syncPreviewToEngine()
            } else {
                previewDeckID = nil
                previewEngine.unload()
                previewCache.clear()
            }
        }

        if liveDeckID == deckID {
            if let next = decks.first {
                liveDeckID = next.id
                stripPicks.liveChanged(from: nil, to: key(next))
                syncLiveToEngine(from: next)
            } else {
                liveDeckID = nil
                allowSleep()
                liveEngine.unload()
                liveCache.clear()
            }
        }
    }

    // MARK: - Sync Helpers

    private func syncDeckToEngine(_ deck: Deck, engine: SlideEngine) {
        engine.loadFromDeck(
            document: deck.pdfDocument,
            index: deck.currentIndex,
            pageCount: deck.pageCount,
            isBlack: deck.isBlack,
            fileName: deck.fileName,
            jumpText: deck.jumpText,
            isVideo: deck.isVideo,
            player: deck.player,
            isArcDeck: deck.isArcDeck,
            slideVideoPlayers: deck.slideVideoPlayers,
            notes: deck.notes
        )
    }

    /// Tabs in the given order (ids not listed keep their relative order after).
    func setDeckOrder(_ ids: [UUID]) {
        let ranked = ids.enumerated().reduce(into: [UUID: Int]()) { $0[$1.element] = $1.offset }
        let sorted = decks.enumerated().sorted { a, b in
            let ra = ranked[a.element.id] ?? Int.max, rb = ranked[b.element.id] ?? Int.max
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)
        if sorted.map(\.id) != decks.map(\.id) { decks = sorted }
    }

    /// Put a deck that is NOT live on a page (V5: a staged twin follows the
    /// live slide so a TAKE never moves the room). The live deck is the
    /// clicker's and is refused.
    func park(deckID: UUID, at index: Int, black: Bool) {
        guard deckID != liveDeckID, let deck = decks.first(where: { $0.id == deckID }) else { return }
        deck.currentIndex = SlideEngine.clampedIndex(index, pageCount: deck.pageCount)
        deck.isBlack = black
        if deckID == previewDeckID { syncPreviewToEngine() }
    }

    /// Push every deck's own index into the engines. Restore sets a deck's
    /// saved index AFTER addDeck synced the engines at 0; without this, the
    /// first take copied the engine's 0 back over the saved slide
    /// (stability audit 2026-09-16, R2).
    func resyncEnginesFromDecks() {
        syncPreviewToEngine()
        syncLiveToEngine()
    }

    /// The other direction, before a save: the previewed deck's position lives
    /// in the preview engine until a switch or take copies it back, so a save
    /// that read `deck.currentIndex` alone stored the preview one slide stale.
    func commitEngineStateToDecks() {
        syncFromPreviewEngine()
        syncFromLiveEngine()
    }

    /// Where a deck stands right now, engine-first for the live and previewed
    /// decks, WITHOUT writing anything: the show-state saver observes this, and
    /// a write inside an observed read re-triggers the observation forever
    /// (three saves per burst, 2026-09-16). Live wins when a deck is both.
    func effectiveIndex(of deck: Deck) -> Int {
        // Both engines are read up front so a change in either is observed,
        // including a preview move on the deck that is also live.
        let preview = previewEngine.currentIndex, live = liveEngine.currentIndex
        guard !deck.isVideo || deck.isArcDeck else { return deck.currentIndex }
        if deck.id == liveDeckID { return live }
        if deck.id == previewDeckID { return preview }
        return deck.currentIndex
    }

    func effectiveBlack(of deck: Deck) -> Bool {
        let preview = previewEngine.isBlack, live = liveEngine.isBlack
        guard !deck.isVideo || deck.isArcDeck else { return deck.isBlack }
        if deck.id == liveDeckID { return live }
        if deck.id == previewDeckID { return preview }
        return deck.isBlack
    }

    // MARK: - Preview Sync (operator view)

    private func syncPreviewToEngine() {
        guard let deck = previewDeck else { return }
        deck.ensurePages(around: deck.currentIndex)
        previewCache.loadFrom(images: deck.images, isLoading: deck.isLoading, progress: deck.progress)
        syncDeckToEngine(deck, engine: previewEngine)
    }

    private func syncFromPreviewEngine() {
        guard let deck = previewDeck, !deck.isVideo || deck.isArcDeck else { return }
        deck.currentIndex = previewEngine.currentIndex
        deck.isBlack = previewEngine.isBlack
        deck.jumpText = previewEngine.jumpText
    }

    private func syncCacheToPreview(from deck: Deck) {
        previewCache.loadFrom(images: deck.images, isLoading: deck.isLoading, progress: deck.progress)
    }

    // MARK: - Live Sync (program output + confidence monitor)

    private func syncLiveToEngine(from deck: Deck? = nil) {
        guard let deck = deck ?? liveDeck else { return }
        deck.ensurePages(around: deck.currentIndex)
        liveCache.loadFrom(images: deck.images, isLoading: deck.isLoading, progress: deck.progress)
        syncDeckToEngine(deck, engine: liveEngine)
    }

    private func syncFromLiveEngine() {
        guard let deck = liveDeck, !deck.isVideo || deck.isArcDeck else { return }
        deck.currentIndex = liveEngine.currentIndex
        deck.isBlack = liveEngine.isBlack
        deck.jumpText = liveEngine.jumpText
    }

    private func syncCacheToLive(from deck: Deck) {
        liveCache.loadFrom(images: deck.images, isLoading: deck.isLoading, progress: deck.progress)
    }

    // MARK: - Builds (manifest version 3, docs/PLAN_per_build_clips.md)
    //
    // The presenter sets the pace: a click plays ONE build and holds. Back
    // undoes ONE build, as PowerPoint does, by cutting to the previous
    // state's still: no seek, no animation in reverse.

    /// Which page of a long speaker note the confidence monitor shows (0-based); back to the top on every live slide.
    var notesPage = 0

    /// Builds of the live page, and the state it stands in (0 = none played).
    var liveBuildCount: Int { liveDeck?.buildCount(page: liveEngine.currentIndex) ?? 0 }
    var liveBuild: Int { min(liveDeck?.buildStates[liveEngine.currentIndex] ?? 0, liveBuildCount) }
    @ObservationIgnored private var buildEndObserver: NSObjectProtocol?

    @ObservationIgnored private var entryEndObserver: NSObjectProtocol?
    private func clearEntryEndObserver() {
        if let o = entryEndObserver { NotificationCenter.default.removeObserver(o) }
        entryEndObserver = nil
    }

    private func clearBuildEndObserver() {
        if let o = buildEndObserver { NotificationCenter.default.removeObserver(o) }
        buildEndObserver = nil
    }

    /// Play build `n` of the live page from its first frame and hold its last.
    private func playBuild(_ n: Int, on page: Int) -> Bool {
        guard let deck = liveDeck, let player = deck.buildPlayer(page: page, n: n) else { return false }
        clearBuildEndObserver()
        // The state being LEFT stays underneath while the clip readies (and cuts
        // off a build still animating, as a click in PowerPoint finishes it):
        // never a flash of what is coming.
        liveEngine.presentedClip?.pause()
        liveEngine.present(still: deck.stateImage(page: page, state: n - 1))
        deck.buildStates[page] = n
        let nextBuild = deck.buildPlayer(page: page, n: n + 1)
        parkAtStart(nextBuild)
        // The output's back layer holds THIS build (pre-armed by the last click) until it is presented. Re-arming
        // it with the next build here pulled the starting player off its only video layer mid-rewind (video
        // targets 1 => 0) and that rewind never completed: every other build sat dead until the next key (2026-09-30).
        start(player, at: 0, stillValid: { [weak self, weak deck] in
            guard let self, let deck else { return false }
            return self.liveDeck === deck && self.liveEngine.currentIndex == page && deck.buildStates[page] == n
        }, then: { [weak self, weak deck] in
            guard let self, let deck else { return }
            self.liveEngine.prefetchClip = nextBuild ?? deck.entryPlayerAt(page: page + 1) ?? deck.playerAt(page: page + 1)
        })
        // Its last frame IS state n; put that still under it for whatever comes next.
        buildEndObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main) { [weak self, weak deck] _ in
            MainActor.assumeIsolated {
                guard let self, let deck, self.liveDeck === deck, self.liveEngine.currentIndex == page, deck.buildStates[page] == n else { return }
                self.liveEngine.present(still: deck.stateImage(page: page, state: n))
            }
        }
        SlideTrackRecorder.record(.motionStart) { $0.clip = deck.clipPath(of: player); $0.clipPosition = 0; $0.build = n; $0.still = deck.stateStillPath(page: page, state: n) }
        return true
    }

    /// CUT the live page to a state: the back-step, and the state a page is resumed in.
    private func showLiveState(_ state: Int, on page: Int) {
        guard let deck = liveDeck else { return }
        clearBuildEndObserver()
        liveEngine.presentedClip?.pause()
        deck.buildStates[page] = state
        startToken += 1                 // a build still waiting on its rewind does not come up over the cut
        liveEngine.present(clip: nil)
        liveEngine.present(still: deck.stateImage(page: page, state: state))
        let nextBuild = deck.buildPlayer(page: page, n: state + 1)
        parkAtStart(nextBuild)
        liveEngine.prefetchClip = nextBuild ?? deck.entryPlayerAt(page: page + 1) ?? deck.playerAt(page: page + 1)
        reconcilePlayback()
    }

    /// The previewed page shows the state it stands in: what a TAKE would put up.
    func reconcilePreviewStill() {
        guard let deck = previewDeck, deck.isArcDeck, deck.hasBuilds, previewDeckID != liveDeckID else {
            if previewDeckID != liveDeckID || liveDeck?.hasBuilds != true { previewEngine.present(still: nil) }
            else { previewEngine.present(still: liveEngine.stateStill) }
            return
        }
        let page = previewEngine.currentIndex
        previewEngine.present(still: deck.stateImage(page: page, state: deck.buildStates[page] ?? 0))
    }

    // MARK: - ARC Deck Video Clip Management

    // MARK: - Click segments (arcdeck)

    /// Clicks consumed on the live page since it was entered. A page's own
    /// clicks (movie start) play from its clip; the builds PowerPoint ran
    /// while leaving it were recorded at the head of the NEXT page's clip
    /// and play from there while the slide number stays put.
    private(set) var liveSegment: Int = 0
    private var segmentStop: Any?
    private var segmentStopPlayer: AVPlayer?
    /// Pending automatic advance for the live page (manifest autoAdvance).
    private var autoAdvanceTask: Task<Void, Never>?

    /// The object firing on the program output right now: a page's entry
    /// clip (the TRN box before it) or the page itself (its main clip or
    /// its still). Drawn as a green box in the filmstrip (2026-09-12).
    var liveFiring: (page: Int, entry: Bool) {
        let idx = liveEngine.currentIndex
        guard let deck = liveDeck, deck.isArcDeck, let p = liveEngine.presentedClip else { return (idx, false) }
        for page in [idx, idx + 1] {
            if deck.entryPlayerAt(page: page) === p { return (page, true) }
            if deck.playerAt(page: page) === p { return (page, false) }
        }
        return (idx, false)
    }

    /// How many clicks the live page still answers before the next slide.
    var liveSegmentsTotal: Int {
        guard let deck = liveDeck, deck.isArcDeck else { return 0 }
        let p = liveEngine.currentIndex
        return deck.ownClickCount(page: p) + deck.buildClickCount(page: p + 1)
    }

    /// Play one stretch of a page's clip on the output and hold at its end.
    private func playSegment(page: Int, _ seg: Deck.Segment) {
        guard let deck = liveDeck, let player = seg.entry ? deck.entryPlayerAt(page: page) : deck.playerAt(page: page) else { return }
        if let old = segmentStop, let op = segmentStopPlayer { op.removeTimeObserver(old) }
        segmentStop = nil; segmentStopPlayer = nil
        if let end = seg.end {
            let t = CMTime(seconds: end, preferredTimescale: 600)
            segmentStop = player.addBoundaryTimeObserver(forTimes: [NSValue(time: t)], queue: .main) { [weak player, weak deck] in
                player?.pause()
                MainActor.assumeIsolated {
                    guard let player, let deck else { return }
                    SlideTrackRecorder.record(.motionEnd) { $0.clip = deck.clipPath(of: player); $0.clipPosition = end }
                }
            }
            segmentStopPlayer = player
        }
        clearEntryEndObserver()
        // Pre-arm what a forward click plays next: this page's main clip
        // after its entry clip, otherwise the next page's way in.
        if seg.entry, let main = deck.playerAt(page: page) {
            let first = deck.ownSegment(page: page, n: 0)?.start ?? (deck.loopStarts[page] ?? 0)
            if abs(main.currentTime().seconds - first) > 0.05 { main.seek(to: CMTime(seconds: first, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) }
            liveEngine.prefetchClip = main
            // A movie that plays ON ENTRY has no click to start it: the way in
            // hands over to it when it ends. Capture cuts a looping movie from
            // its way in so the loop holds the movie only (2026-09-17:
            // "these should be separate so the loop does not include the transition").
            if deck.ownClickCount(page: page) == 0 {
                entryEndObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main) { [weak self, weak deck] _ in
                    MainActor.assumeIsolated {
                        guard let self, let deck, self.liveDeck === deck, self.liveEngine.currentIndex == page, self.liveEngine.presentedClip === player else { return }
                        self.playSegment(page: page, Deck.Segment(start: first, end: nil))
                    }
                }
            }
        } else {
            liveEngine.prefetchClip = deck.entryPlayerAt(page: page + 1) ?? deck.playerAt(page: page + 1)
        }
        // 0.05: a segment's boundary pause lands a frame or two late, and that is not worth a seek back.
        start(player, at: seg.start, tolerance: 0.05) { [weak self, weak deck] in
            guard let self, let deck else { return false }
            return self.liveDeck === deck && self.liveEngine.currentIndex == page
        }
        SlideTrackRecorder.record(.motionStart) { $0.clip = deck.clipPath(of: player); $0.clipPosition = seg.start; $0.page = page + 1 }
    }

    /// Park the page after the live one at its first click, off screen, so a
    /// forward click plays without a seek.
    private func prepareNextClip(after page: Int) {
        guard let deck = liveDeck, deck.manifestVersion >= 2,
              let next = deck.entryPlayerAt(page: page + 1) ?? deck.playerAt(page: page + 1),
              next !== liveEngine.presentedClip else { return }
        if liveEngine.prefetchClip == nil || liveEngine.prefetchClip === deck.playerAt(page: page + 1) { liveEngine.prefetchClip = next }
        let first = deck.buildSegment(page: page + 1, n: 0)?.start ?? deck.entrySegment(page: page + 1)?.start ?? 0
        if abs(next.currentTime().seconds - first) > 0.05 {
            next.seek(to: CMTime(seconds: first, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    /// The live page changed (or was taken): decide what the output shows.
    /// Forward: the entry segment (transition, then hold before the page's
    /// first click). Backward or take: the page still, as PowerPoint shows a
    /// revisited slide in its final state; a looping page plays its loop.
    private func enterLivePage(_ index: Int, forward: Bool, resume: Bool = false) {
        liveSegment = 0
        notesPage = 0
        autoAdvanceTask?.cancel(); autoAdvanceTask = nil
        clearBuildEndObserver()
        clearEntryEndObserver()
        if let deck = liveDeck, deck.isArcDeck {
            // Every entry picks what the output pre-arms afresh. prepareNextClip keeps an arm it did not set, so a
            // stale one (a restored session's slide 47) survived onto image slide 2 and slide 3 started cold (2026-09-30).
            liveEngine.prefetchClip = nil
            // Forward: nothing built yet. Back into it: finished, and back again
            // steps its builds down. Taken or restored: where it was left.
            let k = deck.buildCount(page: index)
            let state = k == 0 ? 0 : (forward ? 0 : (resume ? min(deck.buildStates[index] ?? 0, k) : k))
            if k > 0 { deck.buildStates[index] = state }
            liveEngine.present(still: deck.stateImage(page: index, state: state))
            deck.keepBuildPlayers(for: [index, index + 1])
            if k > 0, state < k { _ = deck.buildPlayer(page: index, n: state + 1) }   // readied before the click
        } else {
            liveEngine.present(still: nil)
        }
        if forward, let deck = liveDeck, let adv = deck.autoAdvances[index] {
            // Leave when the clip has played out (its tail is the exit
            // transition) and at least `adv` seconds have passed.
            let clipLen = deck.playerAt(page: index)?.currentItem?.asset.duration.seconds ?? 0
            let start = deck.entrySegment(page: index)?.start ?? 0
            let wait = max(adv, (clipLen.isFinite ? clipLen - start : 0)) + 0.1
            autoAdvanceTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                guard !Task.isCancelled, let self, self.liveEngine.currentIndex == index else { return }
                SlideTrackRecorder.asking("auto") { self.liveNext() }
            }
        }
        guard let deck = liveDeck, deck.isArcDeck else { return }
        if let old = segmentStop, let op = segmentStopPlayer { op.removeTimeObserver(old) }
        segmentStop = nil; segmentStopPlayer = nil
        guard deck.playerAt(page: index) != nil || deck.entryPlayerAt(page: index) != nil else {
            liveEngine.present(clip: nil)
            reconcilePlayback()
            prepareNextClip(after: index)
            armNextBuild(on: index)
            return
        }
        if deck.manifestVersion < 2 {
            // Version 1: one clip per page, played whole on any arrival.
            playSegment(page: index, Deck.Segment(start: 0, end: nil))
        } else if deck.movieAfterBuilds(page: index) {
            // The movie waits for the click after the last build: the state still is the page for now.
            liveEngine.present(clip: nil)
            reconcilePlayback()
        } else if forward, let seg = deck.entrySegment(page: index) {
            playSegment(page: index, seg)
        } else if deck.loopsAt(page: index) {
            playSegment(page: index, Deck.Segment(start: deck.loopStarts[index] ?? 0, end: nil))
        } else {
            liveEngine.present(clip: nil)
            reconcilePlayback()
        }
        prepareNextClip(after: index)
        armNextBuild(on: index)
    }

    /// When the next click on the live page plays a build clip, pre-arm THAT on the output, as a back-step does.
    /// Entering a page left the next page armed instead, so build 1 started cold: play() ran with no video
    /// layer attached, CoreMedia rebuilt the pipeline mid-play and PGM showed 7 or 8 of the clip's ~26
    /// frames (2026-09-30, slides 43 and 45: a stutter, then the end state). The retry after a back-step was clean.
    private func armNextBuild(on page: Int) {
        guard let deck = liveDeck, deck.isArcDeck else { return }
        let k = deck.buildCount(page: page), state = deck.buildStates[page] ?? 0
        // liveNext plays the page's own clicks first, unless its movie waits for the builds.
        guard state < k, deck.buildAnimates(page: page, n: state + 1),
              deck.ownClickCount(page: page) == 0 || deck.movieAfterBuilds(page: page),
              // A separate way-in clip that hands over to the page's movie on its own keeps the arm on the movie:
              // that hand-over is not a click (playSegment). A way in cut from the page's own clip (clicks [0.7]) is not that.
              !(deck.entryPlayerAt(page: page) != nil && deck.playerAt(page: page) != nil
                && deck.ownClickCount(page: page) == 0 && !deck.movieAfterBuilds(page: page)),
              let build = deck.buildPlayer(page: page, n: state + 1) else { return }
        parkAtStart(build)
        liveEngine.prefetchClip = build
    }

    // MARK: - Live Navigation (clicker / keyboard always drives live)

    func liveNext() {
        autoAdvanceTask?.cancel(); autoAdvanceTask = nil
        lastLiveIndex = liveEngine.currentIndex
        if let deck = liveDeck, deck.isArcDeck, deck.manifestVersion >= 2 {
            let p = lastLiveIndex
            let own = deck.ownClickCount(page: p)
            // Version 3: one clip per build, owned by this page.
            let k = deck.buildCount(page: p), state = deck.buildStates[p] ?? 0
            // A click-started source movie on a page with builds plays AFTER them (Deck.movieAfterBuilds).
            let buildsFirst = deck.movieAfterBuilds(page: p) && state < k
            if !buildsFirst, liveSegment < own, let seg = deck.ownSegment(page: p, n: liveSegment) {
                liveSegment += 1; playSegment(page: p, seg)
                if deck.movieAfterBuilds(page: p) { ShowLog.log("live \(liveDeckName) slide \(p + 1): the movie, after its \(k) build\(k == 1 ? "" : "s")") }
                return
            }
            if state < k, !deck.buildAnimates(page: p, n: state + 1) {
                // A CUT ("Appear"): the next state's still, at once. No clip, no swap, nothing to stutter.
                showLiveState(state + 1, on: p)
                ShowLog.log("live \(liveDeckName) slide \(p + 1) build \(state) -> \(state + 1) of \(k) (cut)")
                SlideTrackRecorder.record(.hold)
                syncLiveBackToPreviewIfNeeded(); reconcilePreviewStill()
                return
            }
            if state < k, playBuild(state + 1, on: p) {
                ShowLog.log("live \(liveDeckName) slide \(p + 1) build \(state) -> \(state + 1) of \(k)")
                syncLiveBackToPreviewIfNeeded(); reconcilePreviewStill()
                return
            }
            if let seg = deck.buildSegment(page: p + 1, n: liveSegment - own) {
                liveSegment += 1; playSegment(page: p + 1, seg); return
            }
        }
        liveEngine.next()
        if liveEngine.currentIndex != lastLiveIndex { logLiveMove(); enterLivePage(liveEngine.currentIndex, forward: true); SlideTrackRecorder.recordPageEntered() }
        syncLiveBackToPreviewIfNeeded()
        checkTimerCue(forward: true)
    }

    /// One line per live slide change: deck, from, to.
    private func logLiveMove() {
        ShowLog.log("live \(liveDeckName) \(lastLiveIndex + 1) -> \(liveEngine.currentIndex + 1)")
        storeLastFrame()
    }

    func livePrevious() {
        autoAdvanceTask?.cancel(); autoAdvanceTask = nil
        lastLiveIndex = liveEngine.currentIndex
        // Back undoes ONE build (PowerPoint's rule): a cut to the previous state.
        if let deck = liveDeck, deck.isArcDeck, deck.buildCount(page: lastLiveIndex) > 0 {
            let state = min(deck.buildStates[lastLiveIndex] ?? 0, deck.buildCount(page: lastLiveIndex))
            if state > 0 {
                showLiveState(state - 1, on: lastLiveIndex)
                ShowLog.log("live \(liveDeckName) slide \(lastLiveIndex + 1) build \(state) -> \(state - 1) of \(deck.buildCount(page: lastLiveIndex)) (back)")
                SlideTrackRecorder.record(.hold)
                syncLiveBackToPreviewIfNeeded(); reconcilePreviewStill()
                return
            }
        }
        liveEngine.previous()
        if liveEngine.currentIndex != lastLiveIndex { logLiveMove(); enterLivePage(liveEngine.currentIndex, forward: false); SlideTrackRecorder.recordPageEntered() }
        syncLiveBackToPreviewIfNeeded()
        checkTimerCue(forward: false)
    }

    func liveGoToFirst() {
        autoAdvanceTask?.cancel(); autoAdvanceTask = nil
        lastLiveIndex = liveEngine.currentIndex
        liveEngine.goToFirst()
        logLiveMove()
        enterLivePage(liveEngine.currentIndex, forward: true)
        SlideTrackRecorder.recordPageEntered()
        syncLiveBackToPreviewIfNeeded()
    }

    func liveGoToLast() {
        autoAdvanceTask?.cancel(); autoAdvanceTask = nil
        lastLiveIndex = liveEngine.currentIndex
        liveEngine.goToLast()
        logLiveMove()
        enterLivePage(liveEngine.currentIndex, forward: true)
        SlideTrackRecorder.recordPageEntered()
        syncLiveBackToPreviewIfNeeded()
    }

    func liveToggleBlack() {
        liveEngine.toggleBlack()
        ShowLog.log(liveEngine.isBlack ? "BLACK on" : "BLACK off")
        SlideTrackRecorder.record(.black)
        syncLiveBackToPreviewIfNeeded()
    }

    /// Jump the live output to a 1-based slide (reconciles clip playback).
    func liveJumpTo(page: Int) {
        autoAdvanceTask?.cancel(); autoAdvanceTask = nil
        lastLiveIndex = liveEngine.currentIndex
        liveEngine.jumpTo(page: page)
        logLiveMove()
        enterLivePage(liveEngine.currentIndex, forward: true)
        SlideTrackRecorder.recordPageEntered()
        syncLiveBackToPreviewIfNeeded()
    }

    /// Machine-readable state for the control server.
    var controlStateJSON: String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        }
        let decksJSON = decks.map { d in
            let errs = d.clipErrors.sorted { $0.key < $1.key }.map { "{\"slide\":\($0.key + 1),\"error\":\"\(esc($0.value))\"}" }.joined(separator: ",")
            return "{\"name\":\"\(esc(d.fileName))\",\"title\":\"\(esc(d.shownName))\",\"live\":\(d.id == liveDeckID),\"preview\":\(d.id == previewDeckID),\"slides\":\(d.pageCount),\"slide\":\(d.currentIndex + 1),\"clipErrors\":[\(errs)]}"
        }.joined(separator: ",")
        // Live clip telemetry so a loop or a stall can be MEASURED over the API.
        var clip = "null"
        if let p = liveEngine.currentPlayer {
            let t = p.currentTime().seconds
            let d = p.currentItem?.duration.seconds ?? .nan
            let loops = liveDeck?.loopsAt(page: liveEngine.currentIndex) ?? false
            let file = liveDeck?.clipName(of: p).map { "\"\(esc($0))\"" } ?? "null"
            // Audio telemetry (2026-09-16: "no sound in the video" after a V4
            // return): what the player would actually send to the output.
            let item = p.currentItem
            let audioTracks = item?.tracks.filter { $0.assetTrack?.mediaType == .audio } ?? []
            let enabled = audioTracks.filter(\.isEnabled).count
            let device = p.audioOutputDeviceUniqueID.map { "\"\(esc($0))\"" } ?? "null"
            clip = "{\"file\":\(file),\"time\":\(t.isFinite ? String(format: "%.2f", t) : "null"),\"duration\":\(d.isFinite ? String(format: "%.2f", d) : "null"),\"rate\":\(p.rate),\"loop\":\(loops),\"muted\":\(p.isMuted),\"volume\":\(p.volume),\"audioTracks\":\(audioTracks.count),\"audioTracksEnabled\":\(enabled),\"audioMix\":\(item?.audioMix != nil),\"outputDevice\":\(device),\"itemStatus\":\(item?.status.rawValue ?? -1)}"
        }
        return """
        {"liveDeck":"\(esc(liveDeckName))","slide":\(liveEngine.currentPage),"totalSlides":\(liveEngine.pageCount),"segment":\(liveSegment),"segments":\(liveSegmentsTotal),"build":\(liveBuild),"builds":\(liveBuildCount),"stateStill":\(liveDeck?.stateStillName(page: liveEngine.currentIndex, state: liveBuild).map { "\"\($0)\"" } ?? "null"),"stillShown":\(liveEngine.stateStill != nil),"black":\(liveEngine.isBlack),"isVideo":\(liveEngine.currentPageIsVideo),"clip":\(clip),"deckCount":\(decks.count),"decks":[\(decksJSON)]}
        """
    }

    private func syncLiveBackToPreviewIfNeeded() {
        guard !isSyncing else { return }
        guard let deck = liveDeck, !deck.isVideo || deck.isArcDeck else { return }
        isSyncing = true
        defer { isSyncing = false }

        deck.currentIndex = liveEngine.currentIndex
        deck.isBlack = liveEngine.isBlack
        deck.ensurePages(around: deck.currentIndex)
        syncCacheToLive(from: deck)
        if previewDeckID == liveDeckID {
            syncCacheToPreview(from: deck)
            syncDeckToEngine(deck, engine: previewEngine)
        }
    }

    // MARK: - Timer Cues

    /// The label of the currently active timer cue (shown in UI)
    private(set) var activeCueLabel: String = ""

    private func checkTimerCue(forward: Bool) {
        guard let deck = liveDeck else { return }
        let page = liveEngine.currentPage  // 1-based
        guard let cue = deck.cueFor(page: page) else { return }

        // Only fire on forward navigation to prevent re-triggering on back
        guard forward else { return }

        switch cue.action {
        case .startCountdown:
            timerEngine.stop()
            timerEngine.mode = .countDown
            timerEngine.countdownDuration = cue.duration
            timerEngine.reset()
            timerEngine.start()
            activeCueLabel = cue.label
        case .stop:
            timerEngine.stop()
            activeCueLabel = cue.label.isEmpty ? "BREAK" : cue.label
        }
    }

    func resetAll() {
        for deck in decks {
            deck.player?.pause()
            deck.cancelBuild()
        }
        decks.removeAll()
        previewDeckID = nil
        liveDeckID = nil
        allowSleep()
        previewEngine.unload()
        previewCache.clear()
        liveEngine.unload()
        liveCache.clear()
        SessionStore.clear()
    }

    // MARK: - V4 switch: silence, never pause

    /// Players the switch muted, so only THOSE come back: preview players are
    /// muted by design and must stay muted.
    private var silencedForSwitch: [AVPlayer] = []
    /// True between silenceForSwitch and restoreAfterSwitch: PowerPoint is on
    /// the program output and nothing of the deck may sound.
    private(set) var switchIsLive = false

    /// A deck opened while PowerPoint is live must not leak audio under the
    /// veil (audit R10); it joins the silenced set and comes back on return.
    private func muteIfSwitchIsLive(_ deck: Deck) {
        guard switchIsLive else { return }
        var players = deck.allClipPlayers
        if let p = deck.player { players.append(p) }
        for p in players where !p.isMuted {
            p.isMuted = true
            silencedForSwitch.append(p)
        }
    }

    /// Mute every player that is currently audible and keep it running: a
    /// looping clip has no transport to resume from, and a paused live player
    /// stayed paused after the return while the preview kept playing
    /// (2026-09-16).
    func silenceForSwitch() {
        var players: [AVPlayer] = []
        for deck in decks {
            if let p = deck.player { players.append(p) }
            players.append(contentsOf: deck.allClipPlayers)
        }
        silencedForSwitch = players.filter { !$0.isMuted }
        silencedForSwitch.forEach { $0.isMuted = true }
        switchIsLive = true
    }

    func restoreAfterSwitch() {
        silencedForSwitch.forEach { $0.isMuted = false }
        silencedForSwitch = []
        switchIsLive = false
    }

    func pauseAllVideos() {
        for deck in decks {
            deck.player?.pause()
            deck.allClipPlayers.forEach { $0.pause() }
        }
    }

    // MARK: - J/K/L Shuttle (live deck)

    private var shuttleRate: Float = 0

    var liveHasVideoPlayer: Bool { liveEngine.currentPlayer != nil }

    /// L: play forward; repeated presses accelerate 1→2→4→8x.
    func liveShuttleForward() {
        let next: Float = shuttleRate >= 1 ? min(shuttleRate * 2, 8) : 1
        setShuttle(next)
    }

    /// J: play reverse; repeated presses accelerate -1→-2→-4→-8x.
    func liveShuttleReverse() {
        let next: Float = shuttleRate <= -1 ? max(shuttleRate * 2, -8) : -1
        setShuttle(next)
    }

    /// K: stop (park).
    func liveShuttleStop() {
        setShuttle(0)
        liveEngine.currentPlayer?.pause()
    }

    private func setShuttle(_ rate: Float) {
        guard let player = liveEngine.currentPlayer, let item = player.currentItem else { return }
        var r = rate
        if r < 0 && !item.canPlayReverse { r = 0 }
        if r > 2 && !item.canPlayFastForward { r = 2 }
        if r < -2 && !item.canPlayFastReverse { r = -2 }
        shuttleRate = r
        player.rate = r
        SlideTrackRecorder.record(r == 0 ? .motionEnd : .motionStart) { $0.note = "shuttle \(r)x" }
    }

    // MARK: - Sleep Prevention

    /// Prevent display sleep and screensaver while a live deck is loaded.
    private func preventSleep() {
        guard !hasSleepAssertion else { return }
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "ARC Presenter Live Show" as CFString,
            &sleepAssertionID
        )
        if result == kIOReturnSuccess {
            hasSleepAssertion = true
            NSLog("ARC Presenter: Sleep prevention enabled — display will stay on.")
        }
    }

    private func allowSleep() {
        guard hasSleepAssertion else { return }
        IOPMAssertionRelease(sleepAssertionID)
        hasSleepAssertion = false
        NSLog("ARC Presenter: Sleep prevention released.")
    }

    func syncNavigationToLiveIfNeeded() {
        guard !isSyncing else { return }
        guard let deck = previewDeck, !deck.isVideo || deck.isArcDeck else { return }
        isSyncing = true
        defer { isSyncing = false }

        deck.currentIndex = previewEngine.currentIndex
        deck.isBlack = previewEngine.isBlack
        deck.ensurePages(around: deck.currentIndex)
        syncCacheToPreview(from: deck)

        if previewDeckID == liveDeckID {
            syncCacheToLive(from: deck)
            syncDeckToEngine(deck, engine: liveEngine)
        }
    }

    // MARK: Last frame for the Guard (crash cover)

    /// The live page, at the program display's pixel size, to `last-frame.bgra`
    /// so the Guard can hold it with a red border if this process dies.
    func storeLastFrame() {
        guard liveDeck != nil, let doc = liveEngine.pdfDocument else { return }
        let page = liveEngine.currentIndex
        let frame = ArcPresenterApp.sharedDisplayManager.programScreenFrame ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let scale = NSScreen.screens.first { $0.frame == frame }?.backingScaleFactor ?? 2
        let size = CGSize(width: frame.width * scale, height: frame.height * scale)
        Task.detached(priority: .utility) {
            guard let pdfPage = doc.page(at: page), let img = PageRenderCache.render(pdfPage, pixelSize: size) else { return }
            LastFrameStore.writeNow(img)
        }
    }

}

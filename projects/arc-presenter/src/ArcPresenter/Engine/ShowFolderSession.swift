//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import AppKit
import ARCShowFormat
import Observation

/// The open show folder in Presenter (V5, design section 1 and 4). One
/// folder is the show: its `show.json` names the items in run order, its
/// `arcdecks/` hold the versions, its `cues/` feed channel B, its `state/`
/// holds this app's session and its `logs/` this app's log. The folder is
/// watched: a late capture from ARC Capture shows up on the tab strip as a
/// marker (pending, updated, failed, or a newer version ready), never as a
/// silent change to a deck that may be live.
@MainActor
@Observable
final class ShowFolderSession {
    struct ItemState: Identifiable, Equatable {
        let id: String
        var title: String
        var kind: ShowSpec.ItemKind
        var status: ShowSpec.ItemStatus
        /// The version whose deck is loaded, if any.
        var loadedVersion: Int?
        /// The version show.json calls current.
        var currentVersion: Int?
        var deckID: UUID?
        var note: String?
        /// show.json's current version passed the verifier (Capture announces
        /// nothing else, and Presenter swaps to nothing else).
        var currentVerified = false
        /// Every file of show.json's current version is on this disk. iCloud
        /// lands show.json first and the deck's files up to a minute later
        /// (measured 2026-09-18: offered at +12 s, local at +81 s).
        var currentLocal = true
        var localFiles = 0
        var totalFiles = 0
        /// A newer version open as a twin tab beside the live one (STAGE).
        var stagedVersion: Int?
        var stagedDeckID: UUID?
        /// Older versions still open after a take, on their way out.
        var retiringDeckIDs: [UUID] = []
        var displayName: String { id == ShowSpec.showDeckID ? title : "\(id) \(title)" }      // the show deck goes by the show's name
        /// A verified newer version exists that is neither loaded nor staged.
        var newerVersionReady: Bool {
            guard currentVerified, currentLocal, let c = currentVersion, let l = loadedVersion else { return false }
            return c > l && stagedVersion != c
        }
        /// A verified newer version whose files are still arriving: shown, not offered.
        var newerVersionDownloading: Bool {
            guard currentVerified, !currentLocal, let c = currentVersion else { return false }
            return c > (loadedVersion ?? 0) && stagedVersion != c
        }
        var wantsAttention: Bool { status == .pending || status == .updated || status == .failed || newerVersionReady || newerVersionDownloading || stagedDeckID != nil }
    }

    /// What a tab is to its item: the version in use, a staged twin, or an
    /// older version retiring after a take.
    enum TabRole: Equatable { case primary, staged, retiring }

    enum UpdateResult: Equatable {
        /// Not live: the new version replaced the old one in its tab.
        case applied(version: Int)
        /// Live: the new version is a twin tab in preview, on the matched page.
        case staged(version: Int, match: VersionMatch.Result)
        /// Live: staged and taken in one.
        case swapped(version: Int, match: VersionMatch.Result)
        case refused(String)
    }

    private(set) var folder: URL?
    private(set) var spec: ShowSpec?
    private(set) var items: [ItemState] = []
    private(set) var lastSync: Date?
    private(set) var lastError: String?
    /// Capture's preflight rows, when the folder has reports/preflight.json.
    private(set) var preflightRows: [(label: String, ok: Bool, required: Bool, detail: String)] = []

    var isOpen: Bool { folder != nil }
    var name: String { spec?.name ?? "" }
    /// Items that want attention: pending, updated, failed, or a newer version.
    var attention: [ItemState] { items.filter(\.wantsAttention) }
    /// The header chip: the most urgent count only.
    var shortAttention: String {
        let newer = items.filter { $0.newerVersionReady || $0.stagedDeckID != nil }.count
        let pending = items.filter { $0.status == .pending || $0.status == .updated }.count
        let failed = items.filter { $0.status == .failed }.count
        let downloading = items.filter(\.newerVersionDownloading).count
        if failed > 0 { return "\(failed) FAILED" }
        if newer > 0 { return "\(newer) NEW" }
        if downloading > 0 { return "\(downloading) DOWNLOADING" }
        if pending > 0 { return "\(pending) CAPTURE" }
        return ""
    }
    var changesSummary: String {
        let newer = items.filter { $0.newerVersionReady || $0.stagedDeckID != nil }.count
        let pending = items.filter { $0.status == .pending || $0.status == .updated }.count
        let failed = items.filter { $0.status == .failed }.count
        var parts: [String] = []
        if newer > 0 { parts.append("\(newer) new version\(newer == 1 ? "" : "s")") }
        let downloading = items.filter(\.newerVersionDownloading).count
        if downloading > 0 { parts.append("\(downloading) downloading") }
        if pending > 0 { parts.append("\(pending) awaiting capture") }
        if failed > 0 { parts.append("\(failed) failed") }
        return parts.joined(separator: ", ")
    }

    private let deckManager: DeckManager
    private let displayManager: DisplayManager
    private let music: MusicEngine?
    /// Tests never touch the console's defaults (the remembered folder).
    private let persisting: Bool
    @ObservationIgnored private var watcher: DispatchSourceFileSystemObject?
    @ObservationIgnored private var arcdecksWatcher: DispatchSourceFileSystemObject?
    @ObservationIgnored private var showJSONWatcher: DispatchSourceFileSystemObject?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var lastShowJSONStamp: (mtime: Date, size: Int)?
    /// "id vN" whose files were seen local once: not walked again.
    @ObservationIgnored private var localVersions: Set<String> = []
    /// Seconds between looks at show.json's mtime. An in-place overwrite (scp,
    /// some shares) raises no vnode event on the folder; this catches it, and
    /// re-checks a version whose files are still downloading. Tests shorten it.
    @ObservationIgnored var pollInterval: TimeInterval = 2
    /// Are a version's files on this disk? Tests inject the answer.
    @ObservationIgnored var fileCheck: (URL) -> Materialization.Report = { Materialization.check($0) }
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var loading = false
    @ObservationIgnored private var resyncWanted = false
    @ObservationIgnored private var observingDecks = false
    @ObservationIgnored private var retireTasks: [UUID: Task<Void, Never>] = [:]
    /// How a staged twin was placed, by its deck, for the tab and the API.
    private(set) var matches: [UUID: VersionMatch.Result] = [:]
    /// "id vN" that would not open: never retried on its own (no log storm).
    @ObservationIgnored private var failedUpdates: Set<String> = []
    /// An older version stays this long after the take that replaced it.
    @ObservationIgnored var retireDelay: TimeInterval = 60
    /// Tests pin this; the console reads the preference.
    @ObservationIgnored var autoApplyOverride: Bool?
    private var autoApply: Bool { autoApplyOverride ?? UserPreferences.autoApplyDeckUpdates }

    static let rememberedKey = "openShowFolder"
    static var rememberedFolder: URL? {
        guard let p = UserDefaults.standard.string(forKey: rememberedKey), FileManager.default.fileExists(atPath: p) else { return nil }
        return URL(fileURLWithPath: p)
    }

    init(deckManager: DeckManager, displayManager: DisplayManager, music: MusicEngine?, persisting: Bool = !AppEnvironment.isTestHost) {
        self.deckManager = deckManager
        self.displayManager = displayManager
        self.music = music
        self.persisting = persisting
    }

    // MARK: Open / attach / close

    /// Point the session store at the folder's state BEFORE the launch restore,
    /// without loading anything: the restore does the loading from state/.
    func attach(folder: URL) {
        guard let s = try? ShowSpec.load(from: folder) else { return }
        self.folder = folder
        self.spec = s
        try? FileManager.default.createDirectory(at: folder.appendingPathComponent(ShowSpec.Folder.state.rawValue), withIntermediateDirectories: true)
        SessionStore.fileURLOverride = folder.appendingPathComponent("state/session.json")
        if persisting { UserDefaults.standard.set(folder.path, forKey: Self.rememberedKey) }
        ShowLog.log("show attached: \(s.name) (\(folder.path)); state and logs live in the folder")
        SlideTrackRecorder.start(showFolder: folder, show: s.name)
        NotificationCenter.default.post(name: .showFolderAttached, object: folder)   // the rundown follows the folder (phase 1)
        watch()
        startPolling()
        if !observingDecks { observingDecks = true; observeDecks(); observeLiveSlide() }
        // The launch restore loads the decks from state/ over the next ~3 s;
        // reconcile once it has, so the tabs carry their names and markers.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            _ = await self?.sync(loadMissing: true)
            self?.readPreflight()
        }
    }

    /// OPEN SHOW: outputs, every ready item's current deck in run order, cues.
    /// Returns the number of decks opened. `restoreState` reopens the folder's
    /// own state/session.json when present (a laptop swap carries positions).
    @discardableResult
    func open(folder: URL, restoreState: Bool = true, timer: TimerEngine? = nil) async -> Int {
        guard let s = try? ShowSpec.load(from: folder) else {
            lastError = "no readable show.json in \(folder.lastPathComponent)"
            ShowLog.error("OPEN SHOW: \(lastError!)")
            return 0
        }
        if self.folder != folder { close() }
        attach(folder: folder)
        ShowLog.log("OPEN SHOW \(s.name)")
        // Outputs from the profile when the app has none yet.
        if let outs = s.outputs, displayManager.programScreenID == nil {
            displayManager.detectScreens()
            for (route, output) in [(outs.program, OutputType.program), (outs.confidence, OutputType.confidence)] {
                guard let route else { continue }
                if let scr = displayManager.availableScreens.first(where: { $0.uuid == route.displayUUID }) ?? displayManager.availableScreens.first(where: { $0.localizedName == route.displayName }) {
                    displayManager.assign(screen: scr, to: output); displayManager.openOutput(output)
                } else { ShowLog.log("show: \(output.shortLabel) display \(route.displayName) not present") }
            }
        }
        let opened = await sync(loadMissing: true)
        if restoreState, let timer, FileManager.default.fileExists(atPath: folder.appendingPathComponent("state/session.json").path), deckManager.decks.isEmpty {
            SessionStore.restore(ShowContext(deckManager: deckManager, timer: timer, displayManager: displayManager, music: music))
        }
        for cue in s.cues { _ = music?.b.addCues(from: folder.appendingPathComponent(cue)) }
        readPreflight()
        ShowLog.log("show \(s.name): \(opened) deck(s) opened, \(s.cues.count) cue(s)")
        return opened
    }

    func close() {
        guard let folder else { return }
        ShowLog.core.copy(into: folder.appendingPathComponent(ShowSpec.Folder.logs.rawValue))
        watcher?.cancel(); watcher = nil
        arcdecksWatcher?.cancel(); arcdecksWatcher = nil
        showJSONWatcher?.cancel(); showJSONWatcher = nil
        pollTask?.cancel(); pollTask = nil
        lastShowJSONStamp = nil; localVersions = []
        SessionStore.fileURLOverride = nil
        if persisting { UserDefaults.standard.removeObject(forKey: Self.rememberedKey) }
        ShowLog.log("show closed: \(spec?.name ?? "")")
        SlideTrackRecorder.start(showFolder: nil, show: nil)
        NotificationCenter.default.post(name: .showFolderClosed, object: nil)
        retireTasks.values.forEach { $0.cancel() }; retireTasks = [:]
        matches = [:]; failedUpdates = []
        self.folder = nil; spec = nil; items = []; preflightRows = []
    }

    /// At quit: the log goes into the folder too.
    func copyLogIntoFolder() {
        guard let folder else { return }
        ShowLog.core.copy(into: folder.appendingPathComponent(ShowSpec.Folder.logs.rawValue))
    }

    // MARK: Sync with show.json

    /// Re-read show.json and reconcile: new ready items get their deck opened
    /// at their run-order position (when `loadMissing`); statuses land on the
    /// tabs; a newer verified version replaces a deck that is NOT live on its
    /// own (when the preference allows) and is only MARKED on the live one,
    /// where the swap is the operator's (STAGE / SWAP). Returns decks opened.
    @discardableResult
    func sync(loadMissing: Bool = true) async -> Int {
        guard folder != nil else { return 0 }
        guard !loading else { resyncWanted = true; return 0 }
        loading = true
        var opened = await reconcile(loadMissing: loadMissing)
        loading = false
        if autoApply {
            for st in items where st.newerVersionReady && st.deckID != deckManager.liveDeckID
                && !failedUpdates.contains("\(st.id) v\(st.currentVersion ?? 0)") {
                _ = await update(itemID: st.id, automatic: true)
            }
        }
        if resyncWanted { resyncWanted = false; opened += await sync(loadMissing: loadMissing) }
        return opened
    }

    /// One pass over show.json. What each open deck IS to its item is derived
    /// from two facts only, which versions are open and which deck is live,
    /// so a relaunch (the session file reopens decks by path) reads the same:
    /// the live version is the one in use, a newer open one is its staged
    /// twin, an older open one is retiring; with none live the newest is in
    /// use and the rest go at once.
    private func reconcile(loadMissing: Bool) async -> Int {
        guard let folder, let s = try? ShowSpec.load(from: folder) else { return 0 }
        spec = s
        var opened = 0
        var states: [ItemState] = []
        var order: [UUID] = []
        var retireNow: [(deck: Deck, heir: UUID)] = []
        let size = displayManager.externalScreenSize ?? CGSize(width: 1920, height: 1080)
        // A show with a show deck is ONE tab (decided 2026-09-17: one show deck, not individual
        // presentations, opened in Presenter); without one, a tab per item. The show deck is versioned like an item, so
        // everything below (in use, staged twin, retiring, the swap) applies to it unchanged.
        let roster = s.roster
        if s.showDeck?.currentVersion != nil, spec?.showDeck?.currentVersion == nil, items.count > 1 {
            ShowLog.log("show: \(s.name) now has a show deck: it is what opens from here on; the presentation tabs close (a live one stays until it is not)")
        }
        for item in roster {
            var st = ItemState(id: item.id, title: item.title, kind: item.kind, status: item.status, loadedVersion: nil,
                               currentVersion: item.current, deckID: nil, note: item.notes)
            st.currentVerified = item.currentVersion?.verified ?? false
            if let cur = item.currentVersion, cur.verified {
                let key = "\(item.id) v\(cur.number)"
                if localVersions.contains(key) { st.currentLocal = true } else {
                    let url = folder.appendingPathComponent(cur.arcdeck), check = fileCheck
                    let report = await Task.detached { check(url) }.value
                    st.currentLocal = report.isLocal; st.localFiles = report.local; st.totalFiles = report.total
                    if report.isLocal { localVersions.insert(key) }
                    let before = items.first { $0.id == item.id }
                    if !report.isLocal, before?.currentVersion != cur.number || before?.currentLocal != false {
                        ShowLog.log("show: \(st.displayName) v\(cur.number) downloading (\(report.local) of \(report.total) files here)")
                    } else if report.isLocal, before?.currentVersion == cur.number, before?.currentLocal == false {
                        ShowLog.log("show: \(st.displayName) v\(cur.number) is on disk (\(report.total) files)")
                    }
                }
            }
            // This item's open versions (by deck path), oldest first.
            var open: [(n: Int, deck: Deck)] = item.versions.compactMap { v in
                let url = folder.appendingPathComponent(v.arcdeck).standardizedFileURL
                return deckManager.decks.first { $0.url.standardizedFileURL == url }.map { (v.number, $0) }
            }.sorted { $0.n < $1.n }
            if open.isEmpty, loadMissing, let cur = item.currentVersion, cur.verified, st.currentLocal {
                let url = folder.appendingPathComponent(cur.arcdeck)
                if let deck = await deckManager.loadDeck(url: url, targetSize: size, kind: .arcdeck) {
                    open = [(cur.number, deck)]
                    opened += 1
                    ShowLog.log("show: opened \(st.displayName) v\(cur.number)")
                } else {
                    st.note = "could not open \(cur.arcdeck)"
                    ShowLog.error("show: could not open \(cur.arcdeck)")
                }
            }
            if let inUse = open.first(where: { $0.deck.id == deckManager.liveDeckID }) ?? open.last {
                let isLive = inUse.deck.id == deckManager.liveDeckID
                st.loadedVersion = inUse.n; st.deckID = inUse.deck.id
                retireTasks.removeValue(forKey: inUse.deck.id)?.cancel()
                let staged = isLive ? open.last(where: { $0.n > inUse.n }) : nil
                st.stagedVersion = staged?.n; st.stagedDeckID = staged?.deck.id
                for other in open where other.deck.id != inUse.deck.id && other.deck.id != staged?.deck.id {
                    if isLive { st.retiringDeckIDs.append(other.deck.id); scheduleRetire(other.deck.id, heir: inUse.deck.id) }
                    else { retireNow.append((other.deck, inUse.deck.id)) }
                }
                for o in open {
                    o.deck.displayName = open.count > 1 ? "\(st.displayName) v\(o.n)" : st.displayName
                    if !retireNow.contains(where: { $0.deck.id == o.deck.id }) { order.append(o.deck.id) }
                }
            }
            if st.newerVersionReady, st != items.first(where: { $0.id == st.id }) {
                ShowLog.log("show: \(st.displayName) v\(st.currentVersion ?? 0) is ready (v\(st.loadedVersion ?? 0) \(st.deckID == deckManager.liveDeckID ? "LIVE" : "loaded"))")
            }
            states.append(st)
        }
        for (deck, heir) in retireNow { retire(deck.id, heir: heir, reason: "its item is no longer live") }
        if s.showDeck?.currentVersion != nil, let showTab = states.first?.deckID {
            for deck in deckManager.decks where deck.id != deckManager.liveDeckID && Self.isInsideTheShowDeck(deck.url) {
                retire(deck.id, heir: showTab, reason: "it is inside the show deck")
            }
        }
        // Tabs in run order: show items first, in show order, an item's
        // versions oldest first so a take never reshuffles the strip.
        deckManager.setDeckOrder(order)
        matches = matches.filter { id, _ in deckManager.decks.contains { $0.id == id } }
        let changed = states != items
        items = states
        lastSync = Date()
        if changed, !attention.isEmpty { ShowLog.log("show: attention: \(changesSummary)") }
        // A twin found staged (a relaunch reopens it by path) has no match on
        // record and may sit anywhere: place it against the live slide.
        followLive()
        return opened
    }

    // MARK: Version swap (step 5, design 4.3): never yank a live deck

    /// Bring an item to show.json's current version. NOT live: the new
    /// version replaces the old one in its tab, on the matching page. LIVE:
    /// nothing on the program output changes; the new version opens as a twin
    /// tab in preview on the page that matches the live slide (STAGE) and the
    /// operator takes it with the ordinary TAKE, or `take` does both (SWAP).
    /// `itemID` nil = the live deck's item.
    @discardableResult
    func update(itemID: String? = nil, take: Bool = false, automatic: Bool = false) async -> UpdateResult {
        func refuse(_ why: String) -> UpdateResult {
            if !automatic { ShowLog.log("show: update refused: \(why)") }
            return .refused(why)
        }
        let deadline = Date().addingTimeInterval(15)
        while loading, Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        guard !loading else { return refuse("the show folder is still loading") }
        guard let folder, let spec else { return refuse("no show folder is open") }
        guard let st = items.first(where: { itemID != nil ? $0.id == itemID : ($0.deckID == deckManager.liveDeckID && $0.deckID != nil) }) else {
            return refuse(itemID.map { "no item \($0) in this show" } ?? "the live deck is not an item of this show")
        }
        if !st.currentLocal, let cur = Self.item(st.id, in: spec)?.currentVersion, cur.number > (st.loadedVersion ?? 0) {
            return refuse("\(st.displayName) v\(cur.number) is still downloading (\(st.localFiles) of \(st.totalFiles) files here)")
        }
        guard let item = Self.item(st.id, in: spec), let cur = item.currentVersion, cur.verified,
              let loadedN = st.loadedVersion, cur.number > loadedN,
              let old = deckManager.decks.first(where: { $0.id == st.deckID }) else {
            return refuse("\(st.displayName) has no verified newer version")
        }
        loading = true
        defer { loading = false }
        let key = "\(st.id) v\(cur.number)"
        let wasLive = old.id == deckManager.liveDeckID

        // Already staged: SWAP takes it, STAGE brings it back to preview.
        if let twinID = st.stagedDeckID, st.stagedVersion == cur.number, let match = matches[twinID] {
            deckManager.previewDeckSwitch(to: twinID)
            guard take else { return .staged(version: cur.number, match: match) }
            deckManager.take()
            ShowLog.log("show: SWAP \(st.displayName) v\(loadedN) -> v\(cur.number), \(match.label)")
            _ = await reconcile(loadMissing: false)
            return .swapped(version: cur.number, match: match)
        }

        let size = displayManager.externalScreenSize ?? CGSize(width: 1920, height: 1080)
        let previewBefore = deckManager.previewDeckID
        guard let fresh = await deckManager.loadDeck(url: folder.appendingPathComponent(cur.arcdeck), targetSize: size, kind: .arcdeck) else {
            failedUpdates.insert(key)
            ShowLog.error("show: \(st.displayName) v\(cur.number) would not open (\(cur.arcdeck)); v\(loadedN) stays")
            return .refused("v\(cur.number) would not open")
        }
        let rendered = Date().addingTimeInterval(10)
        while fresh.isLoading, Date() < rendered { try? await Task.sleep(for: .milliseconds(50)) }

        // The page that matches where the old version stands NOW (the wait
        // above may have seen a click).
        let page = deckManager.effectiveIndex(of: old)
        let match = VersionMatch.match(page: page, oldHashes: item.versions.first { $0.number == loadedN }?.slideHashes,
                                       newHashes: cur.slideHashes, oldSlides: old.sourceSlides, newSlides: fresh.sourceSlides,
                                       newPageCount: fresh.pageCount)
        fresh.currentIndex = match.page
        fresh.isBlack = deckManager.effectiveBlack(of: old)
        fresh.timerCues = old.timerCues.map { cue in
            var c = cue
            c.slideNumber = VersionMatch.match(page: cue.slideNumber - 1, oldHashes: item.versions.first { $0.number == loadedN }?.slideHashes,
                                               newHashes: cur.slideHashes, oldSlides: old.sourceSlides, newSlides: fresh.sourceSlides,
                                               newPageCount: fresh.pageCount).page + 1
            return c
        }
        fresh.displayName = st.displayName
        matches[fresh.id] = match

        let result: UpdateResult
        if wasLive, old.id == deckManager.liveDeckID {
            deckManager.previewDeckSwitch(to: fresh.id)
            if take {
                deckManager.take()
                ShowLog.log("show: SWAP \(st.displayName) v\(loadedN) -> v\(cur.number) from slide \(page + 1) to \(match.label)")
                result = .swapped(version: cur.number, match: match)
            } else {
                ShowLog.log("show: STAGE \(st.displayName) v\(cur.number) beside the live v\(loadedN) (slide \(page + 1)) at \(match.label); TAKE when ready")
                result = .staged(version: cur.number, match: match)
            }
        } else {
            // In place: same tab position (the order pass), preview kept.
            if previewBefore == old.id { deckManager.previewDeckSwitch(to: fresh.id) }
            retire(old.id, heir: fresh.id, reason: "replaced by v\(cur.number)")
            ShowLog.log("show: \(automatic ? "auto-swap" : "swap") \(st.displayName) v\(loadedN) -> v\(cur.number) (not live), \(match.label)")
            result = .applied(version: cur.number)
        }
        _ = await reconcile(loadMissing: false)
        return result
    }

    /// Close an older version's tab. Never the live deck: a deck the operator
    /// took back is in use again, and the next pass reads it that way.
    private func retire(_ id: UUID, heir: UUID, reason: String) {
        retireTasks.removeValue(forKey: id)?.cancel()
        guard id != deckManager.liveDeckID, let deck = deckManager.decks.first(where: { $0.id == id }) else { return }
        if deckManager.previewDeckID == id, deckManager.decks.contains(where: { $0.id == heir }) { deckManager.previewDeckSwitch(to: heir) }
        ShowLog.log("show: retired \(deck.shownName) (\(reason))")
        deckManager.removeDeck(deckID: id)
        matches[id] = nil
    }

    private func scheduleRetire(_ id: UUID, heir: UUID) {
        guard retireTasks[id] == nil else { return }
        let delay = retireDelay
        retireTasks[id] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.retireTasks[id] = nil
            self.retire(id, heir: heir, reason: "\(Int(delay)) s after the take")
        }
    }

    /// A take, a closed tab or a new deck changes what each tab is to its item.
    private func observeDecks() {
        withObservationTracking {
            _ = deckManager.liveDeckID; _ = deckManager.decks.count
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.isOpen else { self.observingDecks = false; return }
                self.observeDecks()
                _ = await self.sync(loadMissing: false)
            }
        }
    }

    /// The presenter keeps clicking while a twin is staged. A twin left where
    /// it was staged would TAKE the room back a slide (drill B, 2026-09-17),
    /// so it is re-matched on every live slide change: the preview always
    /// shows where a TAKE would land NOW. An operator's nudge of the twin
    /// therefore holds until the next live click. No disk on this path: the
    /// live slide is the clicker's.
    private func observeLiveSlide() {
        withObservationTracking {
            _ = deckManager.liveEngine.currentIndex; _ = deckManager.liveEngine.isBlack
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isOpen else { return }
                self.observeLiveSlide()
                self.followLive()
            }
        }
    }

    private func followLive() {
        guard let spec, let st = items.first(where: { $0.deckID == deckManager.liveDeckID && $0.stagedDeckID != nil }),
              let item = Self.item(st.id, in: spec),
              let old = deckManager.decks.first(where: { $0.id == st.deckID }),
              let twin = deckManager.decks.first(where: { $0.id == st.stagedDeckID }) else { return }
        let page = deckManager.liveEngine.currentIndex
        let match = VersionMatch.match(page: page, oldHashes: item.versions.first { $0.number == st.loadedVersion }?.slideHashes,
                                       newHashes: item.versions.first { $0.number == st.stagedVersion }?.slideHashes,
                                       oldSlides: old.sourceSlides, newSlides: twin.sourceSlides, newPageCount: twin.pageCount)
        let black = deckManager.liveEngine.isBlack
        guard matches[twin.id] != match || deckManager.effectiveIndex(of: twin) != match.page || deckManager.effectiveBlack(of: twin) != black else { return }
        deckManager.park(deckID: twin.id, at: match.page, black: black)
        matches[twin.id] = match
        ShowLog.log("show: staged \(st.displayName) v\(st.stagedVersion ?? 0) follows live slide \(page + 1) -> \(match.label)")
    }

    /// A deck that is one PRESENTATION of a show folder that has a show deck: it plays from inside the show deck,
    /// not from a tab of its own. Read from the deck's own path (…/<show>/arcdecks/<id> <title>.vN.arcdeck beside
    /// a show.json with a showDeck), so the launch restore can ask before any session is attached.
    static func isInsideTheShowDeck(_ deck: URL) -> Bool {
        let arcdecks = deck.deletingLastPathComponent()
        guard arcdecks.lastPathComponent == ShowSpec.Folder.arcdecks.rawValue,
              let spec = try? ShowSpec.load(from: arcdecks.deletingLastPathComponent()), spec.showDeck?.currentVersion != nil else { return false }
        let rel = "\(ShowSpec.Folder.arcdecks.rawValue)/\(deck.lastPathComponent)"
        return spec.items.contains { $0.versions.contains { $0.arcdeck == rel } }
    }

    /// An item by id: a presentation, or the show deck.
    static func item(_ id: String, in spec: ShowSpec) -> ShowSpec.Item? {
        spec.items.first { $0.id == id } ?? (spec.showDeck?.id == id ? spec.showDeck : nil)
    }

    /// The tab's item and what the tab is to it.
    func role(for deck: Deck) -> (item: ItemState, role: TabRole)? {
        for st in items {
            if st.deckID == deck.id { return (st, .primary) }
            if st.stagedDeckID == deck.id { return (st, .staged) }
            if st.retiringDeckIDs.contains(deck.id) { return (st, .retiring) }
        }
        return nil
    }

    func state(for deck: Deck) -> ItemState? { items.first { $0.deckID == deck.id } }

    private func readPreflight() {
        guard let folder, let data = try? Data(contentsOf: folder.appendingPathComponent("reports/preflight.json")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = obj["rows"] as? [[String: Any]] else { preflightRows = []; return }
        preflightRows = rows.compactMap { r in
            guard let label = r["label"] as? String, let ok = r["ok"] as? Bool else { return nil }
            return (label, ok, (r["required"] as? Bool) ?? false, (r["detail"] as? String) ?? "")
        }
    }

    // MARK: Watch

    private func watch() {
        watcher?.cancel(); arcdecksWatcher?.cancel()
        guard let folder else { return }
        func source(_ url: URL) -> DispatchSourceFileSystemObject? {
            let fd = Darwin.open(url.path, O_EVTONLY)
            guard fd >= 0 else { return nil }
            let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend], queue: .main)
            src.setEventHandler { [weak self] in self?.scheduleSync() }
            src.setCancelHandler { _ = Darwin.close(fd) }
            src.resume()
            return src
        }
        watcher = source(folder)
        arcdecksWatcher = source(folder.appendingPathComponent(ShowSpec.Folder.arcdecks.rawValue))
        watchShowJSON()
    }

    /// show.json's own vnode. An in-place overwrite (scp, some shares) changes
    /// the file, not the folder, so the folder watch never fires for it (field,
    /// 2026-09-18: 80 s of nothing). An atomic write replaces the vnode and
    /// arrives as .rename/.delete: re-arm on the new one.
    private func watchShowJSON() {
        showJSONWatcher?.cancel(); showJSONWatcher = nil
        guard let folder else { return }
        let fd = Darwin.open(folder.appendingPathComponent("show.json").path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .rename, .delete], queue: .main)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let ev = src.data
            self.scheduleSync()
            if ev.contains(.rename) || ev.contains(.delete) {
                Task { @MainActor [weak self] in try? await Task.sleep(for: .seconds(1)); self?.watchShowJSON() }
            }
        }
        src.setCancelHandler { _ = Darwin.close(fd) }
        src.resume()
        showJSONWatcher = src
    }

    /// The fallback that needs no event: show.json's mtime and size every
    /// `pollInterval` seconds, and a resync while any version's files are
    /// still arriving, so DOWNLOADING turns into READY on its own.
    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let interval = self?.pollInterval ?? 2
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled, let self, let folder = self.folder else { return }
                let path = folder.appendingPathComponent("show.json").path
                if let a = try? FileManager.default.attributesOfItem(atPath: path),
                   let m = a[.modificationDate] as? Date, let size = (a[.size] as? NSNumber)?.intValue {
                    if let last = self.lastShowJSONStamp, last.mtime != m || last.size != size { self.scheduleSync() }
                    self.lastShowJSONStamp = (m, size)
                }
                if self.items.contains(where: { !$0.currentLocal }) { self.scheduleSync() }
            }
        }
    }

    private func scheduleSync() {
        syncTask?.cancel()
        syncTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            _ = await self?.sync(loadMissing: true)
            self?.readPreflight()
        }
    }

    // MARK: Control API

    var json: String {
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        guard let folder, let spec else { return "{\"open\":false}" }
        let rows = items.map { i -> String in
            let live = i.deckID != nil && i.deckID == deckManager.liveDeckID
            var match = "null"
            if let m = i.stagedDeckID.flatMap({ matches[$0] }) { match = "{\"slide\":\(m.page + 1),\"basis\":\"\(m.basis.rawValue)\"}" }
            return "{\"id\":\"\(esc(i.id))\",\"title\":\"\(esc(i.title))\",\"status\":\"\(i.status.rawValue)\",\"loaded\":\(i.loadedVersion.map(String.init) ?? "null"),\"current\":\(i.currentVersion.map(String.init) ?? "null"),\"newerReady\":\(i.newerVersionReady),\"downloading\":\(i.newerVersionDownloading ? "\"\(i.localFiles)/\(i.totalFiles)\"" : "null"),\"live\":\(live),\"staged\":\(i.stagedVersion.map(String.init) ?? "null"),\"stagedMatch\":\(match),\"retiring\":\(i.retiringDeckIDs.count)}"
        }.joined(separator: ",")
        return "{\"open\":true,\"name\":\"\(esc(spec.name))\",\"folder\":\"\(esc(folder.path))\",\"attention\":\"\(esc(changesSummary))\",\"items\":[\(rows)]}"
    }
}

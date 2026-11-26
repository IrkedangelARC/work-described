//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import AppKit
import PDFKit
import AVFoundation
import ARCShowFormat

/// A show folder (V3, design: arc-presenter/docs/DESIGN_show_folder.md):
/// `show.json` at the root, sources in `decks/`, one versioned .arcdeck per
/// item in `arcdecks/`, reports, logs, state. This is the operator's unit:
/// copy the folder to another Mac and the show plays there.
///
/// The store scans `decks/` into items in run order (file-name order, as the
/// builder always sorted), keeps a ledger per item (source hash, per-slide
/// hashes, versions), captures pending and updated items into NEW versions
/// (never overwriting one that may be live), verifies each before it is
/// announced, watches the folder for late drops, runs the preflight, and
/// hands the folder to Presenter.
@MainActor
@Observable
final class ShowFolderStore {
    let folder: URL
    private(set) var spec: ShowSpec
    private(set) var log: [String] = []
    private(set) var busy = false
    /// ARC Grab's downloads of the online videos slides link to, `state/grabs/<id>.mp4` (OnlineVideo.swift): fetched once per show.
    var grabsURL: URL { folder.appendingPathComponent("state/grabs", isDirectory: true) }
    /// The review queue, `state/review.json` (docs/PLAN_review_queue.md).
    var review = ReviewQueue()
    private(set) var status = ""
    private(set) var placeholders: [String] = []
    private(set) var preflightRows: [PreflightRow] = []
    private(set) var preflightRanAt: Date?
    /// The capture running right now (for the monitor).
    private(set) var currentSession: CaptureSession?
    /// Item ids captured this session, for the log pane.
    private(set) var lastCaptured: [String] = []

    @ObservationIgnored private var watcher: DispatchSourceFileSystemObject?
    @ObservationIgnored private var watchFD: Int32 = -1
    @ObservationIgnored private var rescanTask: Task<Void, Never>?
    /// A linked source folder (ShowFolder+Sources.swift): what is mirrored into decks/, and the poll that keeps it so.
    var sourceLedger = SourceFolder.Ledger()
    private(set) var syncing = false
    var lastSourceSync: Date?
    @ObservationIgnored var sourcePoll: Task<Void, Never>?
    func setSyncing(_ on: Bool) { syncing = on }
    func setStatus(_ text: String) { status = text }

    /// What is running RIGHT NOW, for the ACTIVITY panel: which step, which item of how many, since when.
    struct Activity: Equatable {
        var step: ShowPipeline.Step
        var title: String
        var detail: String = ""
        var index = 0
        var count = 0
        var started = Date()
    }
    private(set) var activity: Activity?
    func setActivity(_ a: Activity?) { activity = a }
    /// What the linked source holds, as the TD confirms it (ShowFolder+Pipeline.swift).
    var assessment: SourceAssessment?
    /// STOP: the chain ends after the item it is on. A capture is never cut in the middle of a deck.
    var stopRequested = false
    /// Wall clock for ONE item. A show run had no ceiling of any kind: the
    /// 900 s deadline lives only in the single-deck `--headless --in` path
    /// (HeadlessRunner), so one slide that never settled held 33 other items
    /// until somebody noticed (ARC Test Show 02, 2026-09-20). Matches that
    /// deadline. It is a backstop, not the fix: the session has its own
    /// ceilings now, and this is what catches whatever they do not.
    var itemTimeout: TimeInterval = 900
    /// What AUTO CAPTURE is waiting for, for the ACTIVITY panel ("hands off for 38 s more").
    var autoNote = ""
    /// Width / height of each item's source, once it is in decks/ (item id -> aspect).
    var aspects: [String: Double] = [:]
    var onLog: ((String) -> Void)?

    static let lastFolderKey = "lastShowFolderV3"
    /// Documents/ARC Shows (2026-09-16). Documents is iCloud Drive on
    /// most of the fleet, hence `pin()`.
    nonisolated static var defaultParent: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/ARC Shows", isDirectory: true)
    }

    struct PreflightRow: Codable, Identifiable {
        var id: String
        var label: String
        var ok: Bool
        var required: Bool
        var detail: String
    }

    // MARK: Open / create

    init(folder: URL) throws {
        self.folder = folder
        review = ReviewQueue.load(from: folder)
        if FileManager.default.fileExists(atPath: ShowSpec.url(in: folder).path) {
            spec = try ShowSpec.load(from: folder)
        } else {
            // A plain folder becomes a show folder.
            _ = try ShowSpec.createShowFolder(named: folder.lastPathComponent, date: nil, under: folder.deletingLastPathComponent())
            spec = try ShowSpec.load(from: folder)
        }
        if !AppEnvironment.isTestHost { UserDefaults.standard.set(folder.path, forKey: Self.lastFolderKey) }   // a test's temp show is not the TD's last show
        DebugLog.log("Show", "open \(folder.path): \(spec.items.count) item(s)")
        pin()
        rescan()
        watch()
        loadSources()
    }

    static func create(name: String, date: String?, under parent: URL = defaultParent) throws -> ShowFolderStore {
        let folder = try ShowSpec.createShowFolder(named: name, date: date, under: parent)
        return try ShowFolderStore(folder: folder)
    }

    /// The show the SHOW tab has open, for the REVIEW tab (one show at a time).
    static var current: ShowFolderStore? { didSet { NotificationCenter.default.post(name: currentChanged, object: nil) } }
    static let currentChanged = Notification.Name("ARCCaptureCurrentShowChanged")

    static func restoreLast() -> ShowFolderStore? {
        guard let p = UserDefaults.standard.string(forKey: lastFolderKey), FileManager.default.fileExists(atPath: p) else { return nil }
        return try? ShowFolderStore(folder: URL(fileURLWithPath: p))
    }

    deinit {
        watcher?.cancel()
        sourcePoll?.cancel()
    }

    // MARK: Paths

    func sub(_ f: ShowSpec.Folder) -> URL { folder.appendingPathComponent(f.rawValue, isDirectory: true) }
    func url(of item: ShowSpec.Item) -> URL {
        item.source.hasPrefix("http") ? URL(string: item.source)! : folder.appendingPathComponent(item.source)
    }
    func arcdeckURL(_ v: ShowSpec.Version) -> URL { folder.appendingPathComponent(v.arcdeck) }

    /// When each log line was said (the ACTIVITY panel shows the time beside it).
    private(set) var logTimes: [Date] = []
    func say(_ line: String) {
        log.append(line); logTimes.append(Date())
        if log.count > 600 { log.removeFirst(200); logTimes.removeFirst(200) }
        onLog?(line)
        DebugLog.log("Show", line)
    }

    private func save() {
        do { try spec.write(to: folder) } catch { say("show.json could not be written: \(error.localizedDescription)") }
    }

    // MARK: Items from decks/

    static let deckExt = ["pptx", "ppt", "pptm", "key"], linkExt = ["webloc", "url"], pdfExt = ["pdf"]
    static let imageExt = ["png", "jpg", "jpeg", "heic", "tif", "tiff"], movieExt = ["mp4", "mov", "m4v"]

    /// "1.06 Smith.pptx" -> ("1.06", "Smith"); "Keynote.key" -> ("Keynote", "Keynote").
    nonisolated static func itemID(from fileName: String) -> (id: String, title: String) {
        let stem = (fileName as NSString).deletingPathExtension
        let pattern = try! NSRegularExpression(pattern: #"^(\d+(?:\.\d+)*)[\s_\-]+(.+)$"#)
        if let m = pattern.firstMatch(in: stem, range: NSRange(stem.startIndex..., in: stem)),
           let idR = Range(m.range(at: 1), in: stem), let tR = Range(m.range(at: 2), in: stem) {
            return (String(stem[idR]), String(stem[tR]).trimmingCharacters(in: .whitespaces))
        }
        return (stem, stem)
    }

    /// A Google Slides item's source hash: its URL, plus the deck's modified date when the link file carries one
    /// (a link mirrored from a Drive folder does). MEASURED 2026-09-17: Drive for Desktop sets a .gslides pointer's
    /// modified date to the deck's last edit (the 174 bytes do not change), and it landed 3 s after the edit.
    /// A hand-made .webloc has no date and hashes as it always did.
    nonisolated static func linkHash(source: String, linkFile: String?) -> String {
        let revision = linkFile?.split(whereSeparator: \.isNewline).first { $0.hasPrefix("Modified=") }
        return SlideHasher.hex(Data((revision.map { source + "\n" + $0 } ?? source).utf8))
    }

    /// The hash a capture records for an item, THE SAME ONE rescan compares against. Two sites computed it
    /// and drifted on 2026-09-17: rescan learned the link file's date, the capture still hashed the bare URL,
    /// and a Google deck read "source changed after v1" seconds after it was captured (the preflight caught it).
    func sourceHash(of item: ShowSpec.Item) -> String? {
        guard item.kind == .googleSlides else { return SlideHasher.fileHash(url(of: item)) }
        return Self.linkHash(source: item.source, linkFile: linkFile(of: item).flatMap { try? String(contentsOf: $0, encoding: .utf8) })
    }

    /// The link file in `decks/` a Google Slides item came from (its `source` is the URL, not the file).
    func linkFile(of item: ShowSpec.Item) -> URL? {
        let decks = sub(.decks)
        return ((try? FileManager.default.contentsOfDirectory(atPath: decks.path)) ?? [])
            .filter { !$0.hasPrefix(".") && Self.itemID(from: $0).id == item.id }
            .map { decks.appendingPathComponent($0) }
            .first { Self.kind(of: $0) == .googleSlides }
    }

    nonisolated static func kind(of url: URL) -> ShowSpec.ItemKind? {
        let e = url.pathExtension.lowercased()
        if e == "key" { return .keynote }
        if deckExt.contains(e) { return .powerpoint }
        if linkExt.contains(e) { return .googleSlides }
        if pdfExt.contains(e) { return .pdf }
        if imageExt.contains(e) { return .image }
        if movieExt.contains(e) { return .movie }
        if e == "arcdeck" { return .arcdeck }
        return nil
    }

    /// Read `decks/`, add new items, mark changed sources `updated`, keep the ledger.
    func rescan() {
        let fm = FileManager.default
        let decks = sub(.decks)
        let names = ((try? fm.contentsOfDirectory(atPath: decks.path)) ?? [])
            .filter { !$0.hasPrefix(".") && !$0.hasPrefix("~$") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        var seen = Set<String>()
        var changed = false
        for name in names {
            let url = decks.appendingPathComponent(name)
            guard let kind = Self.kind(of: url) else { continue }
            let (id, title) = Self.itemID(from: name)
            seen.insert(id)
            let source: String
            if kind == .googleSlides, let link = ShowBuilder.linkURL(url) { source = link.absoluteString } else { source = "decks/\(name)" }
            // A link file mirrored from a Drive folder carries the deck's modified date: an edit upstream is a changed source.
            let hash = kind == .googleSlides ? Self.linkHash(source: source, linkFile: try? String(contentsOf: url, encoding: .utf8)) : SlideHasher.fileHash(url)
            if let i = spec.items.firstIndex(where: { $0.id == id }) {
                var item = spec.items[i]
                if item.source != source || item.kind != kind { item.source = source; item.kind = kind; item.title = title; changed = true }
                if let cur = item.currentVersion, let hash, hash != cur.sourceHash, item.status != .updated {
                    item.status = .updated; changed = true
                    say("\(id) \(title): source changed since v\(cur.number), needs capture")
                } else if item.currentVersion == nil, item.status != .pending, item.status != .failed {
                    item.status = .pending; changed = true
                }
                spec.items[i] = item
            } else {
                spec.items.append(ShowSpec.Item(id: id, title: title, source: source, kind: kind, status: .pending))
                say("\(id) \(title): new (\(kind.rawValue))")
                changed = true
            }
        }
        // A source that vanished keeps its versions but says so.
        for i in spec.items.indices where !seen.contains(spec.items[i].id) && spec.items[i].status != .superseded {
            if spec.items[i].notes?.hasPrefix("source missing") != true {
                spec.items[i].notes = "source missing from decks/ since \(ISO8601DateFormatter().string(from: Date()))"
                changed = true
            }
        }
        // Cues: every audio file in cues/, in name order, for Presenter's channel B.
        let cueDir = sub(.cues)
        let cueExt = ["mp3", "wav", "wave", "aiff", "aif", "m4a", "aac", "caf", "flac"]
        let cues = ((try? fm.contentsOfDirectory(atPath: cueDir.path)) ?? [])
            .filter { !$0.hasPrefix(".") && cueExt.contains(($0 as NSString).pathExtension.lowercased()) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { "cues/\($0)" }
        if cues != spec.cues { spec.cues = cues; changed = true }
        if changed { save() }
        let pending = spec.items.filter { $0.status == .pending || $0.status == .updated }.count
        status = spec.items.isEmpty ? "empty: LINK FOLDER, or drop decks into decks/"
               : pending == 0 ? "\(spec.items.count) item(s), all captured" : "\(pending) of \(spec.items.count) item(s) need capture: CAPTURE PENDING"
    }

    // MARK: Watch decks/ for late drops

    private func watch() {
        let path = sub(.decks).path
        watchFD = open(path, O_EVTONLY)
        guard watchFD >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: watchFD, eventMask: [.write, .rename, .delete], queue: .main)
        src.setEventHandler { [weak self] in self?.scheduleRescan() }
        src.setCancelHandler { [fd = watchFD] in close(fd) }
        src.resume()
        watcher = src
    }

    private func scheduleRescan() {
        rescanTask?.cancel()
        rescanTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.5))   // let a copy finish
            guard !Task.isCancelled else { return }
            self?.rescan()
        }
    }

    // MARK: iCloud

    /// Documents is iCloud Drive: ask for every file to be downloaded and
    /// remember which are still placeholders (the pre-show check shows them).
    func pin() {
        var missing: [String] = []
        let fm = FileManager.default
        guard let e = fm.enumerator(at: folder, includingPropertiesForKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey], options: [.skipsHiddenFiles]) else { return }
        for case let url as URL in e {
            guard let v = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]), v.isUbiquitousItem == true else { continue }
            // Only a placeholder counts: a file still UPLOADING reads as not
            // current too and flagged 34 freshly written files (2026-09-16).
            if v.ubiquitousItemDownloadingStatus == .notDownloaded {
                try? fm.startDownloadingUbiquitousItem(at: url)
                missing.append(url.lastPathComponent)
            }
        }
        placeholders = missing
        if !missing.isEmpty { say("iCloud: \(missing.count) file(s) not downloaded yet, download requested") }
    }

    // MARK: Capture

    var pendingItems: [ShowSpec.Item] { spec.orderedItems.filter { $0.status == .pending || $0.status == .updated } }

    func capturePending(force: Bool = false) async {
        let targets = force ? spec.orderedItems.filter { $0.kind != .arcdeck } : pendingItems
        guard !targets.isEmpty else { say("nothing to capture"); return }
        say("capturing \(targets.count) item(s)")
        for (n, item) in targets.enumerated() {
            if stopRequested { say("stopped before \(item.id) \(item.title): \(targets.count - n) item(s) left"); break }
            setActivity(Activity(step: .capture, title: "Capturing \(item.id) \(item.title)", detail: item.kind.rawValue, index: n + 1, count: targets.count))
            // The item's wall clock. `finishCapture` keeps whatever pages the
            // item did produce and fails it when there are none, so the run
            // records a verdict for this item either way and goes on to the
            // next one instead of stopping the show.
            let watchdog = Task { [weak self] in
                try? await Task.sleep(for: .seconds(self?.itemTimeout ?? 900))
                guard let self, !Task.isCancelled, let session = self.currentSession, !session.finishing else { return }
                self.say("\(item.id) \(item.title): no end after \(Int(self.itemTimeout / 60)) min; ending the item and moving on")
                await session.finishCapture()
            }
            await capture(itemID: item.id, force: force)
            watchdog.cancel()
        }
        rescan()
    }

    /// Capture ONE item into a new version. Never overwrites the previous one.
    func capture(itemID: String, force: Bool = false) async {
        guard let i = spec.items.firstIndex(where: { $0.id == itemID }) else { return }
        guard !busy else { say("busy; \(itemID) queued next time"); return }
        busy = true
        defer { busy = false; currentSession = nil }
        var item = spec.items[i]
        let fm = FileManager.default
        let n = (item.versions.map(\.number).max() ?? 0) + 1
        let deckName = "\(item.id) \(item.title).v\(n).arcdeck"
        let dest = sub(.arcdecks).appendingPathComponent(deckName)
        let work = folder.appendingPathComponent(".arcbuild/\(item.id)/v\(n)", isDirectory: true)
        try? fm.removeItem(at: work); try? fm.createDirectory(at: work, withIntermediateDirectories: true)
        let sourceURL = url(of: item)
        let sourceHash = sourceHash(of: item)
        let sourceModified = (try? fm.attributesOfItem(atPath: sourceURL.path)[.modificationDate] as? Date)
        status = "capturing \(item.id) \(item.title)"
        say("capture \(item.id) \(item.title) -> v\(n)")
        let t0 = Date()

        var producedDeck: URL?
        var reportPath: String?
        var verified = false
        var detail = ""
        var slideHashes: [String]? = nil

        switch item.kind {
        case .powerpoint where item.currentVersion?.slideHashes?.isEmpty == false && !force && !isPerBuildDeck(item.currentVersion):
            // Changed-slides-only recapture (design 4.2): diff the ledger,
            // capture the changed ranges, merge with the reused pages and clips.
            let newHashes = SlideHasher.pptxSlideHashes(sourceURL)
            slideHashes = newHashes
            let analysis = PPTXAnalyzer.analyze(sourceURL)
            let plan = RecapturePlan.make(oldHashes: item.currentVersion?.slideHashes ?? [], newHashes: newHashes,
                                          hidden: Set(analysis.hiddenSlides), slideCount: analysis.slideCount > 0 ? analysis.slideCount : nil)
            switch plan {
            case .unchanged:
                say("  no slide changed (the file was re-saved); v\(item.current ?? 0) stays current")
                item.status = .ready
                if var cur = item.currentVersion, let idx = item.versions.firstIndex(where: { $0.number == cur.number }) {
                    cur.sourceHash = sourceHash; cur.sourceModified = sourceModified; item.versions[idx] = cur
                }
                spec.items[i] = item; save(); status = "\(item.id) unchanged"
                return
            case .full(let reason):
                say("  full capture: \(reason)")
                let r = await captureWhole(item: item, sourceURL: sourceURL, work: work, n: n)
                producedDeck = r.deck; reportPath = r.report; verified = r.verified; detail = r.detail
            case .partial(let ranges, let changed, let reuse):
                say("  \(changed.count) slide(s) changed \(changed); capturing \(ranges.map { "\($0.lowerBound)-\($0.upperBound)" }.joined(separator: ", "))")
                var rangeDecks: [IncrementalMerger.Source] = []
                var failed: String? = nil
                for (k, range) in ranges.enumerated() {
                    let session = CaptureSession(driver: PowerPointDriver(), frameSource: FrameCapture(), recorder: VideoRecorder())
                    session.sourceFile = sourceURL
                    session.outputDirectory = work.appendingPathComponent("range\(k)", isDirectory: true)
                    session.captureRange = range
                    currentSession = session
                    do {
                        let rep = try await session.run()
                        guard let out = rep.output, let src = IncrementalMerger.Source(deck: URL(fileURLWithPath: out)) else { failed = "range \(range) produced no deck"; break }
                        rangeDecks.append(src)
                        say("  range \(range.lowerBound)-\(range.upperBound): \(rep.slides.count) slide(s) in \(Int(rep.wallSeconds)) s")
                    } catch { failed = "range \(range.lowerBound)-\(range.upperBound): \(error.localizedDescription)"; break }
                }
                if let failed {
                    detail = failed
                } else if let cur = item.currentVersion, let old = IncrementalMerger.Source(deck: arcdeckURL(cur)) {
                    let order = (1...max(1, analysis.slideCount)).filter { !analysis.hiddenSlides.contains($0) }
                    let out = work.appendingPathComponent("\(item.id) \(item.title).arcdeck")
                    do {
                        try IncrementalMerger.merge(order: order, reuse: reuse, old: old, ranges: rangeDecks, wanted: Set(changed), into: out)
                        let verdict = await DeckVerifier.verify(arcdeck: out)
                        producedDeck = out; verified = verdict.ok; detail = "merged: " + verdict.detail
                    } catch { detail = "merge failed: \(error.localizedDescription)" }
                } else {
                    detail = "the current version's deck is missing; capture again with FORCE"
                }
            }
        case .powerpoint, .keynote, .googleSlides:
            let driver: PresentationDriver
            var slidesDriver: GoogleSlidesDriver?
            switch item.kind {
            case .googleSlides: let d = GoogleSlidesDriver(); slidesDriver = d; driver = d
            case .keynote: driver = KeynoteDriver()
            default: driver = PowerPointDriver()
            }
            let r = await captureWhole(item: item, sourceURL: sourceURL, work: work, n: n, driver: driver)
            producedDeck = r.deck; reportPath = r.report; verified = r.verified; detail = r.detail
            if item.kind == .googleSlides, let info = slidesDriver?.slidesInfo { slideHashes = SlideHasher.slidesHashes(info) }
            else if item.kind == .powerpoint { slideHashes = SlideHasher.pptxSlideHashes(sourceURL) }
        case .pdf, .image, .movie:
            do {
                let out = work.appendingPathComponent("\(item.id) \(item.title).arcdeck")
                try StillsDeckWriter.write(source: sourceURL, kind: item.kind, to: out)
                try DeckCombiner.wrapInPlace(out, name: "\(item.id) \(item.title)", bumper: bumperURL)   // logo pages, as a captured deck has
                let verdict = await DeckVerifier.verify(arcdeck: out)
                producedDeck = out
                verified = verdict.ok
                detail = verdict.detail
                if item.kind == .pdf { slideHashes = SlideHasher.pdfPageHashes(sourceURL) }
            } catch {
                detail = error.localizedDescription
            }
        case .arcdeck:
            // A ready-made deck dropped into decks/: adopt it as the version.
            let verdict = await DeckVerifier.verify(arcdeck: sourceURL)
            producedDeck = sourceURL
            verified = verdict.ok
            detail = verdict.detail
        case .other:
            // A kind written by a newer app, decoded as `.other` rather than failing the whole file
            // (ShowSpec.ItemKind, 2026-09-18). This build cannot capture what it cannot name, so it
            // leaves the item exactly as it found it and SAYS SO. Silently skipping it would look
            // identical to a capture that produced nothing.
            detail = "kind \"\(item.kind.rawValue)\" is not one this version of ARC Capture understands; the item is left alone. A newer version may capture it."
            say("  \(item.id): \(detail)")
        }

        // Move the produced deck into arcdecks/ as vN (copy for an adopted arcdeck).
        var stored: String?
        if let produced = producedDeck, fm.fileExists(atPath: produced.path) {
            try? fm.removeItem(at: dest)
            do {
                if item.kind == .arcdeck { try fm.copyItem(at: produced, to: dest) } else { try fm.moveItem(at: produced, to: dest) }
                stored = "arcdecks/\(deckName)"
            } catch {
                detail = "could not store the deck: \(error.localizedDescription)"; verified = false
            }
        }
        let version = ShowSpec.Version(number: n, arcdeck: stored ?? "", capturedAt: Date(), sourceHash: sourceHash, sourceModified: sourceModified,
                                       slideHashes: slideHashes, report: reportPath, verified: verified && stored != nil, verifyDetail: detail)
        item.versions.append(version)
        if version.verified {
            item.current = n
            item.status = .ready
            lastCaptured.append(item.id)
            say("  v\(n) ready in \(Int(Date().timeIntervalSince(t0))) s: \(detail)")
        } else {
            item.status = .failed
            say("  v\(n) FAILED: \(detail)")
        }
        spec.items[i] = item
        if version.verified, SourceFolder.isHoldingSlide(title: item.title) { refreshBumper() }
        save()
        status = version.verified ? "\(item.id) v\(n) ready" : "\(item.id) v\(n) failed"
        await updateReview(for: item, version: version)
    }

    /// Recapture of SLIDES, not the item (docs/PLAN_review_queue.md, section 4): the ranges around the
    /// wanted source slides are captured again (each one slide early, for the real transition in) and
    /// merged with the current version's other pages, as the changed-slides path does. PowerPoint and
    /// Keynote; the merged deck carries no logo pages (the show deck adds its own, as after any merge).
    func recapture(itemID: String, slides wanted: [Int]) async {
        guard let i = spec.items.firstIndex(where: { $0.id == itemID }) else { return }
        var item = spec.items[i]
        // A FAILED capture (slides the show passed, R2) has no current version, but its deck is on disk with every
        // other page: that is the base the missing slides go back into.
        guard let cur = item.currentVersion ?? item.latestVersion, !cur.arcdeck.isEmpty, let old = IncrementalMerger.Source(deck: arcdeckURL(cur)) else { say("\(itemID): nothing captured to put slides back into; capture the item"); return }
        guard item.kind == .powerpoint || item.kind == .keynote else { say("\(itemID): \(item.kind.rawValue) cannot be captured by the slide; capture the item"); return }
        let order = old.manifest.slides.filter { $0.role == nil }.map { $0.pptxSlide ?? $0.slide }
        let want = wanted.filter { order.contains($0) }.sorted()
        let unknown = wanted.filter { !order.contains($0) }
        if !unknown.isEmpty { say("  slide(s) \(unknown.map(String.init).joined(separator: ", ")) are not in v\(cur.number); skipped") }
        guard !want.isEmpty else { say("\(itemID): no slide to recapture"); return }
        guard !busy else { say("busy; \(itemID) not recaptured"); return }
        busy = true
        defer { busy = false; currentSession = nil }
        let fm = FileManager.default
        let n = (item.versions.map(\.number).max() ?? 0) + 1
        let deckName = "\(item.id) \(item.title).v\(n).arcdeck"
        let dest = sub(.arcdecks).appendingPathComponent(deckName)
        let work = folder.appendingPathComponent(".arcbuild/\(item.id)/v\(n)", isDirectory: true)
        try? fm.removeItem(at: work); try? fm.createDirectory(at: work, withIntermediateDirectories: true)
        let sourceURL = url(of: item)
        let ranges = RecapturePlan.ranges(around: want, last: order.max())
        if let last = order.max(), want.contains(last) { say("  slide \(last) is the deck's last: a range capture keeps no recording of leaving it, so its builds stay as they were") }
        status = "recapturing \(item.id) slides \(want.map(String.init).joined(separator: ", "))"
        say("recapture \(item.id) slide(s) \(want.map(String.init).joined(separator: ", ")) -> v\(n): ranges \(ranges.map { "\($0.lowerBound)-\($0.upperBound)" }.joined(separator: ", "))")
        let t0 = Date()
        var rangeDecks: [IncrementalMerger.Source] = []
        var failed: String? = nil
        var reportPath: String? = nil
        var reportPaths: [String] = []
        for (k, range) in ranges.enumerated() {
            let session = CaptureSession(driver: item.kind == .keynote ? KeynoteDriver() : PowerPointDriver(), frameSource: FrameCapture(), recorder: VideoRecorder())
            session.sourceFile = sourceURL
            session.outputDirectory = work.appendingPathComponent("range\(k)", isDirectory: true)
            session.captureRange = range
            session.splitOverrides = review.overrides(for: item.id)
            session.grabDirectory = grabsURL
            currentSession = session
            do {
                let rep = try await session.run()
                guard let out = rep.output, let src = IncrementalMerger.Source(deck: URL(fileURLWithPath: out)) else { failed = "range \(range.lowerBound)-\(range.upperBound) produced no deck"; break }
                rangeDecks.append(src)
                let rel = "\(ShowSpec.Folder.reports.rawValue)/\(item.id).v\(n).range\(k).json"
                try? rep.write(to: folder.appendingPathComponent(rel)); reportPath = rel; reportPaths.append(rel)
                say("  range \(range.lowerBound)-\(range.upperBound): \(rep.slides.count) slide(s) in \(Int(rep.wallSeconds)) s" + (rep.ok ? "" : ", NOT ok: \(rep.error ?? "")"))
            } catch { failed = "range \(range.lowerBound)-\(range.upperBound): \(error.localizedDescription)"; break }
        }
        var verified = false
        var detail = ""
        var stored: String? = nil
        if let failed {
            detail = failed
        } else {
            let out = work.appendingPathComponent("\(item.id) \(item.title).arcdeck")
            var reuse: [Int: Int] = [:]
            for p in order where !want.contains(p) { reuse[p] = p }
            do {
                try IncrementalMerger.merge(order: order, reuse: reuse, old: old, ranges: rangeDecks, wanted: Set(want), into: out)
                let verdict = await DeckVerifier.verify(arcdeck: out)
                try? fm.removeItem(at: dest)
                try fm.moveItem(at: out, to: dest)
                stored = "arcdecks/\(deckName)"
                verified = verdict.ok; detail = "recaptured slide(s) \(want.map(String.init).joined(separator: ", ")) from v\(cur.number), merged: " + verdict.detail
            } catch { detail = "merge failed: \(error.localizedDescription)" }
        }
        let version = ShowSpec.Version(number: n, arcdeck: stored ?? "", capturedAt: Date(), sourceHash: cur.sourceHash, sourceModified: cur.sourceModified,
                                       slideHashes: cur.slideHashes, report: reportPath, verified: verified && stored != nil, verifyDetail: detail)
        item.versions.append(version)
        if version.verified { item.current = n; item.status = .ready; say("  v\(n) ready in \(Int(Date().timeIntervalSince(t0))) s: \(detail)") }
        else { say("  v\(n) FAILED: \(detail)") }
        spec.items[i] = item
        save()
        status = version.verified ? "\(item.id) v\(n) ready" : "\(item.id) v\(n) failed"
        // The rows about the pages that were NOT recaptured still stand (the range's report knows nothing of them).
        let standing = review.entries.filter { $0.item == item.id }
        await updateReview(for: item, version: version, reports: reportPaths)
        if version.verified, let newManifest = DeckManifest.load(from: dest.appendingPathComponent("manifest.json")).manifest {
            let carried = ReviewQueue.carry(standing, from: old.manifest, to: newManifest, recaptured: Set(want))
            // The range reports also speak of the warm-up and run-out slides around the wanted ones (a range's
            // last slide keeps no builds, for one): those pages came from the old version, so their rows do not stand.
            let fresh = review.entries.filter { e in
                guard e.item == item.id else { return false }
                guard let p = e.slide, let src = newManifest.slides.first(where: { $0.slide == p && $0.role == nil }).map({ $0.pptxSlide ?? $0.slide }) else { return true }
                return want.contains(src)
            }
            let merged = fresh + carried.filter { c in !fresh.contains { $0.id == c.id } }
            review.replace(item: item.id, with: merged)
            do { try review.save(to: folder) } catch { say("review.json could not be written: \(error.localizedDescription)") }
            let open = review.open.filter { $0.item == item.id }.count
            if open > 0 { say("  REVIEW: \(open) still to decide for \(item.id)") }
        }
    }

    /// Every item's queued slides (rows marked recapture, R2 rows), captured again.
    func recaptureQueued() async {
        for item in spec.orderedItems {
            let manifest = item.currentVersion.flatMap { DeckManifest.load(from: arcdeckURL($0).appendingPathComponent("manifest.json")).manifest }
            let slides = review.recaptureSlides(item: item.id, manifest: manifest)
            if !slides.isEmpty { await recapture(itemID: item.id, slides: slides) }
        }
    }

    /// The slides the queue wants captured again, item by item (for the SHOW tab's chip).
    var queuedRecaptures: [(item: String, slides: [Int])] {
        spec.orderedItems.compactMap { item in
            let manifest = item.currentVersion.flatMap { DeckManifest.load(from: arcdeckURL($0).appendingPathComponent("manifest.json")).manifest }
            let s = review.recaptureSlides(item: item.id, manifest: manifest)
            return s.isEmpty ? nil : (item.id, s)
        }
    }

    /// A decision from the review player: kept in `state/review.json`, applied by the next rebuild or run.
    func decide(_ o: ReviewOverride) {
        review.set(o)
        for e in review.entries where e.item == o.item && (o.click == 0 ? e.slide == o.slide : e.slide == o.slide && e.evidence["click"] == "\(o.click)") {
            review.setStatus(o.kind == .recapture ? "recapture" : (o.kind == .accept ? "accepted" : "decided"), of: e.id)
        }
        do { try review.save(to: folder) } catch { say("review.json could not be written: \(error.localizedDescription)") }
        // The source movie is put in place right away: a rebuild of the item (seconds), then the queue reads the deck again.
        if o.kind == .sourceMovie { Task { await reprocess(itemID: o.item, rebuild: true) } }
    }

    func reopenReview(item: String? = nil) {
        review.reopen(item: item)
        do { try review.save(to: folder) } catch { say("review.json could not be written: \(error.localizedDescription)") }
        say("REVIEW: \(item.map { "\($0)'s" } ?? "every") decision reopened")
    }

    func setReviewStatus(_ status: String, of id: String) {
        review.setStatus(status, of: id)
        do { try review.save(to: folder) } catch { say("review.json could not be written: \(error.localizedDescription)") }
    }

    /// The review queue for one item after its capture (docs/PLAN_review_queue.md, phase 1): the
    /// rules read the report, the deck's manifest and the splitter's sidecars, and the item's
    /// entries in `state/review.json` are replaced. A clean capture removes any older doubts.
    func updateReview(for item: ShowSpec.Item, version: ShowSpec.Version, reports: [String]? = nil) async {
        func load(_ rel: String) -> CaptureReport? {
            guard let data = try? Data(contentsOf: folder.appendingPathComponent(rel)) else { return nil }
            let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
            return try? dec.decode(CaptureReport.self, from: data)
        }
        let loaded = (reports ?? [version.report].compactMap { $0 }).compactMap(load)
        let report: CaptureReport? = loaded.first
        var manifest: DeckManifest? = nil
        var sidecars: [ReviewSidecar] = []
        if !version.arcdeck.isEmpty {
            let deck = folder.appendingPathComponent(version.arcdeck)
            manifest = DeckManifest.load(from: deck.appendingPathComponent("manifest.json")).manifest
            if let files = try? FileManager.default.contentsOfDirectory(at: deck.appendingPathComponent("review"), includingPropertiesForKeys: nil) {
                sidecars = files.filter { $0.pathExtension == "json" }.compactMap { try? JSONDecoder().decode(ReviewSidecar.self, from: Data(contentsOf: $0)) }
            }
        }
        var entries = ReviewRules.evaluate(item: item, report: report, verifyDetail: version.verifyDetail ?? "", manifest: manifest,
                                           sidecars: sidecars, deckRel: version.arcdeck.isEmpty ? nil : version.arcdeck)
        for more in loaded.dropFirst() {   // a recapture of several ranges: every range's report speaks
            for e in ReviewRules.evaluate(item: item, report: more, verifyDetail: version.verifyDetail ?? "", manifest: manifest, sidecars: sidecars, deckRel: version.arcdeck.isEmpty ? nil : version.arcdeck)
            where !entries.contains(where: { $0.id == e.id }) { entries.append(e) }
        }
        // R12: a black page nobody asked for. Found on the deck itself, after the splitter; the show will not
        // build over it undecided, and an accepted one becomes a PROBLEM slide (BlackPages).
        if !version.arcdeck.isEmpty {
            let deck = folder.appendingPathComponent(version.arcdeck)
            let hits = await BlackPages.find(in: deck)
            for h in hits where !entries.contains(where: { $0.rule == "R12" && $0.slide == h.page }) {
                var e = ReviewEntry(item: item.id, title: item.title, slide: h.page, rule: "R12",
                                    reason: "page \(h.page) is black and nothing asked for black: \(h.reason). Recapture it, or accept and the show carries a PROBLEM slide there", evidence: ["black": h.reason])
                if let sc = sidecars.first(where: { $0.slide == h.page }) { e.recording = version.arcdeck + "/" + sc.recording; e.marks = sc.marks }
                else if let f = manifest?.slides.first(where: { $0.slide == h.page })?.file { e.recording = version.arcdeck + "/" + f }
                entries.append(e)
            }
            if !hits.isEmpty { say("  BLACK: \(hits.count) page(s) of \(item.id) are black (\(hits.map { String($0.page) }.joined(separator: ", "))): the show will not build over them undecided") }
        }
        // Decisions made against another source do not carry: the deck changed under them.
        let dropped = review.dropOverrides(item: item.id, unlessHash: version.sourceHash)
        if dropped > 0 { say("  REVIEW: \(dropped) decision\(dropped == 1 ? "" : "s") for \(item.id) dropped, the source changed") }
        review.replace(item: item.id, with: entries)
        do { try review.save(to: folder) } catch { say("review.json could not be written: \(error.localizedDescription)") }
        if !entries.isEmpty { say("  REVIEW: \(entries.count) decision\(entries.count == 1 ? "" : "s") for \(item.id): \(Set(entries.map(\.rule)).sorted().joined(separator: " "))") }
    }

    /// One whole-show capture into `work`; the report lands in reports/.
    /// Run the splitter over a version that is ALREADY captured and keep the
    /// result as a new version: per-build clips, state stills, a looping movie
    /// cut from its way in. No PowerPoint, no display, seconds not minutes; how
    /// a deck captured before a splitter rule existed gets it.
    /// `rebuild`: the pages with a kept recording are cut again from it with the review's decisions
    /// (docs/PLAN_review_queue.md, phase 2); the "needs nothing" check is skipped, a decision is a change.
    func reprocess(itemID: String, rebuild: Bool = false) async {
        guard let i = spec.items.firstIndex(where: { $0.id == itemID }), let cur = spec.items[i].currentVersion else { say("\(itemID): nothing captured to reprocess"); return }
        guard !busy else { say("busy; \(itemID) not reprocessed"); return }
        busy = true; defer { busy = false }
        var item = spec.items[i]
        let n = (item.versions.map(\.number).max() ?? 0) + 1
        let rel = "\(ShowSpec.Folder.arcdecks.rawValue)/\(item.id) \(item.title).v\(n).arcdeck"
        let dest = folder.appendingPathComponent(rel)
        do {
            let sum = try await BuildSplitter.convert(deck: arcdeckURL(cur), into: dest, pptx: url(of: item), overrides: review.overrides(for: item.id), rebuild: rebuild, grabDir: grabsURL) { [weak self] l in self?.say("  " + l) }
            // Speaker notes the capture of the day did not carry.
            let hadNotes = FileManager.default.fileExists(atPath: dest.appendingPathComponent("notes.json").path)
            let notes = hadNotes ? 0 : DeckNotes.write(source: url(of: item), into: dest)
            guard rebuild || sum.builds > 0 || sum.loopsSeparated > 0 || notes > 0 || sum.cuts > 0 || sum.waysInCut > 0 || sum.sourceMovies > 0 || sum.onlineVideos > 0 else {
                try? FileManager.default.removeItem(at: dest)
                say("\(item.id): v\(cur.number) needs nothing (no builds to split, no loop to separate, no source movie to swap in, notes \(hadNotes ? "present" : "none in the source"))"); return
            }
            if sum.sourceMovies > 0 { say("  \(sum.sourceMovies) source movie(s) in place of recordings") }
            if sum.onlineVideos > 0 { say("  \(sum.onlineVideos) online video(s) fetched by ARC Grab, played locally") }
            for (n, why) in sum.onlineVideosFailed.sorted(by: { $0.key < $1.key }) { say("  slide \(n): the online video it links to was not fetched: \(why)") }
            if notes > 0 { say("  speaker notes added to \(notes) page(s)") }
            let verdict = await DeckVerifier.verify(arcdeck: dest)
            item.versions.append(ShowSpec.Version(number: n, arcdeck: rel, capturedAt: Date(), sourceHash: cur.sourceHash, sourceModified: cur.sourceModified,
                                                  slideHashes: cur.slideHashes, report: cur.report, verified: verdict.ok,
                                                  verifyDetail: "\(rebuild ? "rebuilt" : "reprocessed") from v\(cur.number): \(verdict.detail)"))
            if verdict.ok { item.current = n; item.status = .ready }
            spec.items[i] = item; save()
            if let v = item.versions.last { await updateReview(for: item, version: v) }
            say("\(item.id): v\(n) \(verdict.ok ? "ready" : "FAILED verification"), \(rebuild ? "rebuilt" : "reprocessed") from v\(cur.number): \(sum.builds) build clip(s), \(sum.loopsSeparated) loop(s) separated, \(sum.cuts) build(s) and \(sum.waysInCut) way(s) in turned into cuts; \(verdict.detail)")
        } catch {
            try? FileManager.default.removeItem(at: dest)
            say("\(item.id): reprocess FAILED: \(error.localizedDescription)")
        }
    }

    /// The changed-slides merger (IncrementalMerger) reuses pages and clips of a
    /// version 2 deck by slide number. It knows nothing of logo pages, per-build
    /// clips or state stills, and would write a deck without them: until it
    /// does, a per-build deck is recaptured whole.
    private func isPerBuildDeck(_ v: ShowSpec.Version?) -> Bool {
        guard let v, let m = DeckManifest.load(from: arcdeckURL(v).appendingPathComponent("manifest.json")).manifest else { return false }
        return m.version >= 3 || m.slides.contains { $0.role != nil }
    }

    /// A show's own art for the logo pages: `bumper.png` at the root of the folder. nil = the ARC mark.
    /// A show with a HOLDING SLIDE item ("S0.0 Holding Slide ...", which lands as 0.00) has it made from that
    /// item's captured page (`refreshBumper`); without one, a bumper.png put there by hand is used as it is.
    var bumperURL: URL? {
        let u = folder.appendingPathComponent("bumper.png")
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    /// The item that is the show's logo page, by its name (2026-09-17: "I will name them S0.0 Holding Slide").
    var holdingItem: ShowSpec.Item? { holdingItems.first }
    /// Every holding slide: the show's (S0.0) first, then a session's own (S2.0 = the logo page of session 2).
    var holdingItems: [ShowSpec.Item] { spec.orderedItems.filter { SourceFolder.isHoldingSlide(title: $0.title) && $0.status != .superseded } }

    /// A session's own logo page, when it has one (`bumper-s2.png`, made from item 2.00). nil = the show's.
    func bumperURL(session n: Int) -> URL? {
        guard n > 0 else { return nil }
        let u = folder.appendingPathComponent("bumper-s\(n).png")
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    /// "Session 2" as the client's folder names it, else "Session 2".
    func sessionName(_ n: Int) -> String {
        let folderName = sourceLedger.links.first { Self.session(of: Self.itemID(from: $0.deck).id) == n }.map { SourceFolder.top(of: $0.rel) }
        return (folderName?.isEmpty == false) ? folderName! : "Session \(n)"
    }

    /// `bumper.png` from the holding slide's current version: its first page that is not a logo page, at 1920 wide.
    /// Every deck captured or combined AFTER this carries it; one captured before keeps the page it was given
    /// until it is recaptured (the combined decks do not: DeckCombiner redraws logo pages).
    func refreshBumper() {
        for item in holdingItems { refreshBumper(from: item) }
    }

    private func refreshBumper(from item: ShowSpec.Item) {
        guard let v = item.currentVersion else { return }
        let session = Self.session(of: item.id) ?? 0
        let deck = arcdeckURL(v)
        guard let doc = PDFDocument(url: deck.appendingPathComponent("slides.pdf")) else { return }
        let roles = Dictionary((DeckManifest.load(from: deck.appendingPathComponent("manifest.json")).manifest?.slides ?? []).map { ($0.slide, $0.role) }, uniquingKeysWith: { a, _ in a })
        guard let index = (0..<doc.pageCount).first(where: { (roles[$0 + 1] ?? nil) == nil }), let page = doc.page(at: index) else { return }
        let box = page.bounds(for: .mediaBox)
        guard box.width > 0, box.height > 0 else { return }
        let size = CGSize(width: 1920, height: (1920 * box.height / box.width).rounded())
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return }
        rep.size = size
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ctx
        NSColor.black.setFill(); CGRect(origin: .zero, size: size).fill()
        ctx.cgContext.scaleBy(x: size.width / box.width, y: size.height / box.height)
        page.draw(with: .mediaBox, to: ctx.cgContext)
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        let out = folder.appendingPathComponent(session > 0 ? "bumper-s\(session).png" : "bumper.png")
        if (try? Data(contentsOf: out)) == png { return }
        do {
            try png.write(to: out, options: .atomic)
            let before = spec.items.filter { $0.id != item.id && $0.currentVersion != nil }.count
            say((session > 0 ? "session \(session) logo pages" : "logo pages") + ": now \(item.id) \(item.title) v\(v.number)" + (before > 0 ? "; \(before) deck(s) captured earlier keep the page they were given until recaptured (the combined decks are redrawn)" : ""))
        } catch { say("bumper.png could not be written: \(error.localizedDescription)") }
    }

    private func captureWhole(item: ShowSpec.Item, sourceURL: URL, work: URL, n: Int, driver: PresentationDriver? = nil) async -> (deck: URL?, report: String?, verified: Bool, detail: String) {
        let session = CaptureSession(driver: driver ?? PowerPointDriver(), frameSource: FrameCapture(), recorder: VideoRecorder())
        session.sourceFile = sourceURL
        session.outputDirectory = work
        session.splitOverrides = review.overrides(for: item.id)   // a re-run applies the review's decisions again without asking
        session.grabDirectory = grabsURL
        session.bumperImageURL = bumperURL
        currentSession = session
        let reportURL = sub(.reports).appendingPathComponent("\(item.id).v\(n).json")
        do {
            let rep = try await session.run()
            try? rep.write(to: reportURL)
            return (rep.output.map { URL(fileURLWithPath: $0) }, "reports/\(reportURL.lastPathComponent)", rep.verified ?? rep.ok,
                    rep.verifyDetail ?? (rep.ok ? "\(rep.slides.count) slides" : (rep.error ?? "failed")))
        } catch {
            let rep = (error as? CaptureFailure)?.report ?? session.report
            if let rep { try? rep.write(to: reportURL) }
            // A run that failed for slides the show passed (R2) still wrote every other page: that deck is kept as
            // the FAILED version, so the review queue's recapture of those slides has a base to put them back into
            // (8.90 on 2026-09-19 had no deck to mend and needed the whole capture again).
            let leftBehind = ((try? FileManager.default.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)) ?? [])
                .first { $0.pathExtension == "arcdeck" && FileManager.default.fileExists(atPath: $0.appendingPathComponent("manifest.json").path) }
            return (leftBehind, rep == nil ? nil : "reports/\(reportURL.lastPathComponent)", false, error.localizedDescription)
        }
    }

    // MARK: Preflight

    /// Capture-report warnings that mean a slide's media will not play in the show.
    nonisolated static func mediaWarnings(inReport url: URL?) -> [String] {
        guard let url, let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let warnings = obj["warnings"] as? [String] else { return [] }
        return warnings.filter { $0.contains("movie did not start") || $0.contains("playback stopped") || $0.contains("the deck has") }
    }

    @discardableResult
    func preflight() async -> Bool {
        pin()
        rescan()
        var rows: [PreflightRow] = []
        let fm = FileManager.default
        for item in spec.orderedItems where item.status != .superseded {
            let src = url(of: item)
            if !item.source.hasPrefix("http"), !fm.fileExists(atPath: src.path) {
                rows.append(PreflightRow(id: item.id, label: "\(item.id) \(item.title)", ok: false, required: true, detail: "source missing: \(item.source)"))
                continue
            }
            if placeholders.contains(src.lastPathComponent) {
                rows.append(PreflightRow(id: item.id, label: "\(item.id) \(item.title)", ok: false, required: true, detail: "still an iCloud placeholder (download requested)"))
                continue
            }
            switch item.status {
            case .pending:
                rows.append(PreflightRow(id: item.id, label: "\(item.id) \(item.title)", ok: false, required: true, detail: "not captured"))
            case .updated:
                rows.append(PreflightRow(id: item.id, label: "\(item.id) \(item.title)", ok: false, required: true, detail: "source changed after v\(item.currentVersion?.number ?? 0); recapture"))
            case .failed:
                rows.append(PreflightRow(id: item.id, label: "\(item.id) \(item.title)", ok: false, required: true, detail: item.latestVersion?.verifyDetail ?? "last capture failed"))
            case .ready, .captured, .superseded:
                if let v = item.currentVersion {
                    let verdict = await DeckVerifier.verify(arcdeck: arcdeckURL(v))
                    rows.append(PreflightRow(id: item.id, label: "\(item.id) \(item.title)", ok: verdict.ok, required: true, detail: "v\(v.number): \(verdict.detail)"))
                    // The verifier checks structure. What the capture SAW going
                    // wrong is in its report, and nobody reads a JSON file the
                    // night before: media that never started is raised here.
                    for w in Self.mediaWarnings(inReport: v.report.map { folder.appendingPathComponent($0) }) {
                        rows.append(PreflightRow(id: "\(item.id).media", label: "\(item.id) \(item.title)", ok: false, required: false, detail: "v\(v.number): \(w)"))
                    }
                } else {
                    rows.append(PreflightRow(id: item.id, label: "\(item.id) \(item.title)", ok: false, required: true, detail: "no current version"))
                }
            }
        }
        if spec.items.isEmpty { rows.append(PreflightRow(id: "items", label: "ITEMS", ok: false, required: false, detail: "no items in decks/")) }
        if let m = spec.mergedDeck {
            let verdict = await DeckVerifier.verify(arcdeck: folder.appendingPathComponent(m))
            rows.append(PreflightRow(id: "stack", label: "MERGED STACK", ok: verdict.ok, required: false, detail: verdict.detail))
        }
        for cue in spec.cues where !fm.fileExists(atPath: folder.appendingPathComponent(cue).path) {
            rows.append(PreflightRow(id: "cue.\(cue)", label: "CUE", ok: false, required: false, detail: "missing: \(cue)"))
        }
        preflightRows = rows
        preflightRanAt = Date()
        let passed = rows.filter(\.required).allSatisfy(\.ok)
        let report: [String: Any] = ["ranAt": ISO8601DateFormatter().string(from: Date()), "passed": passed, "show": spec.name,
                                     "rows": rows.map { ["id": $0.id, "label": $0.label, "ok": $0.ok, "required": $0.required, "detail": $0.detail] }]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: sub(.reports).appendingPathComponent("preflight.json"), options: .atomic)
        }
        say("PREFLIGHT \(passed ? "PASS" : "FAIL"): \(rows.filter { !$0.ok }.count) of \(rows.count) flagged")
        for r in rows where !r.ok { say("  \(r.required ? "FAIL" : "WARN") \(r.label): \(r.detail)") }
        // Preflight is the LAST check, not the first step (the operator pressed it on a fresh import, 2026-09-17: "dont i capture first?").
        let uncaptured = rows.filter { $0.detail == "not captured" }.count
        if uncaptured > 0 { say("\(uncaptured) item(s) are not captured yet: CAPTURE PENDING first, preflight is the check before HAND OFF") }
        status = passed ? "preflight PASS" : (uncaptured > 0 ? "\(uncaptured) not captured yet: CAPTURE PENDING first" : "preflight FAIL")
        return passed
    }

    // MARK: Merged stack (the single-deck option) and hand-off

    /// The COMBINED session deck beside the deck per preso: every ready item
    /// in run order in one arcdeck, a logo page before, between and after.
    /// The ONE show deck, as a NEW VERSION every time (`<show>.show.vN.arcdeck`), recorded in show.json as
    /// `showDeck` with one key per page. It used to be rebuilt in place under one name, which is a deck
    /// Presenter may have LIVE being replaced under it; versioned, Presenter stages the new one beside the
    /// live one on the matching page and the operator takes it ("never yank a live deck").
    func buildStack() async {
        refreshBumper()
        let included = showDeckItems
        // Sessions inside the ONE deck: a session with its own holding slide ("S2.0 Holding Slide ...") is
        // announced by it, and the page where a session starts is labelled for the operator.
        let sessions = Set(included.compactMap { Self.session(of: $0.id) })
        var lastSession: Int?
        // NEVER a black page nobody asked for: an undecided one stops the build, an accepted one becomes a
        // PROBLEM slide, only an explicit LEAVE IT BLACK keeps it (2026-09-19).
        let black = review.entries.filter { e in e.rule == "R12" && included.contains(where: { $0.id == e.item }) }
        let undecided = black.filter { $0.status == "open" || $0.status == "recapture" }
        guard undecided.isEmpty else {
            say("show deck NOT built: \(undecided.count) black page(s) undecided (\(undecided.map { "\($0.item) p\($0.slide ?? 0)" }.joined(separator: ", "))): decide them in REVIEW, or run the recaptures")
            status = "black pages undecided"; return
        }
        let ready: [DeckCombiner.Part] = included.compactMap { item in
            guard let v = item.currentVersion else { return nil }
            let n = Self.session(of: item.id)
            var part = DeckCombiner.Part(name: "\(item.id) \(item.title)", deck: arcdeckURL(v), bumper: n.flatMap { bumperURL(session: $0) })
            for e in black where e.item == item.id && e.status == "accepted" {
                if let p = e.slide { part.replace[p] = (item.id, item.title, e.evidence["black"] ?? "not captured") }
            }
            if sessions.count > 1, let n, n != lastSession { part.dividerTitle = sessionName(n).uppercased() }
            lastSession = n
            return part
        }
        guard !ready.isEmpty else { say("no ready decks to combine"); return }
        busy = true; defer { busy = false }
        var deckItem = spec.showDeck ?? ShowSpec.Item(id: ShowSpec.showDeckID, title: spec.name, source: "", kind: .arcdeck)
        let n = (deckItem.versions.map(\.number).max() ?? 0) + 1
        let rel = "arcdecks/\(spec.name).show.v\(n).arcdeck"
        let out = folder.appendingPathComponent(rel)
        do {
            let t0 = Date()
            let r = try DeckCombiner.combine(ready, name: spec.name, into: out, bumper: bumperURL) { [weak self] l in self?.say(l) }
            let verdict = await DeckVerifier.verify(arcdeck: out)
            guard verdict.ok else { say("show deck FAILED verification: \(verdict.detail)"); status = "show deck failed"; try? FileManager.default.removeItem(at: out); return }
            deckItem.title = spec.name
            deckItem.versions.append(ShowSpec.Version(number: n, arcdeck: rel, capturedAt: Date(), slideHashes: showDeckPageKeys(out, items: included),
                                                      verified: true, verifyDetail: verdict.detail))
            deckItem.current = n; deckItem.status = .ready
            spec.showDeck = deckItem
            spec.mergedDeck = rel
            save()
            markShowDeckBuilt(from: included)
            say("show deck: \(out.lastPathComponent), \(r.parts) deck(s), \(r.pages) pages, \(r.clips) clip(s), \(r.stills) still(s) in \(String(format: "%.1f", Date().timeIntervalSince(t0))) s; \(verdict.detail)")
            if n > 1 { say("  v\(n - 1) stays on disk: a Presenter that has it open stages v\(n) beside it and swaps on the matching page") }
            status = "show deck v\(n) built"
        } catch {
            say("show deck FAILED: \(error.localizedDescription)")
        }
    }

    /// One key per page of the show deck (ShowSpec.pageKeys): which talk, which of its pages, and the source
    /// slide's own hash when the capture recorded one, so an edited slide reads as changed.
    private func showDeckPageKeys(_ deck: URL, items: [ShowSpec.Item]) -> [String] {
        guard let manifest = DeckManifest.load(from: deck.appendingPathComponent("manifest.json")).manifest else { return [] }
        let hashes = Dictionary(items.map { ($0.id, $0.currentVersion?.slideHashes ?? []) }, uniquingKeysWith: { a, _ in a })
        return ShowSpec.pageKeys(manifest.slides.sorted { $0.slide < $1.slide }.map { s in
            let id = s.source.map { String($0.prefix { $0 != " " }) } ?? ""
            let own = hashes[id] ?? []
            let key = s.pptxSlide.flatMap { own.indices.contains($0 - 1) ? own[$0 - 1] : nil }
            return (s.source, s.sourcePage, key, s.role != nil)
        })
    }

    // MARK: Session decks

    /// "1.06" -> 1, "2.11" -> 2, "1.09.5" -> 1; "Keynote" -> nil (not in a session).
    nonisolated static func session(of id: String) -> Int? {
        let head = id.prefix { $0 != "." }
        return head.count < id.count ? Int(head) : nil
    }

    /// Ready items grouped by session, in run order. Session 0 is the linked folder's ROOT (a holding slide, the
    /// client's own combined deck): those stay single decks, a session deck is a session's talks.
    nonisolated static func sessionGroups(_ items: [(id: String, title: String)]) -> [(session: Int, ids: [String])] {
        var order: [Int] = [], groups: [Int: [String]] = [:]
        for item in items {
            guard let n = session(of: item.id), n > 0 else { continue }
            if groups[n] == nil { order.append(n) }
            groups[n, default: []].append(item.id)
        }
        return order.sorted().map { ($0, groups[$0]!) }
    }

    /// One combined deck PER SESSION, a logo page before the first talk, between every two and after the last
    /// (2026-09-17: "combine them into session decks with logo slides in between"). Named after the session's
    /// folder in the linked source when there is one. The single decks and the whole-show deck are untouched.
    func buildSessionDecks() async {
        refreshBumper()
        let ready = spec.orderedItems.filter { $0.status != .superseded && $0.currentVersion != nil }
        let groups = Self.sessionGroups(ready.map { ($0.id, $0.title) })
        guard !groups.isEmpty else { say("no sessions to combine (item ids carry no session number)"); return }
        guard !busy else { say("busy; session decks not built"); return }
        busy = true; defer { busy = false }
        let left = ready.filter { (Self.session(of: $0.id) ?? 0) == 0 }
        if !left.isEmpty { say("not in a session deck (root or unnumbered): " + left.map(\.id).joined(separator: ", ")) }
        var built = 0
        for g in groups {
            let items = ready.filter { g.ids.contains($0.id) }
            let parts = items.compactMap { item in item.currentVersion.map { DeckCombiner.Part(name: "\(item.id) \(item.title)", deck: arcdeckURL($0)) } }
            // The folder the client named, when the show is fed by one ("Session 2"); else "Session N".
            let folderName = sourceLedger.links.first { l in items.contains { l.deck.hasPrefix($0.id + " ") } }.map { SourceFolder.top(of: $0.rel) }
            let name = "\(spec.name) - " + ((folderName?.isEmpty == false) ? folderName! : "Session \(g.session)")
            let out = sub(.arcdecks).appendingPathComponent("\(name).arcdeck")
            do {
                let t0 = Date()
                let r = try DeckCombiner.combine(parts, name: name, into: out, bumper: bumperURL) { _ in }
                let verdict = await DeckVerifier.verify(arcdeck: out)
                guard verdict.ok else { say("session deck \(name) FAILED verification: \(verdict.detail)"); continue }
                built += 1
                say("session deck: \(out.lastPathComponent), \(r.parts) deck(s), \(r.pages) pages, \(r.clips) clip(s) in \(String(format: "%.1f", Date().timeIntervalSince(t0))) s; \(verdict.detail)")
            } catch {
                say("session deck \(name) FAILED: \(error.localizedDescription)")
            }
        }
        status = "\(built) of \(groups.count) session deck(s) built"
    }

    /// `POST /show?path=` on Presenter: it opens the whole folder.
    func handOff() async -> Bool {
        guard await ensurePresenter() else { return false }
        guard let url = URL(string: "http://localhost:8760/show?path=" + (folder.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? folder.path)) else { return false }
        var req = URLRequest(url: url); req.httpMethod = "POST"; req.timeoutInterval = 20
        guard let (_, resp) = try? await URLSession.shared.data(for: req), let code = (resp as? HTTPURLResponse)?.statusCode else {
            say("hand-off: Presenter is not answering on localhost:8760"); return false
        }
        let ok = (200...299).contains(code)
        say(ok ? "handed off to Presenter" : "hand-off refused: HTTP \(code)")
        return ok
    }

    /// A Presenter that understands show decks is answering on 8760: the one running, or the newest 5.0 or later,
    /// started here (2026-09-17: "hand off isnt working": first none was running, then 4.1.0 was, which has no /show).
    func ensurePresenter() async -> Bool {
        func get(_ path: String) async -> Int? {
            guard let u = URL(string: "http://localhost:8760" + path) else { return nil }
            var req = URLRequest(url: u); req.timeoutInterval = 3
            guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return nil }
            return (resp as? HTTPURLResponse)?.statusCode
        }
        if await get("/state") == nil {
            guard let app = Self.presenterForShows() else { say("no ARC Presenter 5 or later found on this Mac"); return false }
            say("starting \(app.url.path) (\(app.version))")
            let config = NSWorkspace.OpenConfiguration(); config.activates = false
            _ = try? await NSWorkspace.shared.openApplication(at: app.url, configuration: config)
            var up = false
            for _ in 0..<40 { try? await Task.sleep(for: .seconds(0.5)); if await get("/state") != nil { up = true; break } }
            guard up else { say("Presenter did not answer on localhost:8760 within 20 s"); return false }
            try? await Task.sleep(for: .seconds(2))            // its own session restore first
        }
        if await get("/show") == 404 {
            say("the ARC Presenter that is running is older than 5.0. Quit it and press again; the right one will be started.")
            return false
        }
        return true
    }

    /// The newest installed ARC Presenter that opens show folders (5.0 and later).
    nonisolated static func presenterForShows() -> (url: URL, version: String)? {
        // ONLY the Applications folders. Launch Services also knows every Xcode build product: asked by bundle id
        // it offered build/dd/.../Debug/ARC Presenter.app, which is Apple Development signed and re-prompts for
        // Accessibility (it was started once, 2026-09-17).
        var found: [URL] = []
        let fm = FileManager.default
        for dir in [fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications"), URL(fileURLWithPath: "/Applications")] {
            for sub in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
                let direct = sub.pathExtension == "app" ? [sub] : ((try? fm.contentsOfDirectory(at: sub, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "app" }
                found += direct.filter { $0.lastPathComponent.hasPrefix("ARC Presenter") }
            }
        }
        let versions = Set(found.map { $0.standardizedFileURL }).compactMap { url -> (URL, String)? in
            guard let v = Bundle(url: url)?.infoDictionary?["CFBundleShortVersionString"] as? String else { return nil }
            return (url, v)
        }
        return versions.filter { $0.1.compare("5.0", options: .numeric) != .orderedAscending }
            .max { $0.1.compare($1.1, options: .numeric) == .orderedAscending }
            .map { (url: $0.0, version: $0.1) }
    }

    var summary: String {
        let byStatus = Dictionary(grouping: spec.items, by: \.status).mapValues(\.count)
        return byStatus.map { "\($0.key.rawValue) \($0.value)" }.sorted().joined(separator: ", ")
    }
}

// MARK: - Stills decks for PDF, image and movie items

/// A PDF, an image or a movie as an .arcdeck of its own (the per-item shape
/// of what the show builder does inside a merged stack).
@MainActor
enum StillsDeckWriter {
    static func write(source: URL, kind: ShowSpec.ItemKind, to deck: URL) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: deck)
        try fm.createDirectory(at: deck, withIntermediateDirectories: true)
        let pdfURL = deck.appendingPathComponent("slides.pdf")
        var slides: [DeckManifest.Slide] = []
        let name = source.lastPathComponent
        switch kind {
        case .pdf:
            guard let doc = PDFDocument(url: source) else { throw NSError(domain: "ARCCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: "PDF will not open"]) }
            try fm.copyItem(at: source, to: pdfURL)
            for i in 0..<doc.pageCount { slides.append(DeckManifest.Slide(slide: i + 1, type: .image, source: name, sourcePage: i + 1)) }
        case .image:
            guard let img = NSImage(contentsOf: source), let page = ShowBuilder.canvasPage(img) else { throw NSError(domain: "ARCCapture", code: 2, userInfo: [NSLocalizedDescriptionKey: "image will not open"]) }
            let doc = PDFDocument(); doc.insert(page, at: 0)
            ARCCredit.stamp(doc)
            guard doc.write(to: pdfURL) else { throw NSError(domain: "ARCCapture", code: 3, userInfo: [NSLocalizedDescriptionKey: "slides.pdf could not be written"]) }
            slides.append(DeckManifest.Slide(slide: 1, type: .image, source: name))
        case .movie:
            let doc = PDFDocument()
            if let poster = ShowBuilder.firstFrame(source), let page = ShowBuilder.canvasPage(poster) { doc.insert(page, at: 0) } else { doc.insert(PDFPage(), at: 0) }
            ARCCredit.stamp(doc)
            guard doc.write(to: pdfURL) else { throw NSError(domain: "ARCCapture", code: 3, userInfo: [NSLocalizedDescriptionKey: "slides.pdf could not be written"]) }
            try fm.createDirectory(at: deck.appendingPathComponent("media"), withIntermediateDirectories: true)
            let rel = "media/slide_001.mov"
            try fm.copyItem(at: source, to: deck.appendingPathComponent(rel))
            slides.append(DeckManifest.Slide(slide: 1, type: .video, file: rel, source: name))
        default:
            throw NSError(domain: "ARCCapture", code: 4, userInfo: [NSLocalizedDescriptionKey: "not a stills source"])
        }
        try DeckManifest(slides: slides).write(to: deck.appendingPathComponent("manifest.json"))
    }
}

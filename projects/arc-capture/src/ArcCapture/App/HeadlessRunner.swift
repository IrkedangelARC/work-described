//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import AppKit
import Foundation
import ARCShowFormat

/// Headless mode: no ARC Capture window, one capture, a JSON report, an exit
/// code. PowerPoint still needs a real display and its slideshow window in
/// front, and the Screen Recording / Automation grants must already be in
/// place for this signed bundle; "headless" is about ARC Capture, not macOS.
///
///   "ARC Capture" --headless --in deck.pptx [--out DIR] [--report FILE.json]
///                 [--dwell 0.3] [--max-record 30] [--timeout 900] [--keep-pngs]
///                 [--resume]
///
/// `--resume` picks up a run that died: if a `<name>.arcdeck.partial` beside
/// the output holds slides captured from this same, unchanged deck, they are
/// restored and the show restarts on the slide after the last one.
///
/// Exit: 0 ok, 1 capture failed, 2 bad arguments, 3 run timeout.
enum HeadlessRunner {

    struct Options {
        var input: URL
        var outputDir: URL?
        var reportURL: URL?
        var dwell: TimeInterval = 0.3
        var maxRecord: TimeInterval = 30
        var timeout: TimeInterval = 900
        var keepPNGs = false
        var resume = false
    }

    /// Every flag that means "do this and exit". The V3 show-folder commands
    /// were missing: `--new-show` alone opened the GUI and made nothing (2026-09-17).
    static let commandFlags: Set<String> = ["--headless", "--watch", "--analyze", "--show", "--new-show", "--show-folder", "--verify", "--split-builds", "--recapture"]
    static var isRequested: Bool { isRequested(in: CommandLine.arguments) }
    static func isRequested(in arguments: [String]) -> Bool { arguments.contains { commandFlags.contains($0) } }
    /// --watch: the headless run, plus the monitor window (the suite can be watched).
    static var isWatch: Bool { CommandLine.arguments.contains("--watch") }
    /// The running headless session, for the monitor window.
    /// Observable so the --watch window re-renders once the session exists:
    /// a plain static was read once (nil) when the scene first built and the
    /// window stayed blank (2026-09-12).
    @MainActor @Observable final class WatchState { var session: CaptureSession? }
    @MainActor static let watch = WatchState()
    @MainActor static var activeSession: CaptureSession? {
        get { watch.session }
        set { watch.session = newValue }
    }

    struct ParseError: Error { let message: String }

    static func parse(_ args: [String]) -> Result<Options, ParseError> {
        var input: URL? = nil
        var o = Options(input: URL(fileURLWithPath: "/dev/null"))
        var i = 1
        func value() -> String? { i + 1 < args.count ? args[i + 1] : nil }
        while i < args.count {
            switch args[i] {
            case "--headless", "--watch": break
            case "--in": guard let v = value() else { return .failure(ParseError(message: "--in needs a path")) }; input = v.hasPrefix("http") ? URL(string: v) : URL(fileURLWithPath: v); i += 1
            case "--out": guard let v = value() else { return .failure(ParseError(message: "--out needs a path")) }; o.outputDir = URL(fileURLWithPath: v); i += 1
            case "--report": guard let v = value() else { return .failure(ParseError(message: "--report needs a path")) }; o.reportURL = URL(fileURLWithPath: v); i += 1
            case "--dwell": guard let v = value(), let d = TimeInterval(v) else { return .failure(ParseError(message: "--dwell needs seconds")) }; o.dwell = d; i += 1
            case "--max-record": guard let v = value(), let d = TimeInterval(v) else { return .failure(ParseError(message: "--max-record needs seconds")) }; o.maxRecord = d; i += 1
            case "--timeout": guard let v = value(), let d = TimeInterval(v) else { return .failure(ParseError(message: "--timeout needs seconds")) }; o.timeout = d; i += 1
            case "--keep-pngs": o.keepPNGs = true
            case "--resume": o.resume = true
            default:
                if args[i].hasPrefix("-") { return .failure(ParseError(message: "unknown option \(args[i])")) }
            }
            i += 1
        }
        guard let input else { return .failure(ParseError(message: "--in <deck.pptx> is required")) }
        if input.isFileURL, !FileManager.default.fileExists(atPath: input.path) { return .failure(ParseError(message: "no such file: \(input.path)")) }
        o.input = input
        return .success(o)
    }

    /// Called once the app has finished launching. Never returns to the UI.
    @MainActor
    static func start() {
        let args = CommandLine.arguments
        func value(after flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        // V3 show folders.
        // --new-show NAME [--date YYYY-MM-DD] [--under DIR]: create the folder skeleton and exit.
        if let name = value(after: "--new-show") {
            let under = value(after: "--under").map { URL(fileURLWithPath: $0) } ?? ShowFolderStore.defaultParent
            do { let s = try ShowFolderStore.create(name: name, date: value(after: "--date"), under: under); print(s.folder.path); exit(0) }
            catch { print("FAILED: \(error.localizedDescription)"); exit(1) }
        }
        // --show-folder DIR [--confirm-order] [--item ID [--force | --reprocess | --rebuild | --recapture-slides 4,5]] [--recapture-queued] [--reprocess] [--review] [--review-reopen] [--agenda] [--decide ITEM:PAGE:CLICK:KIND[:IN:OUT]] [--capture-pending [--force]] [--preflight] [--stack] [--session-decks] [--handoff]: operate on a show folder and exit.
        if let dir = value(after: "--show-folder") {
            NSApp.setActivationPolicy(.accessory)
            let store: ShowFolderStore
            do { store = try ShowFolderStore(folder: URL(fileURLWithPath: dir)) } catch { print("FAILED: \(error.localizedDescription)"); exit(1) }
            store.onLog = { print($0); fflush(stdout) }
            Task { @MainActor in
                var ok = true
                // --link-source DIR / --unlink-source / --sync-source [--dry-run]: a client's folder (a Drive folder) mirrored into decks/, read only.
                if let src = value(after: "--link-source") { await store.linkSource(URL(fileURLWithPath: (src as NSString).expandingTildeInPath), dryRun: args.contains("--dry-run")) }
                if args.contains("--unlink-source") { store.unlinkSource() }
                if args.contains("--sync-source") { await store.syncSources(dryRun: args.contains("--dry-run")) }
                // --confirm-order: the TD's confirmation of the assessed run order, headless (the SHOW tab's CONFIRM ORDER): the files come in.
                if args.contains("--confirm-order") { store.confirmOrder(); await store.syncSources(); store.rescan() }
                // --item ID [--force]: that item only (a whole show need not be redone for one deck).
                if let id = value(after: "--item"), !args.contains("--review") {
                    guard store.spec.items.contains(where: { $0.id == id }) else { print("FAILED: no item \(id) in \(store.spec.name)"); exit(2) }
                    // --reprocess: the splitter over what is already captured (no PowerPoint); otherwise capture it.
                    if let list = value(after: "--recapture-slides") { await store.recapture(itemID: id, slides: list.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }) }
                    else if args.contains("--rebuild") { await store.reprocess(itemID: id, rebuild: true) }
                    else if args.contains("--reprocess") { await store.reprocess(itemID: id) }
                    else { await store.capture(itemID: id, force: args.contains("--force")) }
                    store.rescan()
                } else if args.contains("--reprocess") {
                    for item in store.spec.orderedItems where item.currentVersion != nil { await store.reprocess(itemID: item.id) }
                    store.rescan()
                }
                // --decide ITEM:PAGE:CLICK:KIND[:IN:OUT]: a review decision without the player (kind = clip, cut, whole, accept, recapture).
                if let d = value(after: "--decide") {
                    let f = d.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
                    guard f.count >= 4, let page = Int(f[1]), let click = Int(f[2]), let kind = ReviewOverride.Kind(rawValue: f[3]) else { print("FAILED: --decide wants ITEM:PAGE:CLICK:KIND[:IN:OUT]"); exit(2) }
                    let hash = store.spec.items.first { $0.id == f[0] }?.currentVersion?.sourceHash
                    store.decide(ReviewOverride(item: f[0], slide: page, click: click, kind: kind, in: f.count > 4 ? Double(f[4]) : nil, out: f.count > 5 ? Double(f[5]) : nil, sourceHash: hash))
                    print("decided: \(f[0]) page \(page) click \(click) \(kind.rawValue)")
                }
                // --agenda: read the schedule deck again into state/rundown.json and print the cues.
                if args.contains("--agenda") {
                    await store.assess(quiet: true)
                    await store.readAgenda(force: true)
                    if let r = try? Rundown.load(from: store.folder) {
                        print("rundown: \(r.cues.count) cue(s)")
                        for (i, c) in r.cues.enumerated() { print(String(format: "  %2d  %-20@ %-18@ %4d min  %-8@ %@%@", i + 1, c.subtitle ?? "", c.timeRange ?? "", c.durationSeconds / 60, c.format.rawValue, c.title, c.speakers.map { "  [\($0)]" } ?? "")) }
                    }
                }
                // --review-reopen: every decision undone (the rows open, the overrides gone), then the queue printed.
                if args.contains("--review-reopen") {
                    store.reopenReview(item: value(after: "--item"))
                    print("review: reopened")
                }
                // --review: the review queue again from what is on disk (reports, manifests, sidecars), no capture.
                if args.contains("--review") {
                    for item in store.spec.orderedItems where value(after: "--item").map({ $0 == item.id }) ?? true {
                        if let v = item.currentVersion ?? item.latestVersion { await store.updateReview(for: item, version: v) }
                    }
                    let open = store.review.open
                    let rows = store.review.entries
                    print("review: \(open.count) open of \(rows.count)" + (rows.isEmpty ? "" : "\n" + rows.map { "  [\($0.status)] \($0.item) \($0.slide.map { "page \($0)" } ?? "") \($0.rule): \($0.reason)" }.joined(separator: "\n")))
                }
                // --recapture-queued: the slides the review queue marked (R rows, R2 rows), every item.
                if args.contains("--recapture-queued") { await store.recaptureQueued(); store.rescan() }
                if args.contains("--capture-pending") { await store.capturePending(force: args.contains("--force")) }
                if args.contains("--stack") { await store.buildStack() }
                if args.contains("--session-decks") { await store.buildSessionDecks() }
                if args.contains("--preflight") { ok = await store.preflight() }
                if args.contains("--handoff") { ok = await store.handOff() && ok }
                print("show \(store.spec.name): \(store.summary)"); fflush(stdout)
                exit(ok && !store.spec.items.contains { $0.status == .failed } ? 0 : 1)
            }
            return
        }
        // --split-builds DECK.arcdeck [--out NEW.arcdeck] [--source DECK.pptx]: a continuous-clip deck into
        // one clip per build and a still per build state (manifest version 3). With --source, an on-entry
        // movie that fills its slide becomes the source movie itself (SourceMovie.swift). The source deck
        // is not touched.
        if let deck = value(after: "--split-builds") {
            let source = URL(fileURLWithPath: deck)
            let dest = value(after: "--out").map { URL(fileURLWithPath: $0) }
                ?? source.deletingPathExtension().appendingPathExtension("builds.arcdeck")
            let pptx = value(after: "--source").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            // --grabs DIR: where ARC Grab's downloads of linked online videos go (default: a grabs folder beside the output).
            let grabs = value(after: "--grabs").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
                ?? dest.deletingLastPathComponent().appendingPathComponent("grabs", isDirectory: true)
            Task {
                do {
                    let t0 = Date()
                    let sum = try await BuildSplitter.convert(deck: source, into: dest, pptx: pptx, grabDir: grabs) { print("  " + $0); fflush(stdout) }
                    let v = await DeckVerifier.verify(arcdeck: dest)
                    print("\(sum.slidesWithBuilds) slide(s) with builds, \(sum.builds) build clip(s), \(sum.stills) still(s), \(sum.sourceMovies) source movie(s) in \(String(format: "%.1f", Date().timeIntervalSince(t0))) s")
                    print("verify: \(v.ok ? "OK" : "FAILED") \(v.detail)")
                    print(dest.path); fflush(stdout); exit(v.ok ? 0 : 1)
                } catch { print("FAILED: \(error.localizedDescription)"); fflush(stdout); exit(1) }
            }
            return
        }
        // --recapture N --deck DECK.arcdeck --in SOURCE: capture source slide N
        // again and put it back into the finished deck (V3, plan 1.3). One page
        // and its media change; every other page keeps its bytes. N is the
        // DECK page as Presenter numbers it, logo pages included.
        if let nText = value(after: "--recapture") {
            guard let page = Int(nText), page > 0 else { print("FAILED: --recapture needs a page number"); exit(2) }
            guard let deckPath = value(after: "--deck") else { print("FAILED: --recapture needs --deck DECK.arcdeck"); exit(2) }
            guard let inPath = value(after: "--in") else { print("FAILED: --recapture needs --in SOURCE (the deck does not record its source's path)"); exit(2) }
            let deck = URL(fileURLWithPath: (deckPath as NSString).expandingTildeInPath)
            let source = URL(fileURLWithPath: (inPath as NSString).expandingTildeInPath)
            NSApp.setActivationPolicy(.accessory)
            NSApp.windows.forEach { $0.close() }
            Task { @MainActor in
                let t0 = Date()
                guard let manifest = DeckManifest.load(from: deck.appendingPathComponent("manifest.json")).manifest else {
                    print("FAILED: \(deck.lastPathComponent) has no manifest"); fflush(stdout); exit(1)
                }
                guard let pptx = SlideReplacer.sourceSlide(forPage: page, in: manifest) else {
                    print("FAILED: page \(page) is a logo page or is not in this deck"); fflush(stdout); exit(1)
                }
                print("recapturing page \(page) (source slide \(pptx)) of \(deck.lastPathComponent)"); fflush(stdout)

                // One slide, captured with the slide before it so the
                // transition into it is the real one; no logo pages.
                let session = source.pathExtension.lowercased() == "key"
                    ? CaptureSession(driver: KeynoteDriver(), frameSource: FrameCapture(), recorder: VideoRecorder())
                    : CaptureSession()
                let scratch = FileManager.default.temporaryDirectory
                    .appendingPathComponent("arc-recapture-\(UUID().uuidString)")
                try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: scratch) }
                session.sourceFile = source
                session.outputDirectory = scratch
                session.addBumpers = false
                session.captureRange = max(1, pptx - 1)...pptx
                activeSession = session
                do {
                    let rep = try await session.run()
                    guard let fresh = rep.output.map({ URL(fileURLWithPath: $0) }) else {
                        print("FAILED: the recapture wrote no deck"); fflush(stdout); exit(1)
                    }
                    let out = try await SlideReplacer.replace(page: page, in: deck, withSlideFrom: fresh)
                    let others = out.changedPages.filter { $0 != page }
                    writeRecaptureReport(to: value(after: "--report"), [
                        "ok": out.verdict.ok && others.isEmpty,
                        "page": out.page, "pptxSlide": out.pptxSlide,
                        "seconds": (Date().timeIntervalSince(t0) * 10).rounded() / 10,
                        "verified": out.verdict.ok, "verifyDetail": out.verdict.detail,
                        "changedPages": out.changedPages, "unexpectedChanges": others,
                        "deck": deck.path])
                    print("page \(out.page) (source slide \(out.pptxSlide)) replaced in \(String(format: "%.1f", Date().timeIntervalSince(t0))) s")
                    print("verify: \(out.verdict.ok ? "OK" : "FAILED") \(out.verdict.detail)")
                    print("pages whose content changed: \(out.changedPages.isEmpty ? "none" : out.changedPages.map(String.init).joined(separator: ", "))")
                    if !others.isEmpty { print("WARNING: \(others.count) page(s) other than \(page) changed") }
                    fflush(stdout)
                    exit(out.verdict.ok && others.isEmpty ? 0 : 1)
                } catch {
                    writeRecaptureReport(to: value(after: "--report"), [
                        "ok": false, "page": page, "pptxSlide": pptx,
                        "seconds": (Date().timeIntervalSince(t0) * 10).rounded() / 10,
                        "error": error.localizedDescription, "deck": deck.path])
                    print("FAILED: \(error.localizedDescription)"); fflush(stdout); exit(1)
                }
            }
            return
        }
        // --verify DECK.arcdeck: the shared verifier's verdict as JSON, exit 0/1.
        if let deck = value(after: "--verify") {
            Task {
                let v = await DeckVerifier.verify(arcdeck: URL(fileURLWithPath: deck))
                let obj: [String: Any] = ["ok": v.ok, "pages": v.pages, "clips": v.clips, "problems": v.problems, "warnings": v.warnings]
                if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) { print(String(decoding: d, as: UTF8.self)) }
                fflush(stdout); exit(v.ok ? 0 : 1)
            }
            return
        }
        // --show FOLDER [--force] [--no-open]: build a show folder with the Swift builder and exit.
        if let i = CommandLine.arguments.firstIndex(of: "--show"), i + 1 < CommandLine.arguments.count {
            let folder = URL(fileURLWithPath: CommandLine.arguments[i + 1])
            let b = ShowBuilder(folder: folder)
            b.force = CommandLine.arguments.contains("--force"); b.openInPresenter = !CommandLine.arguments.contains("--no-open")
            b.log = { print($0); fflush(stdout) }
            Task { @MainActor in
                do { _ = try await b.build(); exit(0) } catch { print("FAILED: \(error.localizedDescription)"); fflush(stdout); exit(1) }
            }
            return
        }
        // --analyze DECK: print the analyzer's JSON and exit (no PowerPoint).
        if let i = CommandLine.arguments.firstIndex(of: "--analyze"), i + 1 < CommandLine.arguments.count {
            let arg = CommandLine.arguments[i + 1]
            let url = arg.hasPrefix("http") ? URL(string: arg)! : URL(fileURLWithPath: arg)
            // Same driver choice as a run: Keynote and Google Slides analyse through their driver.
            // A Google Slides deck is a URL now; `name:<title>` lookup went with
            // the Drive API (it needed the restricted scope Google blocks).
            let a: PPTXAnalysis
            if arg.hasPrefix("http") {
                // The Slides driver reads the deck out of a Chrome it launches
                // and, in a real run, keeps for the capture. Here there is no
                // capture, so close it: an orphaned capture Chrome holds the
                // profile lock and the next launch silently joins it with no
                // debugging port (2026-09-15).
                let driver = GoogleSlidesDriver()
                a = driver.analyze(url) ?? .empty
                driver.terminateChrome()
            } else if url.pathExtension.lowercased() == "key" {
                a = KeynoteDriver().analyze(url) ?? .empty
            } else {
                a = PPTXAnalyzer.analyze(url)
            }
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? enc.encode(a), let text = String(data: data, encoding: .utf8) { print(text) }
            fflush(stdout)
            exit(0)
        }
        if !isWatch { NSApp.setActivationPolicy(.accessory) }
        if !isWatch { NSApp.windows.forEach { $0.close() } }
        let opts: Options
        switch parse(CommandLine.arguments) {
        case .failure(let e):
            stderr("ARC Capture headless: \(e.message)")
            stderr("usage: --headless --in <deck.pptx | Google Slides URL> [--out DIR] [--report FILE.json] [--dwell S] [--max-record S] [--timeout S] [--keep-pngs] [--resume]")
            exit(2)
        case .success(let o): opts = o
        }
        DebugLog.log("Headless", "run \(opts.input.lastPathComponent) -> \(opts.outputDir?.path ?? "beside the deck")")

        // A Google Slides link gets the Chrome kiosk driver; a file gets PowerPoint.
        let session: CaptureSession
        if opts.input.scheme?.hasPrefix("http") == true { session = CaptureSession(driver: GoogleSlidesDriver(), frameSource: FrameCapture(), recorder: VideoRecorder()) }
        else if opts.input.pathExtension.lowercased() == "key" { session = CaptureSession(driver: KeynoteDriver(), frameSource: FrameCapture(), recorder: VideoRecorder()) }
        else { session = CaptureSession() }
        activeSession = session
        session.sourceFile = opts.input
        session.outputDirectory = opts.outputDir
        session.dwellTime = opts.dwell
        session.maxRecordingTime = opts.maxRecord
        session.keepPNGs = opts.keepPNGs
        session.resumeRequested = opts.resume

        Task { @MainActor in
            let deadline = Task { @MainActor in
                try? await Task.sleep(for: .seconds(opts.timeout))
                if !Task.isCancelled {
                    DebugLog.log("Headless", "run timeout after \(Int(opts.timeout)) s")
                    await session.finishCapture()
                    writeReport(session.report, to: opts.reportURL, note: "run timeout after \(Int(opts.timeout)) s")
                    exit(3)
                }
            }
            do {
                let rep = try await session.run()
                deadline.cancel()
                writeReport(rep, to: opts.reportURL, note: nil)
                print(summary(rep))
                exit(0)
            } catch {
                deadline.cancel()
                let rep = (error as? CaptureFailure)?.report ?? session.report
                writeReport(rep, to: opts.reportURL, note: nil)
                stderr("ARC Capture headless: FAILED: \(error.localizedDescription)")
                exit(1)
            }
        }
    }

    /// The recapture's own small report. `open -n -a` throws stdout away, so
    /// a run driven over ssh has nowhere else to read the outcome from.
    private static func writeRecaptureReport(to path: String?, _ obj: [String: Any]) {
        guard let path else { return }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: url)
    }

    @MainActor
    private static func writeReport(_ report: CaptureReport?, to url: URL?, note: String?) {
        guard var rep = report else { return }
        if let note { rep.warnings.append(note) }
        let target = url ?? (rep.output.map { URL(fileURLWithPath: $0).deletingLastPathComponent() } ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("\(URL(fileURLWithPath: rep.source).deletingPathExtension().lastPathComponent).capture-report.json")
        do { try rep.write(to: target); DebugLog.log("Headless", "report \(target.path)") } catch { stderr("report write failed: \(error.localizedDescription)") }
    }

    static func summary(_ r: CaptureReport) -> String {
        let vids = r.slides.filter { $0.type == .video }.count
        return "\(r.ok ? "OK" : "FAIL") \(URL(fileURLWithPath: r.source).lastPathComponent): \(r.slides.count) slides (\(vids) video), expected \(r.expectedSlides), \(String(format: "%.0f", r.wallSeconds)) s, \(r.warnings.count) warning(s)"
    }

    private static func stderr(_ s: String) {
        FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
    }
}

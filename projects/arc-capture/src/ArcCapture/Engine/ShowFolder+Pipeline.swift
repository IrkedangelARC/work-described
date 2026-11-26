//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import AppKit
import ARCShowFormat

/// What a linked source holds, row by row, as the TD confirms it BEFORE anything is copied.
struct SourceAssessment: Equatable {
    struct Row: Identifiable, Equatable {
        enum State: String { case new, changed, mirrored, excluded, gone }
        var id: String            // the run number it will have: "1.04"
        var title: String
        var rel: String           // where it is in the source
        var kind: String
        var size: Int64
        var state: State
        var isHolding: Bool
    }
    struct Passed: Identifiable, Equatable { var id: String { rel }; var rel: String; var reason: String }
    var rows: [Row] = []
    var passedOver: [Passed] = []
    var at = Date()
    var included: [Row] { rows.filter { $0.state != .excluded && $0.state != .gone } }
    var bytes: Int64 { included.reduce(0) { $0 + $1.size } }
    var byKind: [(kind: String, count: Int)] {
        Dictionary(grouping: included.filter { !$0.isHolding }, by: \.kind).map { ($0.key, $0.value.count) }.sorted { $0.0 < $1.0 }
    }
}

/// The SHOW tab's road (ShowPipeline.swift decides, this does): open a target folder, assess it, confirm the
/// order, then capture, build ONE show deck and open it in Presenter as a chain with a STOP.
extension ShowFolderStore {
    // MARK: 1. Open target folder

    /// The show for a target folder: the one already fed by it, else a new one named after it.
    static func openTarget(_ source: URL) throws -> ShowFolderStore {
        let fm = FileManager.default
        let parent = defaultParent
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        for dir in (try? fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)) ?? [] {
            let ledger = dir.appendingPathComponent("state/sources.json")
            guard let data = try? Data(contentsOf: ledger) else { continue }
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            if let l = try? decoder.decode(SourceFolder.Ledger.self, from: data), l.folders.contains(source.path) { return try ShowFolderStore(folder: dir) }
        }
        var name = SourceFolder.clean(source.lastPathComponent)
        if name.isEmpty { name = "Show" }
        var candidate = name, n = 2
        while fm.fileExists(atPath: parent.appendingPathComponent(candidate).path) { candidate = "\(name) \(n)"; n += 1 }
        return try create(name: candidate, date: nil)
    }

    // MARK: 2. Assess (reads the listing only: nothing is downloaded)

    func assess(quiet: Bool = false) async {
        guard let source = linkedSource else { assessLocal(); return }
        let root = source.resolvingSymlinksInPath()
        if !quiet { setActivity(Activity(step: .assess, title: "Assessing \(source.lastPathComponent)", detail: "reading the listing, nothing is downloaded")) }
        defer { if !quiet { setActivity(nil) } }
        guard let entries = await Task.detached(priority: .utility, operation: { Self.list(root) }).value else {
            if !quiet { say("source not reachable: \(source.path) (is Google Drive running?)") }
            return
        }
        let takes: (String) -> Bool = { ext in ext == "gslides" || Self.kind(of: URL(fileURLWithPath: "x.\(ext)")).map { $0 != .arcdeck } == true }
        let excluded = Set(sourceLedger.excluded ?? [])
        // Planned WITHOUT the exclusions so an excluded file still shows the number it would have.
        let all = SourceFolder.plan(entries: entries, ledger: sourceLedger.links, supported: takes)
        let size = Dictionary(entries.map { ($0.rel, $0.size) }, uniquingKeysWith: { a, _ in a })
        let changed = Set(all.actions.filter { $0.kind == .update }.map(\.deck)), added = Set(all.actions.filter { $0.kind == .add }.map(\.deck))
        var a = SourceAssessment()
        a.rows = all.links.map { l in
            let parsed = Self.itemID(from: l.deck)
            let ext = (l.rel as NSString).pathExtension.lowercased()
            let kind = ext == "gslides" ? "google slides" : (Self.kind(of: URL(fileURLWithPath: l.deck))?.rawValue ?? ext)
            let state: SourceAssessment.Row.State = excluded.contains(l.rel) ? .excluded : l.goneSince != nil ? .gone : added.contains(l.deck) ? .new : changed.contains(l.deck) ? .changed : .mirrored
            return .init(id: parsed.id, title: parsed.title, rel: l.rel, kind: kind, size: size[l.rel] ?? l.size, state: state, isHolding: SourceFolder.isHoldingSlide(title: parsed.title))
        }.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
        // The reason comes from the scan, which knows it. It used to be guessed back from the path here,
        // and that guess knew only two of the five causes.
        a.passedOver = all.ignored.map { .init(rel: $0.rel, reason: $0.reason) }
        let first = assessment == nil
        assessment = a
        await measureAspects()
        if !quiet || first {
            let kinds = a.byKind.map { "\($0.count) \($0.kind)" }.joined(separator: ", ")
            say("assessed \(source.lastPathComponent): \(a.included.count) file(s) for the show (\(kinds)), \(ByteCountFormatter.string(fromByteCount: a.bytes, countStyle: .file)); \(a.passedOver.count) passed over")
            // Never the count on its own. Grouped by reason, so 21 files are a few lines rather than 21.
            for (reason, items) in Dictionary(grouping: a.passedOver, by: \.reason).sorted(by: { $0.key < $1.key }) {
                say("  passed over, \(reason): \(items.map(\.rel).sorted { $0.localizedStandardCompare($1) == .orderedAscending }.joined(separator: ", "))")
            }
            if let h = a.included.first(where: \.isHolding) { say("holding slide: \(h.id) \(h.title)") } else { say("no holding slide in the folder (name one \"S0.0 Holding Slide ...\"): the ARC mark stands in") }
        }
        await readAgenda(force: false)
    }

    // MARK: 3. The agenda

    /// The rundown for Presenter's cue timer, read from the agenda deck in the folder (docs/PLAN_capture_gui.md
    /// follow-up, 2026-09-19: "can capture populate the timer from the ppt agenda?"). Rules first, the
    /// workstation's model for the rows they refuse, REVIEW for what neither could read; the deck is left out of
    /// the run (it is not a talk). `force`: read again even if a rundown is already there.
    func readAgenda(force: Bool) async {
        guard let a = assessment, let source = linkedSource else { return }
        let root = source.resolvingSymlinksInPath()
        if !force, sourceLedger.agenda != nil, FileManager.default.fileExists(atPath: Rundown.fileURL(in: folder).path) { return }
        // Named like an agenda first; then any small PowerPoint that reads like one.
        let named = { (r: SourceAssessment.Row) -> Bool in ["schedule", "agenda", "program", "run of show", "rundown"].contains { r.title.lowercased().contains($0) } }
        let candidates = a.rows.filter { $0.state != .gone && $0.kind == "powerpoint" && $0.rel.lowercased().hasSuffix(".pptx") && $0.size < 40_000_000 }
            .sorted { (named($0) ? 0 : 1, $0.id) < (named($1) ? 0 : 1, $1.id) }
        for row in candidates {
            let url = root.appendingPathComponent(row.rel)
            let slides = await Task.detached(priority: .utility) { SlideText.paragraphs(of: url) }.value
            guard AgendaParser.looksLikeAgenda(slides) else { continue }
            var agenda = AgendaParser.parse(slides)
            let before = agenda.refused.count
            if before > 0 {
                say("agenda: \(before) row(s) the rules could not read; asking the local model (\(AgendaRepair.baseURL))")
                if let fixes = await AgendaRepair.repair(agenda.refused, log: { [weak self] l in self?.say("  " + l) }) {
                    let n = AgendaRepair.apply(fixes, to: &agenda)
                    say("  \(n) row(s) repaired")
                }
            }
            let rundown = agenda.rundown(name: spec.name, arcNumber: nil)
            do { try rundown.save(to: folder) } catch { say("agenda: rundown could not be written: \(error.localizedDescription)"); return }
            sourceLedger.agenda = row.rel
            saveSources()
            // REVIEW carries the rows to check, in plain words, with the raw line in the evidence.
            let entries = agenda.refused.map { r in
                ReviewEntry(item: "AGENDA", title: row.title, slide: r.slide, rule: "R11",
                            reason: "\(r.day) \(r.timeRange): \(r.refused ?? "") — \(r.title.prefix(60))", evidence: ["raw": r.raw, "speakers": r.speakers])
            }
            review.replace(item: "AGENDA", with: entries)
            do { try review.save(to: folder) } catch { say("review.json could not be written: \(error.localizedDescription)") }
            say("agenda: \(row.id) \(row.title): \(agenda.days.count) day(s), \(rundown.cues.count) cue(s), \(agenda.talks.count) talk(s); rundown written to state/rundown.json"
                + (agenda.refused.isEmpty ? "" : "; \(agenda.refused.count) row(s) to check in REVIEW"))
            if row.state != .excluded {
                say("  the agenda deck is not a talk: left out of the run (PUT BACK if it should play)")
                await setExcluded(row.rel, true)
            }
            return
        }
        if force { say("agenda: no deck in the folder reads as a schedule (a slide per day with a time column)") }
    }

    /// A show with no linked source: what is in decks/ is the assessment.
    private func assessLocal() {
        rescan()
        var a = SourceAssessment()
        a.rows = spec.orderedItems.filter { $0.status != .superseded }.map { item in
            let bytes = (try? FileManager.default.attributesOfItem(atPath: url(of: item).path)[.size] as? NSNumber)?.int64Value ?? 0
            return .init(id: item.id, title: item.title, rel: item.source, kind: item.kind.rawValue, size: bytes, state: .mirrored, isHolding: SourceFolder.isHoldingSlide(title: item.title))
        }
        assessment = a
    }

    // MARK: 4. Confirm the run order

    var plannedOrder: [String] { (assessment?.included ?? []).map(\.id) }

    func confirmOrder() {
        sourceLedger.confirmedOrder = plannedOrder
        saveSources()
        say("run order confirmed: \(plannedOrder.count) item(s), \(plannedOrder.first ?? "") to \(plannedOrder.last ?? "")")
    }

    /// Leave a source file out of the show (the client's own combined deck), or take it back in.
    func setExcluded(_ rel: String, _ out: Bool) async {
        var set = Set(sourceLedger.excluded ?? [])
        if out { set.insert(rel) } else { set.remove(rel) }
        sourceLedger.excluded = set.sorted()
        saveSources()
        say("\(out ? "left out of" : "back in") the show: \(rel)")
        await assess(quiet: true)
    }

    /// SYNC pressed by hand: bring files in when the order is confirmed, else only look again.
    func confirmedSync() async {
        if sourceLedger.confirmedOrder != nil { await syncSources() }
        await assess()
    }

    // MARK: 6. The show deck

    /// What goes into the ONE show deck: every ready item in run order, without the holding slide (it is the
    /// logo page, not a talk) and without what the TD excluded.
    var showDeckItems: [ShowSpec.Item] {
        let excludedDecks = Set(sourceLedger.links.filter { (sourceLedger.excluded ?? []).contains($0.rel) }.map { Self.itemID(from: $0.deck).id })
        return spec.orderedItems.filter { $0.status != .superseded && $0.currentVersion != nil && !SourceFolder.isHoldingSlide(title: $0.title) && !excludedDecks.contains($0.id) }
    }

    func markShowDeckBuilt(from items: [ShowSpec.Item]) {
        sourceLedger.builtFrom = Dictionary(items.map { ($0.id, $0.current ?? 0) }, uniquingKeysWith: { a, _ in a })
        sourceLedger.presentedAt = nil
        saveSources()
    }

    var showDeckURL: URL? { spec.mergedDeck.map { folder.appendingPathComponent($0) }.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil } }
    var showDeckIsCurrent: Bool {
        guard showDeckURL != nil, let built = sourceLedger.builtFrom else { return false }
        return built == Dictionary(showDeckItems.map { ($0.id, $0.current ?? 0) }, uniquingKeysWith: { a, _ in a })
    }

    // MARK: 7. Open in Presenter: the ONE show deck, not a tab per presentation

    /// Presenter opens the show FOLDER (`POST /show`): with a show deck in show.json that is ONE tab, and
    /// Presenter keeps watching the folder, so the next version of the show deck is staged beside it.
    @discardableResult
    func openInPresenter() async -> Bool {
        guard let deck = showDeckURL else { say("no show deck to open: build it first"); return false }
        guard await handOff() else { return false }
        sourceLedger.presentedAt = Date(); saveSources()
        say("open in Presenter: \(deck.lastPathComponent) (one tab, in preview; TAKE puts it live; later versions are staged beside it)")
        return true
    }

    // MARK: Shape (4:3 in a 16:9 show), measured once a file is in decks/: nothing is downloaded to find it out

    func measureAspects() async {
        let wanted = spec.items.filter { $0.status != .superseded && aspects[$0.id] == nil && !$0.source.hasPrefix("http") }.map { ($0.id, url(of: $0)) }
        guard !wanted.isEmpty else { return }
        let found = await Task.detached(priority: .utility) { wanted.compactMap { id, url in AspectProbe.aspect(of: url).map { (id, $0) } } }.value
        for (id, a) in found { aspects[id] = a }
    }

    /// The shape of the show (the most common among the talks) and the items that are another shape.
    var aspectReport: (show: Double, odd: [(id: String, aspect: Double)])? {
        let talks = spec.orderedItems.filter { !SourceFolder.isHoldingSlide(title: $0.title) }.compactMap { aspects[$0.id] }
        guard let show = AspectCheck.showAspect(talks) else { return nil }
        let odd = spec.orderedItems.compactMap { i in aspects[i.id].flatMap { AspectCheck.differs($0, from: show) ? (i.id, $0) : nil } }
        return (show, odd)
    }

    // MARK: AUTO CAPTURE (armed by the TD, and only when nobody is at the Mac)

    var isArmed: Bool { sourceLedger.armed == true }
    func setArmed(_ on: Bool) {
        sourceLedger.armed = on; saveSources(); autoNote = ""
        say(on ? "AUTO CAPTURE ARMED: a change in the target folder is captured, built and staged in Presenter once nobody has touched this Mac for \(AutoCapture.idleNeeded) s"
               : "AUTO CAPTURE off: changes are brought in and marked, the TD presses")
    }

    func autoCaptureIfDue() async {
        let idle = Int(CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!))
        switch AutoCapture.decide(armed: isArmed, facts: pipelineFacts, busy: busy || syncing, idleSeconds: idle) {
        case .nothing: autoNote = ""
        case .needsTD(let why): autoNote = "AUTO is armed, but \(why)"
        case .waitForIdle(let s): autoNote = "AUTO is armed and has work: it starts after \(s) s more of hands off the keyboard and mouse"
        case .run:
            autoNote = ""
            say("AUTO CAPTURE: the target folder changed and nobody has touched this Mac for \(idle) s: starting")
            await run(from: .capture)
        }
    }

    // MARK: The facts, and the chain

    var pipelineFacts: ShowPipeline.Facts {
        var f = ShowPipeline.Facts()
        f.hasShow = linkedSource != nil || !spec.items.isEmpty      // an empty show has not been given its folder yet
        let a = assessment
        f.assessed = a != nil
        f.planned = a?.included.filter { !$0.isHolding }.count ?? 0
        f.holdingSlide = a?.included.first(where: \.isHolding).map { "\($0.id) \($0.title)" }
        if let rel = sourceLedger.agenda, let row = a?.rows.first(where: { $0.rel == rel }) {
            f.agendaDeck = "\(row.id) \(row.title)"
            if let r = try? Rundown.load(from: folder) {
                f.agendaCues = r.cues.count
                f.agendaTalks = r.cues.filter { ![.breakTime, .social].contains($0.format) }.count
                f.agendaDays = Set(r.cues.compactMap(\.subtitle)).count
            }
            f.agendaRefused = review.entries.filter { $0.item == "AGENDA" && $0.status == "open" }.count
        }
        f.orderConfirmed = sourceLedger.confirmedOrder != nil
        f.orderChanged = sourceLedger.confirmedOrder.map { $0 != plannedOrder } ?? false
        f.toBringIn = a?.included.filter { $0.state == .new || $0.state == .changed }.count ?? 0
        // An item LEFT OUT of the show is not counted: its failure must not hold the build (8.90, 2026-09-19).
        let excluded = Set(sourceLedger.excluded ?? [])
        let outByID = Set((a?.rows ?? []).filter { excluded.contains($0.rel) }.map(\.id))
        let live = spec.items.filter { $0.status != .superseded && !outByID.contains($0.id) }
        f.pending = live.filter { $0.status == .pending || $0.status == .updated }.count
        let failedItems = live.filter { $0.status == .failed }
        f.failed = failedItems.count
        f.failedIDs = failedItems.map(\.id)
        f.failedDetail = failedItems.first?.latestVersion?.verifyDetail.map { $0.split(separator: "(").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? $0 }
        f.ready = live.filter { $0.status == .ready }.count
        f.blackUndecided = review.entries.filter { e in e.rule == "R12" && (e.status == "open" || e.status == "recapture") && live.contains { $0.id == e.item } }.count
        f.showDeckBuilt = showDeckURL != nil
        f.showDeckCurrent = showDeckIsCurrent
        f.presented = sourceLedger.presentedAt != nil
        f.running = activity?.step
        return f
    }

    /// The way round a failed capture: the failed items are left out of the show and the deck is built without them.
    func leaveOutFailedAndBuild() async {
        let failed = spec.items.filter { $0.status == .failed }.map(\.id)
        for id in failed {
            if let row = assessment?.rows.first(where: { $0.id == id }) { await setExcluded(row.rel, true) }
            else { say("\(id): not in the source listing; it cannot be left out from here") }
        }
        await run(from: .build)
    }

    /// Capture, build, open: no decision is left after the order is confirmed, so they run as one chain.
    /// STOP ends it after the item it is on; a failure ends it where it failed.
    func run(from step: ShowPipeline.Step) async {
        stopRequested = false
        for s in ShowPipeline.chain(from: step) {
            if stopRequested { say("stopped before: \(s.title)"); break }
            switch s {
            case .capture:
                if linkedSource != nil { await syncSources() }
                if stopRequested { break }
                await capturePending()
                await assess(quiet: true)
                let failed = spec.items.filter { $0.status == .failed }
                if !failed.isEmpty { say("\(failed.count) capture(s) FAILED (\(failed.map(\.id).joined(separator: ", "))): the show deck is not built with a hole in it"); setActivity(nil); return }
                if !pendingItems.isEmpty { setActivity(nil); return }          // stopped part way
                // The pre-show check runs HERE, before anything is built from the captures: a deck that does not
                // verify, a source that went missing, an iCloud placeholder ends the chain before Presenter sees it.
                setActivity(Activity(step: .capture, title: "Preflight", detail: "every item captured and verified, before the show deck is built"))
                guard await preflight() else { say("preflight FAILED: the show deck is not built from this"); setActivity(nil); return }
            case .build:
                setActivity(Activity(step: .build, title: "Building the show deck", detail: "\(showDeckItems.count) presentation(s), the holding slide before, between and after"))
                await buildStack()
                guard showDeckIsCurrent else { setActivity(nil); return }
            case .present:
                setActivity(Activity(step: .present, title: "Opening in ARC Presenter", detail: spec.mergedDeck ?? ""))
                await openInPresenter()
            default: break
            }
        }
        setActivity(nil)
    }
}

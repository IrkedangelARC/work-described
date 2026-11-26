//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation
import ARCShowFormat

/// The review queue (docs/PLAN_review_queue.md, phase 1): after the run, the captures a
/// human should look at, each with the rule that put it there, the evidence, and the kept
/// recording. Lives in the show folder as `state/review.json`. A clean run has none.
struct ReviewEntry: Codable, Identifiable, Equatable {
    var id: String { "\(item)#\(slide ?? 0)#\(rule)" }
    let item: String
    let title: String
    /// The deck page (manifest slide number), when the rule is about one page.
    var slide: Int?
    /// R1 to R10, as in the plan.
    let rule: String
    /// One line, plain words: what the human is being asked to decide.
    let reason: String
    /// The numbers behind it, for the row's hover and the report.
    var evidence: [String: String] = [:]
    /// The kept recording of that page, relative to the show folder, when there is one.
    var recording: String? = nil
    /// The click marks in that recording, seconds from its start.
    var marks: [Double]? = nil
    var status: String = "open"
    var createdAt: Date = Date()
}

/// A decision from the review player (phase 2), keyed by item, deck page and click (0 = the whole
/// page). The splitter reads these BEFORE its own probes, so a re-run of the item applies them again
/// without asking. A new source hash drops them, with a note.
struct ReviewOverride: Codable, Equatable, Identifiable {
    enum Kind: String, Codable {
        case clip       // the build is an animation: `in` to `out` of the recording (click 0: `out` = where the page's clip stops)
        case cut        // the build is a cut to its still
        case whole      // click 0: the page is ONE clip, first mark to the leaving click (R8)
        case accept     // click 0: as captured, no doubt raised again
        case recapture  // click 0: the page is to be captured again (phase 3)
        case sourceMovie // click 0: the movie inside the deck is the page's clip, whatever was recorded
    }
    var id: String { "\(item)#\(slide)#\(click)" }
    let item: String
    let slide: Int
    let click: Int
    var kind: Kind
    var `in`: Double? = nil
    var out: Double? = nil
    var sourceHash: String? = nil
    var decidedAt: Date = Date()
}

struct ReviewQueue: Codable, Equatable {
    var version = 1
    var entries: [ReviewEntry] = []
    var overrides: [ReviewOverride] = []

    init() {}
    /// A queue written before overrides existed still loads.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        entries = try c.decodeIfPresent([ReviewEntry].self, forKey: .entries) ?? []
        overrides = try c.decodeIfPresent([ReviewOverride].self, forKey: .overrides) ?? []
    }

    static func url(in folder: URL) -> URL { folder.appendingPathComponent("state/review.json") }

    static func load(from folder: URL) -> ReviewQueue {
        guard let data = try? Data(contentsOf: url(in: folder)) else { return ReviewQueue() }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode(ReviewQueue.self, from: data)) ?? ReviewQueue()
    }

    func save(to folder: URL) throws {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]; enc.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("state"), withIntermediateDirectories: true)
        try enc.encode(self).write(to: Self.url(in: folder), options: .atomic)
    }

    /// Replace one item's entries (a new capture of the item speaks for it). A row already decided
    /// (accepted, recapture) keeps its status when the same doubt comes back.
    mutating func replace(item: String, with new: [ReviewEntry]) {
        let old = Dictionary(entries.filter { $0.item == item }.map { ($0.id, $0.status) }, uniquingKeysWith: { a, _ in a })
        entries.removeAll { $0.item == item }
        entries.append(contentsOf: new.map { e in
            var e = e
            if e.status == "open", let s = old[e.id], s != "open" { e.status = s }
            return e
        })
        entries.sort { ($0.item, $0.slide ?? 0, $0.rule) < ($1.item, $1.slide ?? 0, $1.rule) }
    }

    /// Every decision of an item (or of all) undone: the rows open again, the overrides gone (2026-09-19:
    /// "I approved the slides in capture because it was not clear and I didn't have the tools to fix it. Let's redo this").
    mutating func reopen(item: String? = nil) {
        for i in entries.indices where item == nil || entries[i].item == item { entries[i].status = "open" }
        overrides.removeAll { item == nil || $0.item == item }
    }

    mutating func setStatus(_ status: String, of id: String) {
        for i in entries.indices where entries[i].id == id { entries[i].status = status }
    }

    var open: [ReviewEntry] { entries.filter { $0.status == "open" } }

    /// The SOURCE slides of an item the queue says to capture again (phase 3): rows marked
    /// recapture (their deck page mapped through the manifest) and R2 rows (the session's own list
    /// of slides the show passed without a page), open or marked.
    func recaptureSlides(item: String, manifest: DeckManifest?) -> [Int] {
        var out = Set<Int>()
        for e in entries where e.item == item {
            if e.rule == "R2", e.status == "open" || e.status == "recapture" {
                for n in (e.evidence["slides"] ?? "").split(separator: ",").compactMap({ Int($0.trimmingCharacters(in: .whitespaces)) }) { out.insert(n) }
            } else if e.status == "recapture", let page = e.slide {
                if let p = manifest?.slides.first(where: { $0.slide == page && $0.role == nil }) { out.insert(p.pptxSlide ?? p.slide) }
                else if manifest == nil { out.insert(page) }
            }
        }
        return out.sorted()
    }

    /// After a recapture of SOME slides and a merge, the rows about the OTHER pages still stand: they
    /// are re-mapped from the old deck's page numbers to the new deck's (logo pages come and go).
    /// Rows about the recaptured slides are dropped, the new evaluation speaks for those.
    static func carry(_ rows: [ReviewEntry], from old: DeckManifest, to new: DeckManifest, recaptured: Set<Int>) -> [ReviewEntry] {
        func source(_ page: Int, in m: DeckManifest) -> Int? { m.slides.first { $0.slide == page && $0.role == nil }.map { $0.pptxSlide ?? $0.slide } }
        func page(_ src: Int, in m: DeckManifest) -> Int? { m.slides.first { $0.role == nil && ($0.pptxSlide ?? $0.slide) == src }?.slide }
        return rows.compactMap { e in
            guard let p = e.slide else { return e.rule == "R2" || e.rule == "R1" ? nil : e }   // the run's own verdicts belong to the new run
            guard let src = source(p, in: old), !recaptured.contains(src), let np = page(src, in: new) else { return nil }
            var e = e
            e.slide = np
            return e
        }
    }

    // MARK: Overrides

    mutating func set(_ o: ReviewOverride) {
        overrides.removeAll { $0.id == o.id }
        overrides.append(o)
        overrides.sort { ($0.item, $0.slide, $0.click) < ($1.item, $1.slide, $1.click) }
    }

    func overrides(for item: String) -> [ReviewOverride] { overrides.filter { $0.item == item } }

    /// Drop an item's overrides made against another source. Returns how many went.
    @discardableResult
    mutating func dropOverrides(item: String, unlessHash hash: String?) -> Int {
        let before = overrides.count
        overrides.removeAll { $0.item == item && $0.sourceHash != hash }
        return before - overrides.count
    }
}

/// What the splitter writes beside a kept recording: `review/slide_NNN.json` in the deck.
struct ReviewSidecar: Codable, Equatable {
    struct Flag: Codable, Equatable {
        let rule: String
        let reason: String
        var evidence: [String: String] = [:]
    }
    let slide: Int
    /// The recording's file, relative to the deck.
    let recording: String
    let marks: [Double]
    var flags: [Flag]
}

/// The rules, pure, so they are tested without a capture.
enum ReviewRules {
    /// "first-settle timeout" joined these on 2026-09-20: the opening slide
    /// that never stilled is kept as its live frame, and that page is a guess
    /// until somebody looks at it.
    static let watchdogEndings: Set<String> = ["quiet", "timeout", "first-settle timeout"]
    /// A movie shorter than its declared length by more than this is short.
    static let movieShortfall = 0.15

    static func evaluate(item: ShowSpec.Item, report: CaptureReport?, verifyDetail: String, manifest: DeckManifest?,
                         sidecars: [ReviewSidecar], deckRel: String?) -> [ReviewEntry] {
        var out: [ReviewEntry] = []
        let byPage = Dictionary(sidecars.map { ($0.slide, $0) }, uniquingKeysWith: { a, _ in a })
        /// The deck page for a source slide number (the manifest is renumbered around the logo pages).
        func page(source n: Int) -> DeckManifest.Slide? { manifest?.slides.first { $0.role == nil && ($0.pptxSlide ?? $0.slide) == n } }
        func add(_ rule: String, _ reason: String, slide: Int? = nil, _ evidence: [String: String] = [:], sidecar: ReviewSidecar? = nil, clip: String? = nil) {
            var e = ReviewEntry(item: item.id, title: item.title, slide: slide, rule: rule, reason: reason, evidence: evidence)
            if let sidecar, let deckRel { e.recording = deckRel + "/" + sidecar.recording; e.marks = sidecar.marks }
            else if let clip, let deckRel { e.recording = deckRel + "/" + clip }   // a movie page's clip is its recording
            guard !out.contains(where: { $0.id == e.id }) else { return }
            out.append(e)
        }

        // R9: a kind this build cannot capture.
        if item.kind == .other {
            add("R9", "the item's kind is not one this version of ARC Capture understands: leave it out, or capture it with a newer version", ["kind": item.kind.rawValue])
            return out
        }
        // R1: the run failed.
        if let report, !report.ok {
            let err = report.error ?? verifyDetail
            // R2: slides the show passed without us: recapture those, not the item.
            if let range = err.range(of: "shown by the deck but not captured") {
                let nums = err[..<range.lowerBound].split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
                add("R2", "slide\(nums.count == 1 ? "" : "s") \(nums.map(String.init).joined(separator: ", ")) passed without a page: recapture \(nums.count == 1 ? "it" : "them")",
                    ["slides": nums.map(String.init).joined(separator: ",")])
            } else {
                add("R1", "the capture failed: \(err.prefix(160)); recapture, or accept what is there", ["error": String(err.prefix(300))])
            }
        } else if report == nil, !verifyDetail.isEmpty, item.status == .failed {
            add("R1", "the capture failed: \(verifyDetail.prefix(160))", ["error": String(verifyDetail.prefix(300))])
        }

        // R6: a click that drew nothing and moved nothing (the session's own red flag, any driver).
        var noOpSlides = Set<Int>()
        for w in report?.warnings ?? [] where w.contains("changed nothing on screen") {
            let nums = w.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            guard let n = nums.first else { continue }
            let click = nums.count > 1 ? nums[1] : 0
            noOpSlides.insert(n)
            let p = page(source: n)
            add("R6", "slide \(n) click \(click) changed nothing on screen: play the slide yourself; a dropped click is recaptured, a build with nothing to draw is accepted",
                slide: p?.slide ?? n, ["warning": w, "click": "\(click)"], sidecar: p.flatMap { byPage[$0.slide] })
        }
        // R5: a build count the XML disagrees with (the session's warning line), unless R6 already says why.
        for w in report?.warnings ?? [] where w.contains("the source has") && w.contains("build") {
            let n = w.split(whereSeparator: { !$0.isNumber }).first.flatMap { Int($0) }
            if let n, noOpSlides.contains(n) { continue }
            let p = n.flatMap(page(source:))
            add("R5", w + ": accept the still, or recapture", slide: p?.slide ?? n, ["warning": w], sidecar: p.flatMap { byPage[$0.slide] }, clip: p?.file)
        }

        // R7 (the session's own finding): playback stopped before the movie's end, the clip ends at the stillness.
        for w in report?.warnings ?? [] {
            guard let r = w.range(of: "playback stopped "), w.contains("into the movie") else { continue }
            let n = w.split(whereSeparator: { !$0.isNumber }).first.flatMap { Int($0) }
            let stopped = w[r.upperBound...].split(whereSeparator: { !$0.isNumber && $0 != "." }).first.flatMap { Double($0) }
            let declared = n.flatMap { report?.analysis.slideDurations[$0] }
            let p = n.flatMap(page(source:))
            var ev = ["warning": w]
            if let stopped { ev["stopped"] = String(format: "%.0f", stopped) }
            if let declared { ev["declared"] = String(format: "%.1f", declared) }
            let head = "slide \(n.map(String.init) ?? "?"): playback stopped \(stopped.map { String(format: "%.0f", $0) } ?? "?") s into a \(declared.map { String(format: "%.0f", $0) } ?? "?") s movie"
            add("R7", head + ": mark where it should end, or recapture with a longer hold", slide: p?.slide, ev, sidecar: p.flatMap { byPage[$0.slide] }, clip: p?.file)
        }

        // R8: auto-advance and loops, from the deck's own timing.
        if let a = report?.analysis {
            for (n, secs) in a.autoAdvanceSlides.sorted(by: { $0.key < $1.key }) {
                add("R8", "slide \(n) advances by itself after \(String(format: "%.1f", secs)) s: keep it as one timed clip, or mark its edges", slide: n, ["advTm": String(format: "%.2f", secs)])
            }
            for n in a.loopingSlides.sorted() where a.autoAdvanceSlides[n] == nil {
                add("R8", "slide \(n) loops its movie: one period is kept; mark its edges if the loop point is wrong", slide: n, ["loop": "indefinite"])
            }
        }

        guard let manifest else { return out }
        for page in manifest.slides where page.role == nil {
            let n = page.pptxSlide ?? page.slide
            let sc = byPage[page.slide]
            // R3: the strip ended by the watchdog, not by stillness.
            if let ended = page.measured?.endedBy, watchdogEndings.contains(ended) {
                let how = ended == "quiet" ? "quiet watchdog"
                        : ended == "first-settle timeout" ? "first-settle ceiling (the opening slide never stilled; this page is the live frame)"
                        : "timeout"
                add("R3", "slide \(n) was ended by the \(how), not by stillness: check where the animation really stops",
                    slide: page.slide, ["endedBy": ended, "settleMs": page.measured?.settleMs.map(String.init) ?? "?"], sidecar: sc)
            }
            // R7: a movie shorter than it should be.
            if page.type == .video, let declared = report?.analysis.slideDurations[n], declared > 1, let got = page.measured?.clipSeconds, got > 0,
               got < declared * (1 - movieShortfall) {
                add("R7", "slide \(n): the movie runs \(String(format: "%.0f", declared)) s in the deck but \(String(format: "%.0f", got)) s were recorded: mark its end, or recapture with a longer hold",
                    slide: page.slide, ["declared": String(format: "%.1f", declared), "recorded": String(format: "%.1f", got)], sidecar: sc, clip: page.file)
            }
            // R4, R6, R10: the splitter's own doubts, from its sidecar.
            for f in sc?.flags ?? [] {
                add(f.rule, f.reason, slide: page.slide, f.evidence, sidecar: sc)
            }
        }
        // R13: the slide links to an online video that was not fetched (OnlineVideo.swift): the page is as
        // captured, a click on it in the room would have opened a browser. Read from the deck, not the report:
        // a reprocess fetches again without a new report.
        for page in manifest.slides where page.role == nil && page.sourceMovie != true {
            guard let m = page.media?.first(where: { $0.url != nil }), let url = m.url else { continue }
            let why = m.name.hasPrefix("not fetched: ") ? String(m.name.dropFirst(13)) : m.name
            add("R13", "slide \(page.pptxSlide ?? page.slide) links to an online video that was not fetched (\(why)): install ARC Grab 1.5.0 or get online and REPROCESS; ACCEPT leaves the page as captured",
                slide: page.slide, ["url": url, "why": why], sidecar: byPage[page.slide], clip: page.file)
        }
        return out
    }
}

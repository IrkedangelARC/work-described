//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation
import PDFKit
import ARCShowFormat

/// Changed-slides-only recapture (V3, design section 4.2). A slide's
/// version-2 clip holds the PREVIOUS slide's builds and the transition in,
/// so a slide is reusable only when its own hash and its predecessor's are
/// both unchanged. Everything else is captured again, as contiguous ranges
/// that start one slide early so the transition in is the real one, and
/// the ranges are merged with the reused pages and clips into a new deck.
enum RecapturePlan: Equatable {
    /// Nothing changed at the slide level (the file was re-saved).
    case unchanged
    /// Too much changed, or nothing to diff against: capture the whole show.
    case full(reason: String)
    /// Capture these pptx ranges (each already widened by one at the front);
    /// `reuse` maps a new pptx slide number to the old one whose assets serve.
    case partial(ranges: [ClosedRange<Int>], changed: [Int], reuse: [Int: Int])

    /// `oldHashes` / `newHashes`: per pptx slide, 1-based by position. `hidden`:
    /// new pptx slides the show skips. Full when more than `fullAbove` of the
    /// visible slides changed.
    static func make(oldHashes: [String], newHashes: [String], hidden: Set<Int> = [], slideCount: Int? = nil, fullAbove: Double = 0.6) -> RecapturePlan {
        guard !oldHashes.isEmpty, !newHashes.isEmpty else { return .full(reason: "no slide hashes to diff") }
        let total = slideCount ?? newHashes.count
        guard newHashes.count == total else { return .full(reason: "hash count \(newHashes.count) does not match \(total) slides") }
        // Old (hash, predecessorHash) pairs, by old pptx number.
        var oldByPair: [String: Int] = [:]
        for (i, h) in oldHashes.enumerated() {
            let prev = i > 0 ? oldHashes[i - 1] : "^"
            if oldByPair["\(prev)|\(h)"] == nil { oldByPair["\(prev)|\(h)"] = i + 1 }
        }
        var reuse: [Int: Int] = [:]
        var changed: [Int] = []
        for (i, h) in newHashes.enumerated() {
            let n = i + 1
            if hidden.contains(n) { continue }
            let prev = i > 0 ? newHashes[i - 1] : "^"
            if let old = oldByPair["\(prev)|\(h)"] { reuse[n] = old } else { changed.append(n) }
        }
        let visible = max(1, newHashes.count - hidden.count)
        if changed.isEmpty { return .unchanged }
        if Double(changed.count) / Double(visible) > fullAbove { return .full(reason: "\(changed.count) of \(visible) slides changed") }
        return .partial(ranges: ranges(around: changed, last: total), changed: changed, reuse: reuse)
    }

    /// The ranges that capture `slides` (sorted source numbers): contiguous runs, each starting one
    /// slide earlier so the transition INTO the first wanted slide is the real one (bounded at 1) and
    /// ending one slide LATER so the last wanted slide's builds are walked (a range capture keeps no
    /// recording of leaving its last slide; bounded at `last`), touching runs merged. Also the review
    /// queue's recapture of slides (phase 3).
    static func ranges(around slides: [Int], last: Int? = nil) -> [ClosedRange<Int>] {
        let changed = Array(Set(slides)).sorted()
        guard let first = changed.first else { return [] }
        func hi(_ n: Int) -> Int { last.map { min($0, n + 1) } ?? n + 1 }
        var ranges: [ClosedRange<Int>] = []
        var runStart = first, runEnd = first
        for n in changed.dropFirst() {
            if n <= runEnd + 1 { runEnd = n } else { ranges.append(max(1, runStart - 1)...hi(runEnd)); runStart = n; runEnd = n }
        }
        ranges.append(max(1, runStart - 1)...hi(runEnd))
        var merged: [ClosedRange<Int>] = []
        for r in ranges {
            if let last = merged.last, r.lowerBound <= last.upperBound + 1 { merged[merged.count - 1] = last.lowerBound...max(last.upperBound, r.upperBound) }
            else { merged.append(r) }
        }
        return merged
    }
}

/// Assemble a new arcdeck from reused slides of the old one and freshly
/// captured range decks. Order is the new deck's visible pptx order; every
/// entry keeps its pptxSlide and is renumbered to its position.
enum IncrementalMerger {
    struct Source {
        let deck: URL
        let manifest: DeckManifest
        let pdf: PDFDocument
        /// pptx slide -> position in this deck (0-based page index).
        let pageByPptx: [Int: Int]
        let slideByPptx: [Int: DeckManifest.Slide]

        init?(deck: URL) {
            guard let pdf = PDFDocument(url: deck.appendingPathComponent("slides.pdf")),
                  let manifest = DeckManifest.load(from: deck.appendingPathComponent("manifest.json")).manifest else { return nil }
            self.deck = deck; self.pdf = pdf; self.manifest = manifest
            var pages: [Int: Int] = [:], slides: [Int: DeckManifest.Slide] = [:]
            for s in manifest.slides {
                let p = s.pptxSlide ?? s.slide
                pages[p] = s.slide - 1; slides[p] = s
            }
            pageByPptx = pages; slideByPptx = slides
        }
    }

    /// `order`: the new deck's visible pptx slides in show order. `reuse`:
    /// new pptx -> old pptx. Captured slides come from `ranges` (the first
    /// slide of each range is the warm-up and is not used unless it is itself
    /// in `wanted`). Throws when a wanted slide is in neither.
    static func merge(order: [Int], reuse: [Int: Int], old: Source, ranges: [Source], wanted: Set<Int>, into dest: URL) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: dest)
        try fm.createDirectory(at: dest.appendingPathComponent("media"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dest.appendingPathComponent("stills"), withIntermediateDirectories: true)
        let pdf = PDFDocument()
        var slides: [DeckManifest.Slide] = []
        var missing: [Int] = []
        for (i, pptx) in order.enumerated() {
            let n = i + 1
            var picked: (Source, DeckManifest.Slide, Int)? = nil
            if wanted.contains(pptx) {
                for r in ranges { if let s = r.slideByPptx[pptx], let page = r.pageByPptx[pptx] { picked = (r, s, page); break } }
            } else if let oldN = reuse[pptx], let s = old.slideByPptx[oldN], let page = old.pageByPptx[oldN] {
                picked = (old, s, page)
            } else {
                for r in ranges { if let s = r.slideByPptx[pptx], let page = r.pageByPptx[pptx] { picked = (r, s, page); break } }
            }
            guard let (src, slide, page) = picked, let pdfPage = src.pdf.page(at: page) else { missing.append(pptx); continue }
            pdf.insert(pdfPage, at: pdf.pageCount)
            var e = slide
            e.slide = n
            e.pptxSlide = pptx
            // Every file the slide references travels, renamed to its new position. Copying only `file` and
            // `entryFile` left a version-3 slide's build clips and stills behind while the manifest entry kept
            // pointing at them, so the merged deck failed DeckVerifier on every build (found 2026-09-18).
            // Naming follows DeckCombiner, which assembles decks the same way.
            let tag = String(format: "slide_%03d", n)
            func move(_ rel: String?, to newRel: String) throws -> String? {
                guard let rel else { return nil }
                let from = src.deck.appendingPathComponent(rel)
                guard fm.fileExists(atPath: from.path) else {
                    throw NSError(domain: "ARCCapture", code: 12, userInfo: [NSLocalizedDescriptionKey: "slide \(pptx): \(rel) is missing from \(src.deck.lastPathComponent)"])
                }
                try fm.copyItem(at: from, to: dest.appendingPathComponent(newRel))
                return newRel
            }
            e.file = try move(slide.file, to: "media/\(tag).\((slide.file as NSString?)?.pathExtension ?? "mov")")
            e.entryFile = try move(slide.entryFile, to: "media/\(tag)_in.mov")
            e.initialStill = try move(slide.initialStill, to: "stills/\(tag)_s00.png")
            if let builds = slide.builds {
                e.builds = try builds.enumerated().map { k, b in
                    // A build that is a CUT has no clip (Build.file nil): its still comes along, and that is all of it.
                    let f = try move(b.file, to: String(format: "media/%@_b%02d.mov", tag, k + 1))
                    guard let st = try move(b.still, to: String(format: "stills/%@_s%02d.png", tag, k + 1)) else {
                        throw NSError(domain: "ARCCapture", code: 13, userInfo: [NSLocalizedDescriptionKey: "slide \(pptx): a build has no still"])
                    }
                    return DeckManifest.Build(file: f, still: st, duration: b.duration)
                }
            }
            slides.append(e)
        }
        guard missing.isEmpty else {
            throw NSError(domain: "ARCCapture", code: 10, userInfo: [NSLocalizedDescriptionKey: "slides \(missing) were captured by no range and reused from no version"])
        }
        ARCCredit.stamp(pdf)
        guard pdf.write(to: dest.appendingPathComponent("slides.pdf")) else {
            throw NSError(domain: "ARCCapture", code: 11, userInfo: [NSLocalizedDescriptionKey: "slides.pdf could not be written"])
        }
        try DeckManifest(slides: slides).write(to: dest.appendingPathComponent("manifest.json"))
        // A v2 deck has no stills and a deck of plain pages has no media; leaving the empty directories behind
        // would change the bundle's shape for no reason. DeckCombiner prunes the same two.
        for sub in ["media", "stills"] where ((try? fm.contentsOfDirectory(atPath: dest.appendingPathComponent(sub).path)) ?? []).isEmpty {
            try? fm.removeItem(at: dest.appendingPathComponent(sub))
        }
        // Notes travel with the old deck when nothing captured them anew.
        let notes = old.deck.appendingPathComponent("notes.json")
        if fm.fileExists(atPath: notes.path) { try? fm.copyItem(at: notes, to: dest.appendingPathComponent("notes.json")) }
    }
}

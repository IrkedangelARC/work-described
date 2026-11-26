//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import AppKit
import PDFKit
import ARCShowFormat

/// Several decks into ONE, with a logo page before the first, between every
/// two, and after the last (2026-09-17: "We will add title or logo
/// slides before, between and after all decks", and both outputs wanted: a
/// deck per preso and a combined session deck).
///
/// Typed end to end (ARCShowFormat), so everything a version 3 deck carries
/// comes along: per-build clips, state stills, entry clips, notes, what the
/// capture knew about each slide. The untyped stack builder it replaces for
/// show folders moved `file` and `entryFile` and wrote version 2.
///
/// A deck captured with its own logo pages brings them: its closing page
/// becomes the page between it and the next deck, and the next deck's opening
/// page is dropped, so there is never a double logo. A deck without them (a
/// PDF, an image, a movie, an older capture) gets them here.
enum DeckCombiner {
    struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }
    struct Part {
        let name: String; let deck: URL
        /// The logo page that ANNOUNCES this part (the page before it): its session's own holding slide. nil = the show's.
        var bumper: URL? = nil
        /// Set on the first part of a session: the page before it is that session's divider, and says so to the
        /// operator in the manifest ("SESSION 2"). Nothing is drawn over the art: the room sees the holding slide.
        var dividerTitle: String? = nil
        /// Pages (this deck's numbering) the show carries as PROBLEM slides, with the words to put on them: a black
        /// page ACCEPTED in review (never a black page nobody asked for).
        var replace: [Int: (item: String, title: String, reason: String)] = [:]
    }
    struct Result: Equatable { let pages: Int; let clips: Int; let stills: Int; let parts: Int }

    @discardableResult
    static func combine(_ parts: [Part], name: String, into dest: URL, bumper: URL? = nil, log: (String) -> Void = { _ in }) throws -> Result {
        guard !parts.isEmpty else { throw Failure(message: "nothing to combine") }
        let fm = FileManager.default
        let work = dest.deletingLastPathComponent().appendingPathComponent(".combine-\(UUID().uuidString).arcdeck")
        try? fm.removeItem(at: work)
        for sub in ["media", "stills"] { try fm.createDirectory(at: work.appendingPathComponent(sub), withIntermediateDirectories: true) }
        defer { try? fm.removeItem(at: work) }

        let out = PDFDocument()
        var slides: [DeckManifest.Slide] = []
        var notes: [String: String] = [:]
        var info = DeckManifest.DeckInfo()
        info.title = name; info.capturedAt = Date(); info.captureApp = "ARC Capture"
        info.captureVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        info.parts = []
        var clips = 0, stills = 0
        var frame = CGSize(width: 1920, height: 1080)

        func addLogo(_ role: DeckManifest.Role, announcing next: Part?) throws {
            guard let page = PDFPage(image: Bumper.image(size: frame, custom: next?.bumper ?? bumper)) else { throw Failure(message: "the logo page could not be made") }
            out.insert(page, at: out.pageCount)
            var s = DeckManifest.Slide(slide: out.pageCount, type: .image); s.role = role
            s.title = next?.dividerTitle
            slides.append(s)
        }

        for (i, part) in parts.enumerated() {
            guard let doc = PDFDocument(url: part.deck.appendingPathComponent("slides.pdf")) else { throw Failure(message: "\(part.name): slides.pdf will not open") }
            let manifest = DeckManifest.load(from: part.deck.appendingPathComponent("manifest.json")).manifest
            let byPage = Dictionary((manifest?.slides ?? []).map { ($0.slide, $0) }, uniquingKeysWith: { a, _ in a })
            let partNotes = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: part.deck.appendingPathComponent("notes.json")))) ?? [:]
            if let first = doc.page(at: 0) { let b = first.bounds(for: .mediaBox); if b.width > 0 { frame = b.size } }
            // Pixel size for a logo page made here: the deck's own, when it says.
            if let w = manifest?.deck?.pixelWidth, let h = manifest?.deck?.pixelHeight, w > 0, h > 0 { frame = CGSize(width: w, height: h) }
            if info.pixelWidth == nil { info.pixelWidth = manifest?.deck?.pixelWidth; info.pixelHeight = manifest?.deck?.pixelHeight }
            // One deck wrapped in its logo pages is still THAT deck: keep what it says about itself.
            if parts.count == 1, let own = manifest?.deck { var keep = own; keep.parts = info.parts; info = keep }

            let hasOpening = byPage[1]?.role == .opening, hasClosing = byPage[doc.pageCount]?.role == .closing
            if i == 0, !hasOpening { try addLogo(.opening, announcing: part) }
            let firstPage = out.pageCount + 1
            for p in 1...max(1, doc.pageCount) {
                guard let src = doc.page(at: p - 1), let copy = src.copy() as? PDFPage else { continue }
                var s = byPage[p] ?? DeckManifest.Slide(slide: p, type: .image)
                if s.role == .opening, i > 0 { continue }                                   // the previous deck's closing page stands between
                if s.role == .closing, i < parts.count - 1 { s.role = .between }
                // A logo page is REDRAWN, not copied: the deck may have been captured before the show had its
                // holding slide, or with an older one. One that carries a recording keeps its own picture.
                // A logo page announces what FOLLOWS it: the next part's session art between two parts, this part's at the ends.
                let announced: Part? = s.role == .between ? parts[i + 1] : (s.role == .opening ? part : nil)
                if let problem = part.replace[p],
                   let fresh = PDFPage(image: ProblemSlide.image(size: frame, item: problem.item, title: problem.title, page: s.pptxSlide ?? p, reason: problem.reason)) {
                    // A page accepted as not captured: the show says so, and nothing of the black capture travels.
                    out.insert(fresh, at: out.pageCount)
                    s.type = .image; s.file = nil; s.entryFile = nil; s.builds = nil; s.initialStill = nil; s.clicks = nil; s.entryClicks = nil; s.loop = nil; s.autoAdvance = nil
                    log("  ! \(part.name) page \(p): PROBLEM slide in place of a black page (\(problem.reason))")
                } else if s.role != nil, s.file == nil, s.entryFile == nil, s.builds == nil,
                   let fresh = PDFPage(image: Bumper.image(size: frame, custom: (announced ?? part).bumper ?? bumper)) {
                    out.insert(fresh, at: out.pageCount)
                    s.title = announced?.dividerTitle
                } else {
                    out.insert(copy, at: out.pageCount)
                }
                let n = out.pageCount
                let tag = String(format: "slide_%03d", n)
                func move(_ rel: String?, to newRel: String) throws -> String? {
                    guard let rel else { return nil }
                    let from = part.deck.appendingPathComponent(rel)
                    guard fm.fileExists(atPath: from.path) else { throw Failure(message: "\(part.name): \(rel) is missing") }
                    try fm.copyItem(at: from, to: work.appendingPathComponent(newRel))
                    return newRel
                }
                s.file = try move(s.file, to: "media/\(tag).\((s.file as NSString?)?.pathExtension ?? "mov")")
                s.entryFile = try move(s.entryFile, to: "media/\(tag)_in.mov")
                if s.file != nil { clips += 1 }; if s.entryFile != nil { clips += 1 }
                if let first = s.initialStill { s.initialStill = try move(first, to: "stills/\(tag)_s00.png"); stills += 1 }
                if let builds = s.builds {
                    s.builds = try builds.enumerated().map { k, b in
                        // A build that is a CUT has no clip (Build.file nil): its still comes along, and that is all of it.
                        // (Force-unwrapped, the first show deck built from cut builds crashed the app, 2026-09-17.)
                        let f = try move(b.file, to: String(format: "media/%@_b%02d.mov", tag, k + 1))
                        guard let st = try move(b.still, to: String(format: "stills/%@_s%02d.png", tag, k + 1)) else { throw Failure(message: "\(part.name): a build has no still") }
                        if f != nil { clips += 1 }
                        stills += 1
                        return DeckManifest.Build(file: f, still: st, duration: b.duration)
                    }
                }
                if s.role == nil { s.source = s.source ?? part.name; s.sourcePage = s.sourcePage ?? p }
                if let note = partNotes[String(p)] { notes[String(n)] = note }
                s.slide = n
                slides.append(s)
            }
            if !hasClosing { try addLogo(i < parts.count - 1 ? .between : .closing, announcing: i < parts.count - 1 ? parts[i + 1] : nil) }
            info.parts?.append(.init(name: part.name, firstPage: firstPage, lastPage: out.pageCount))
            log("  + \(part.name): pages \(firstPage)..\(out.pageCount)")
        }

        ARCCredit.stamp(out)
        guard out.write(to: work.appendingPathComponent("slides.pdf")) else { throw Failure(message: "slides.pdf could not be written") }
        try DeckManifest(deck: info, slides: slides).write(to: work.appendingPathComponent("manifest.json"))
        if !notes.isEmpty { try JSONEncoder().encode(notes).write(to: work.appendingPathComponent("notes.json")) }
        for sub in ["media", "stills"] where ((try? fm.contentsOfDirectory(atPath: work.appendingPathComponent(sub).path)) ?? []).isEmpty {
            try? fm.removeItem(at: work.appendingPathComponent(sub))
        }
        try? fm.removeItem(at: dest)
        try fm.moveItem(at: work, to: dest)
        return Result(pages: slides.count, clips: clips, stills: stills, parts: parts.count)
    }

    /// A single deck with no logo pages of its own (a PDF, an image, a movie)
    /// gets them, in place: the single-preso output matches the combined one.
    static func wrapInPlace(_ deck: URL, name: String, bumper: URL? = nil) throws {
        let tmp = deck.deletingLastPathComponent().appendingPathComponent(".wrap-\(UUID().uuidString).arcdeck")
        try combine([Part(name: name, deck: deck)], name: name, into: tmp, bumper: bumper)
        try FileManager.default.removeItem(at: deck)
        try FileManager.default.moveItem(at: tmp, to: deck)
    }
}

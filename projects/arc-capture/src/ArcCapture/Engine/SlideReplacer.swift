//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import AppKit
import Foundation
import PDFKit
import ARCShowFormat

/// Put one recaptured slide back into a finished deck (V3, plan 1.3). This is
/// the fix for "slide 23 came out wrong" that does not cost a 40-minute rerun.
///
/// One page and its media change; every other page keeps the bytes it had, so
/// a deck already handed to Presenter is only disturbed where it was wrong.
/// The new deck is built beside the old one and swapped in only after the
/// shared verifier passes, and the old one is kept as `.bak` until it does.
enum SlideReplacer {

    struct Result {
        let deck: URL
        /// The page that changed, 1-based in the deck.
        let page: Int
        /// The source slide it was captured from.
        let pptxSlide: Int
        let verdict: DeckVerdict
        /// Pages whose rendered content hash moved. Should be [page] alone.
        let changedPages: [Int]
    }

    struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }

    /// Which source slide does deck page `page` show? nil for a logo page,
    /// which has no source slide and cannot be recaptured.
    static func sourceSlide(forPage page: Int, in manifest: DeckManifest) -> Int? {
        manifest.slides.first { $0.slide == page }?.pptxSlide
    }

    /// Rewrite every media and still path an entry names.
    static func remap(_ slide: DeckManifest.Slide, _ rename: (String) -> String) -> DeckManifest.Slide {
        var e = slide
        e.file = slide.file.map(rename)
        e.entryFile = slide.entryFile.map(rename)
        e.initialStill = slide.initialStill.map(rename)
        e.builds = slide.builds?.map { b in
            var n = b
            n.file = b.file.map(rename)
            n.still = rename(b.still)
            return n
        }
        return e
    }

    /// Replace `page` of `deck` with the slide captured into `fresh`.
    ///
    /// `fresh` is a range capture that ends on the wanted source slide (it
    /// starts one slide early so the transition into it is the real one), so
    /// the entry taken from it is the one whose `pptxSlide` matches.
    static func replace(page: Int, in deck: URL, withSlideFrom fresh: URL) async throws -> Result {
        let fm = FileManager.default
        guard let oldManifest = DeckManifest.load(from: deck.appendingPathComponent("manifest.json")).manifest else {
            throw Failure(message: "\(deck.lastPathComponent) has no manifest to rewrite")
        }
        guard let freshManifest = DeckManifest.load(from: fresh.appendingPathComponent("manifest.json")).manifest else {
            throw Failure(message: "the recapture produced no manifest")
        }
        guard let target = oldManifest.slides.first(where: { $0.slide == page }) else {
            throw Failure(message: "this deck has no page \(page)")
        }
        guard let pptx = target.pptxSlide else {
            throw Failure(message: "page \(page) is a logo page, not a slide of the source; there is nothing to recapture")
        }
        guard let replacement = freshManifest.slides.first(where: { $0.pptxSlide == pptx }) else {
            throw Failure(message: "the recapture did not produce source slide \(pptx)")
        }
        guard let oldPDF = PDFDocument(url: deck.appendingPathComponent("slides.pdf")),
              let freshPDF = PDFDocument(url: fresh.appendingPathComponent("slides.pdf")) else {
            throw Failure(message: "slides.pdf could not be opened")
        }
        guard page >= 1, page <= oldPDF.pageCount else {
            throw Failure(message: "page \(page) is outside this deck's \(oldPDF.pageCount) pages")
        }
        guard let freshPage = freshPDF.page(at: (replacement.slide - 1)) else {
            throw Failure(message: "the recapture has no page for source slide \(pptx)")
        }

        let before = SlideHasher.pdfPageHashes(deck.appendingPathComponent("slides.pdf"))

        // Build the new deck beside the old one: everything copied as it was,
        // then the one page swapped.
        let staging = deck.deletingLastPathComponent()
            .appendingPathComponent(".\(deck.lastPathComponent).recapture-\(UUID().uuidString)")
        try? fm.removeItem(at: staging)
        try fm.copyItem(at: deck, to: staging)
        defer { try? fm.removeItem(at: staging) }

        // The outgoing page's own files go; every other page's stay untouched.
        for rel in target.mediaFiles + target.stillFiles {
            try? fm.removeItem(at: staging.appendingPathComponent(rel))
        }
        try fm.createDirectory(at: staging.appendingPathComponent("media"), withIntermediateDirectories: true)

        // The incoming page's files come in under names nothing else uses.
        let stamp = String(UUID().uuidString.prefix(6)).lowercased()
        var entry = remap(replacement) { rel in
            "media/slide_\(String(format: "%03d", page))_r\(stamp)_\(URL(fileURLWithPath: rel).lastPathComponent)"
        }
        for (from, to) in zip(replacement.mediaFiles + replacement.stillFiles,
                              entry.mediaFiles + entry.stillFiles) {
            let src = fresh.appendingPathComponent(from)
            guard fm.fileExists(atPath: src.path) else {
                throw Failure(message: "the recapture is missing \(from)")
            }
            try fm.copyItem(at: src, to: staging.appendingPathComponent(to))
        }
        entry.slide = page
        entry.pptxSlide = pptx
        // What the deck knows about the slide from the source outlives one
        // recapture; what was MEASURED belongs to the new capture.
        entry.title = entry.title ?? target.title
        entry.hasNotes = entry.hasNotes ?? target.hasNotes

        // The PDF: the same pages, with one swapped.
        oldPDF.removePage(at: page - 1)
        oldPDF.insert(freshPage, at: page - 1)
        ARCCredit.stamp(oldPDF)
        guard oldPDF.write(to: staging.appendingPathComponent("slides.pdf")) else {
            throw Failure(message: "the rebuilt slides.pdf could not be written")
        }

        var slides = oldManifest.slides
        if let i = slides.firstIndex(where: { $0.slide == page }) { slides[i] = entry }
        try DeckManifest(deck: oldManifest.deck, slides: slides)
            .write(to: staging.appendingPathComponent("manifest.json"))

        let verdict = await DeckVerifier.verify(arcdeck: staging)
        guard verdict.ok else {
            throw Failure(message: "the recaptured deck did not verify: \(verdict.detail)")
        }

        // Swap, keeping the old one until the new one is in place.
        let backup = deck.appendingPathExtension("bak")
        try? fm.removeItem(at: backup)
        try fm.moveItem(at: deck, to: backup)
        do { try fm.moveItem(at: staging, to: deck) } catch {
            try? fm.moveItem(at: backup, to: deck)      // put it back
            throw Failure(message: "the recaptured deck could not be moved into place: \(error.localizedDescription)")
        }
        try? fm.removeItem(at: backup)

        let after = SlideHasher.pdfPageHashes(deck.appendingPathComponent("slides.pdf"))
        var changed: [Int] = []
        if before.count == after.count {
            for i in 0..<before.count where before[i] != after[i] { changed.append(i + 1) }
        }
        DebugLog.log("Recapture", "page \(page) (source slide \(pptx)) replaced; page content changed on \(changed.isEmpty ? "no page" : changed.map(String.init).joined(separator: ", "))")
        return Result(deck: deck, page: page, pptxSlide: pptx, verdict: verdict, changedPages: changed)
    }
}

//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import AppKit
import ARCShowFormat

/// Writes the capture to disk. One PDF is assembled once and shared by every
/// output (the old code assembled it twice for a mixed deck).
///
///   <name>.arcdeck/            always: slides.pdf, media/slide_NNN.mov, manifest.json
///   <name>.pdf                 static-only decks (a convenience copy of slides.pdf)
///   <name>/                    mixed decks, only with keepPNGs: slide_NNN.png + .mov + slides.pdf + manifest.json
enum DeckWriter {

    enum DeckWriteError: LocalizedError {
        case pageFailed(Int)
        var errorDescription: String? {
            switch self {
            case .pageFailed(let n): "slide \(n): the page picture could not be written"
            }
        }
    }

    struct Output {
        let deckURL: URL
        let pdfURL: URL?
        let folderURL: URL?
        /// Relative clip path per captured slide index, for the report.
        let clipFiles: [Int: String]
    }

    static func write(slides: [CaptureResult], baseName: String, into outputDir: URL, keepPNGs: Bool,
                      analysis: PPTXAnalysis? = nil, info: DeckManifest.DeckInfo? = nil) throws -> Output {
        let fm = FileManager.default
        let deckURL = outputDir.appendingPathComponent("\(baseName).arcdeck")
        if fm.fileExists(atPath: deckURL.path) { try fm.removeItem(at: deckURL) }
        try fm.createDirectory(at: deckURL, withIntermediateDirectories: true)

        // The one PDF, assembled a page at a time from the JPEGs the
        // checkpoint already wrote (V3, plan 1.1). A slide that was never
        // checkpointed (the logo pages, a PDF import, a run with no partial)
        // is compressed here into a scratch file and used the same way, so
        // nothing holds more than one page's bitmap.
        let pdfURL = deckURL.appendingPathComponent("slides.pdf")
        let scratch = deckURL.appendingPathComponent(".pages")
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }
        var pageFiles: [URL] = []
        for s in slides {
            if let f = s.pageFile, fm.fileExists(atPath: f.path) { pageFiles.append(f); continue }
            let dest = scratch.appendingPathComponent("page_\(String(format: "%03d", s.id)).jpg")
            guard let data = PDFAssembler.pageJPEG(from: s.image) else {
                throw DeckWriteError.pageFailed(s.id)
            }
            try data.write(to: dest, options: .atomic)
            pageFiles.append(dest)
        }
        try PDFAssembler.assemble(jpegFiles: pageFiles, to: pdfURL)

        // Clips + manifest.
        let hasVideo = slides.contains(where: \.isVideo)
        var clipFiles: [Int: String] = [:]
        if hasVideo { try fm.createDirectory(at: deckURL.appendingPathComponent("media"), withIntermediateDirectories: true) }
        // Typed manifest (ARCShowFormat.DeckManifest, V3): the same version-2
        // keys as before, written through the contract Presenter reads.
        func r2(_ v: Double) -> Double { (v * 100).rounded() / 100 }
        var entries: [DeckManifest.Slide] = []
        for s in slides {
            var e = DeckManifest.Slide(slide: s.id, type: s.slideType == .video ? .video : .image)
            e.pptxSlide = s.pptxSlide
            e.autoAdvance = s.autoAdvance.map(r2)
            // What the source says and what the capture saw: none of it is
            // needed to play the deck, all of it travels with it.
            e.role = s.role
            e.measured = s.role == nil ? DeckManifest.Measured(settleMs: s.settleMs, motionFrames: s.motionFrames, endedBy: s.endedBy, capturedAt: s.capturedAt) : nil
            if let n = s.pptxSlide, let a = analysis {
                e.title = a.slideTitles[n]
                e.media = a.slideMedia[n]
                e.mediaStart = a.mediaStarts[n]
                e.transitionEffect = a.transitionEffects[n]
                e.transitionSeconds = a.transitionDurations[n].map(r2)
                e.sourceClicks = a.clickCounts[n]
                e.hasNotes = a.slidesWithNotes.contains(n) ? true : nil
            }
            if s.isVideo, let src = s.videoURL, fm.fileExists(atPath: src.path) {
                let rel = "media/slide_\(String(format: "%03d", s.id)).mov"
                try fm.copyItem(at: src, to: deckURL.appendingPathComponent(rel))
                e.file = rel
                if s.loop { e.loop = true }
                if s.transition { e.transition = true }
                if let ls = s.loopStart, ls > 0 { e.loopStart = r2(ls) }
                if !s.clicks.isEmpty { e.clicks = s.clicks.map(r2) }
                e.entryClick = s.entryClick
                if let st = s.stopAt, st > 0 { e.stopAt = r2(st) }
                if s.transitionIn { e.transitionIn = true }
                if let src2 = s.entryClipURL, fm.fileExists(atPath: src2.path) {
                    let rel2 = "media/slide_\(String(format: "%03d", s.id))_in.mov"
                    try fm.copyItem(at: src2, to: deckURL.appendingPathComponent(rel2))
                    e.entryFile = rel2
                    if !s.entryClicks.isEmpty { e.entryClicks = s.entryClicks.map(r2) }
                }
                clipFiles[s.id] = rel
            }
            entries.append(e)
        }
        try DeckManifest(deck: info, slides: entries).write(to: deckURL.appendingPathComponent("manifest.json"))

        var outPDF: URL? = nil
        var outFolder: URL? = nil
        if !hasVideo {
            outPDF = outputDir.appendingPathComponent("\(baseName).pdf")
            try? fm.removeItem(at: outPDF!)
            try fm.copyItem(at: pdfURL, to: outPDF!)
        } else if keepPNGs {
            let folder = outputDir.appendingPathComponent(baseName)
            if fm.fileExists(atPath: folder.path) { try fm.removeItem(at: folder) }
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try fm.copyItem(at: pdfURL, to: folder.appendingPathComponent("slides.pdf"))
            var flat: [[String: String]] = []
            for s in slides {
                let dest = folder.appendingPathComponent(s.filename)
                switch s.slideType {
                case .image:
                    try autoreleasepool {
                        if let tiff = s.image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                           let png = rep.representation(using: .png, properties: [:]) {
                            try png.write(to: dest)
                        }
                    }
                case .video:
                    if let rel = clipFiles[s.id] { try fm.copyItem(at: deckURL.appendingPathComponent(rel), to: dest) }
                }
                flat.append(["slide": String(s.id), "type": s.slideType.rawValue, "file": s.filename])
            }
            try JSONSerialization.data(withJSONObject: flat, options: [.prettyPrinted, .sortedKeys])
                .write(to: folder.appendingPathComponent("manifest.json"))
            outFolder = folder
        }
        DebugLog.log("Deck", "wrote \(deckURL.lastPathComponent): \(slides.count) slides, \(clipFiles.count) clips")
        return Output(deckURL: deckURL, pdfURL: outPDF, folderURL: outFolder, clipFiles: clipFiles)
    }
}

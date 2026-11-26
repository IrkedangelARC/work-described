//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import AppKit
import Foundation
import ARCShowFormat

/// Every captured slide on disk the moment it is captured (V3, plan 1.1/1.2).
///
/// Two problems, one store. A 40-minute run that dies on slide 40 used to
/// leave nothing at all, and a run held every slide's 2x bitmap in memory
/// until the deck was written: 27.3 MB a slide, 1.9 GB at 53 slides, about
/// 3.2 GB at 100 (MEASURED_memory_2026-09).
///
/// So each slide is written as it is finished, into the deck-in-progress:
///
///     <name>.arcdeck.partial/
///         progress.json          run header, source identity, every slide so far
///         pages/slide_NNN.jpg    the page at PDF size (not the 2x bitmap)
///         media/slide_NNN.mov    the finished clip, moved out of /tmp
///         media/slide_NNN_in.mov the entry-transition clip
///
/// `CaptureResult` then drops its bitmap and points at `pages/slide_NNN.jpg`,
/// so only the slide in flight is resident. `DeckWriter` assembles the deck
/// from those files, and a crashed run is restored by `restore(from:)`.
///
/// The partial is deleted when the deck is written and verified, and kept on
/// every other ending.
@MainActor
final class CaptureCheckpoint {

    /// One captured slide, as progress.json records it. Everything
    /// `CaptureResult` carries that the deck needs, plus the file names.
    struct Slide: Codable {
        var id: Int
        var pptxSlide: Int?
        var type: String                    // SlideType.rawValue
        var capturedAt: Date
        var settleMs: Int
        var motionFrames: Int
        var endedBy: String
        var page: String                    // relative to the partial
        var clip: String?
        var entryClip: String?
        var loop: Bool = false
        var loopStart: Double?
        var transition: Bool = false
        var clicks: [Double] = []
        var entryClick: Int?
        var stopAt: Double?
        var transitionIn: Bool = false
        var autoAdvance: Double?
        var entryClicks: [Double] = []
        var role: String?
    }

    /// progress.json. Rewritten whole after every slide (it is a few KB) and
    /// replaced atomically, so a crash mid-write cannot leave a half file.
    struct Progress: Codable {
        var version = 1
        var baseName: String
        var source: String
        var sourceModified: Date?
        var sourceBytes: Int?
        var startedAt: Date
        var updatedAt: Date
        /// The show position of the last captured slide: a resume starts after it.
        var lastPptxSlide: Int?
        var app: String?
        var host: String?
        var system: String?
        /// One hash per source slide, in show order. This, not the file's
        /// modification date, is what says the deck is still the deck: PowerPoint
        /// rewrites the .pptx container while it has it open (measured on the
        /// mini 2026-09-18, the file's size and mtime both moved across a run),
        /// which used to veto every real resume.
        var slideHashes: [String]?
        var slides: [Slide] = []
        /// Runs that have written into this partial, oldest first (a resumed
        /// run appends). Only for the record.
        var runs: [String] = []
    }

    let dir: URL
    private(set) var progress: Progress
    private let fm = FileManager.default

    static let suffix = "arcdeck.partial"

    static func partialURL(baseName: String, in outputDir: URL) -> URL {
        outputDir.appendingPathComponent("\(baseName).\(suffix)")
    }

    /// Open (or reopen) the partial for this run. `resuming` keeps what is
    /// already there; otherwise anything left from an older run is cleared,
    /// because a fresh capture of the same deck must not splice old pages in.
    init(baseName: String, in outputDir: URL, source: URL?, resuming: Bool = false,
         app: String? = nil, host: String? = nil, system: String? = nil) throws {
        // `fm` is not available yet: every member has to be set first.
        let files = FileManager.default
        dir = Self.partialURL(baseName: baseName, in: outputDir)
        let existing = resuming ? Self.readProgress(at: dir) : nil
        if existing == nil, files.fileExists(atPath: dir.path) { try files.removeItem(at: dir) }
        try files.createDirectory(at: dir.appendingPathComponent("pages"), withIntermediateDirectories: true)
        try files.createDirectory(at: dir.appendingPathComponent("media"), withIntermediateDirectories: true)
        let attrs = source.flatMap { try? files.attributesOfItem(atPath: $0.path) }
        let hashes = existing == nil ? source.map { Self.slideHashes(of: $0) } : nil
        if var p = existing {
            p.updatedAt = Date()
            p.runs.append(ISO8601DateFormatter().string(from: Date()))
            progress = p
        } else {
            progress = Progress(baseName: baseName,
                                source: source?.path ?? "",
                                sourceModified: attrs?[.modificationDate] as? Date,
                                sourceBytes: attrs?[.size] as? Int,
                                startedAt: Date(), updatedAt: Date(),
                                app: app, host: host, system: system,
                                slideHashes: (hashes?.isEmpty ?? true) ? nil : hashes,
                                runs: [ISO8601DateFormatter().string(from: Date())])
        }
        try writeProgress()
        DebugLog.log("Checkpoint", "\(existing == nil ? "opened" : "resumed") \(dir.lastPathComponent)\(existing == nil ? "" : " at \(progress.slides.count) slide(s)")")
    }

    // MARK: - Writing

    /// Write one finished slide and hand back the same slide with its bitmap
    /// released and its files pointing into the partial. The clip is MOVED,
    /// not copied: it is the only copy either way and a move costs nothing.
    ///
    /// Throws only when the page itself cannot be written; a clip that will
    /// not move is reported and the slide keeps its temp clip, because losing
    /// the checkpoint is not a reason to lose the capture.
    @discardableResult
    func append(_ slide: CaptureResult) throws -> CaptureResult {
        var out = slide
        let t0 = Date()
        let padded = String(format: "%03d", slide.id)
        let pageRel = "pages/slide_\(padded).jpg"
        guard let data = PDFAssembler.pageJPEG(from: slide.image) else {
            throw Failure(message: "slide \(slide.id): the page could not be compressed")
        }
        let tJPEG = Date()
        try data.write(to: dir.appendingPathComponent(pageRel), options: .atomic)
        let tPage = Date()
        out.checkpointed(pageFile: dir.appendingPathComponent(pageRel),
                         thumbnail: PDFAssembler.thumbnail(fromJPEG: data))
        let tThumb = Date()

        var clipRel: String? = nil, entryRel: String? = nil
        if let clip = slide.videoURL, fm.fileExists(atPath: clip.path) {
            let rel = "media/slide_\(padded).mov"
            if moveIn(clip, to: rel) { clipRel = rel; out.videoURL = dir.appendingPathComponent(rel) }
        }
        if let entry = slide.entryClipURL, fm.fileExists(atPath: entry.path) {
            let rel = "media/slide_\(padded)_in.mov"
            if moveIn(entry, to: rel) { entryRel = rel; out.entryClipURL = dir.appendingPathComponent(rel) }
        }

        var e = Slide(id: slide.id, pptxSlide: slide.pptxSlide, type: slide.slideType.rawValue,
                      capturedAt: slide.capturedAt, settleMs: slide.settleMs, motionFrames: slide.motionFrames,
                      endedBy: slide.endedBy, page: pageRel, clip: clipRel, entryClip: entryRel)
        e.loop = slide.loop; e.loopStart = slide.loopStart; e.transition = slide.transition
        e.clicks = slide.clicks; e.entryClick = slide.entryClick; e.stopAt = slide.stopAt
        e.transitionIn = slide.transitionIn; e.autoAdvance = slide.autoAdvance
        e.entryClicks = slide.entryClicks; e.role = slide.role?.rawValue
        progress.slides.removeAll { $0.id == slide.id }
        progress.slides.append(e)
        progress.slides.sort { $0.id < $1.id }
        if let n = slide.pptxSlide { progress.lastPptxSlide = n }
        progress.updatedAt = Date()
        let tClips = Date()
        try writeProgress()
        func ms(_ a: Date, _ b: Date) -> Int { Int(b.timeIntervalSince(a) * 1000) }
        DebugLog.log("Checkpoint", "slide \(slide.id) stored in \(ms(t0, Date())) ms (jpeg \(ms(t0, tJPEG)), page \(ms(tJPEG, tPage)), thumb \(ms(tPage, tThumb)), clips \(ms(tThumb, tClips)), progress \(ms(tClips, Date())))")
        return out
    }

    private func moveIn(_ src: URL, to rel: String) -> Bool {
        let dest = dir.appendingPathComponent(rel)
        do {
            try? fm.removeItem(at: dest)
            try fm.moveItem(at: src, to: dest)
            return true
        } catch {
            // Across volumes a move is a copy; try that before giving up.
            do { try fm.copyItem(at: src, to: dest); try? fm.removeItem(at: src); return true }
            catch {
                DebugLog.log("Checkpoint", "clip \(src.lastPathComponent) could not be stored: \(error.localizedDescription)")
                return false
            }
        }
    }

    private func writeProgress() throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        let data = try enc.encode(progress)
        let target = dir.appendingPathComponent("progress.json")
        let tmp = dir.appendingPathComponent(".progress.json.new")
        try data.write(to: tmp, options: .atomic)
        _ = try? fm.replaceItemAt(target, withItemAt: tmp)
        if fm.fileExists(atPath: tmp.path) {         // replaceItemAt did not take
            try? fm.removeItem(at: target)
            try fm.moveItem(at: tmp, to: target)
        }
    }

    /// The deck is written and verified: the partial has done its job.
    func discard() {
        try? fm.removeItem(at: dir)
        DebugLog.log("Checkpoint", "discarded \(dir.lastPathComponent)")
    }

    struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }

    // MARK: - Reading and resuming

    static func readProgress(at partial: URL) -> Progress? {
        guard let data = try? Data(contentsOf: partial.appendingPathComponent("progress.json")) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(Progress.self, from: data)
    }

    /// What a resume needs: the slides already captured, rebuilt as
    /// `CaptureResult`s that point at the partial's files. The page bitmaps
    /// are NOT loaded; each slide gets a filmstrip thumbnail and reads its
    /// page back only when the deck is written.
    static func restore(from partial: URL) -> (progress: Progress, slides: [CaptureResult])? {
        guard let p = readProgress(at: partial), !p.slides.isEmpty else { return nil }
        let fm = FileManager.default
        var out: [CaptureResult] = []
        for e in p.slides.sorted(by: { $0.id < $1.id }) {
            let page = partial.appendingPathComponent(e.page)
            guard fm.fileExists(atPath: page.path) else {
                DebugLog.log("Checkpoint", "slide \(e.id): page missing from the partial; the resume stops here")
                break
            }
            let clip = e.clip.map { partial.appendingPathComponent($0) }
            if let c = clip, !fm.fileExists(atPath: c.path) {
                DebugLog.log("Checkpoint", "slide \(e.id): clip missing from the partial; the resume stops here")
                break
            }
            var r = CaptureResult(id: e.id, pptxSlide: e.pptxSlide,
                                  slideType: SlideType(rawValue: e.type) ?? .image, image: nil,
                                  videoURL: clip, capturedAt: e.capturedAt, settleMs: e.settleMs,
                                  motionFrames: e.motionFrames, endedBy: e.endedBy)
            let thumb = (try? Data(contentsOf: page)).flatMap { PDFAssembler.thumbnail(fromJPEG: $0) }
            r.checkpointed(pageFile: page, thumbnail: thumb)
            r.loop = e.loop; r.loopStart = e.loopStart; r.transition = e.transition
            r.clicks = e.clicks; r.entryClick = e.entryClick; r.stopAt = e.stopAt
            r.transitionIn = e.transitionIn; r.autoAdvance = e.autoAdvance
            r.entryClicks = e.entryClicks
            r.role = e.role.flatMap { DeckManifest.Role(rawValue: $0) }
            if let ec = e.entryClip {
                let u = partial.appendingPathComponent(ec)
                if fm.fileExists(atPath: u.path) { r.entryClipURL = u }
            }
            out.append(r)
        }
        guard !out.isEmpty else { return nil }
        return (p, out)
    }

    /// Does this partial hold a usable resume for `source`? The source must
    /// be the same file, unchanged: a deck edited since the crash has to be
    /// captured again, and splicing new slides onto old pages would be
    /// silent corruption.
    static func matches(_ p: Progress, source: URL, liveHashes: [String]? = nil) -> Bool {
        guard p.source == source.path else { return false }
        // Content first. PowerPoint rewrites the .pptx while it is open, so a
        // date or a byte count says "edited" about a deck nobody touched.
        if let was = p.slideHashes, !was.isEmpty {
            let now = liveHashes ?? slideHashes(of: source)
            if !now.isEmpty { return was == now }
        }
        // No hashes on either side (an older partial, or a source nothing can
        // hash): fall back to the file's identity.
        let attrs = try? FileManager.default.attributesOfItem(atPath: source.path)
        if let was = p.sourceModified, let now = attrs?[.modificationDate] as? Date,
           abs(was.timeIntervalSince(now)) > 1 { return false }
        if let was = p.sourceBytes, let now = attrs?[.size] as? Int, was != now { return false }
        return true
    }

    /// One hash per slide of the source, in show order; empty when the kind
    /// cannot be hashed (a Google Slides URL, an unreadable archive).
    static func slideHashes(of source: URL) -> [String] {
        switch source.pathExtension.lowercased() {
        case "pptx", "pptm", "ppt": return SlideHasher.pptxSlideHashes(source)
        case "pdf": return SlideHasher.pdfPageHashes(source)
        default: return []
        }
    }

    /// The partial to resume for `source`, looked for beside the deck it
    /// would be written next to. The name is the analysed title, so the
    /// directory is also scanned: a partial written under a title the
    /// analyzer no longer returns is still the right one if its recorded
    /// source matches.
    static func findResumable(source: URL, baseName: String?, in outputDir: URL) -> (url: URL, progress: Progress)? {
        var candidates: [URL] = []
        if let baseName { candidates.append(partialURL(baseName: baseName, in: outputDir)) }
        let listed = (try? FileManager.default.contentsOfDirectory(at: outputDir, includingPropertiesForKeys: nil)) ?? []
        candidates.append(contentsOf: listed.filter { $0.lastPathComponent.hasSuffix(".\(suffix)") })
        var seen = Set<String>()
        var live: [String]? = nil
        for c in candidates where seen.insert(c.path).inserted {
            if live == nil { live = slideHashes(of: source) }
            guard let p = readProgress(at: c) else {
                DebugLog.log("Checkpoint", "\(c.lastPathComponent): progress.json missing or unreadable")
                continue
            }
            guard !p.slides.isEmpty else {
                DebugLog.log("Checkpoint", "\(c.lastPathComponent): no slides in it")
                continue
            }
            guard matches(p, source: source, liveHashes: live) else {
                DebugLog.log("Checkpoint", "\(c.lastPathComponent): does not match this deck (recorded \(p.slideHashes?.count ?? 0) slide hash(es), the deck now has \(live?.count ?? 0); first difference at \(zip(p.slideHashes ?? [], live ?? []).enumerated().first { $0.element.0 != $0.element.1 }?.offset.description ?? "none"))")
                continue
            }
            return (c, p)
        }
        DebugLog.log("Checkpoint", "no resumable partial among \(candidates.count) candidate(s) in \(outputDir.path)")
        return nil
    }
}

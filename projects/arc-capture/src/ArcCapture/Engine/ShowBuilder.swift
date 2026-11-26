//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import AppKit
import AVFoundation
import PDFKit

/// A show folder (or an ordered item list) to ONE arcdeck, in Swift: the
/// port of tools/build_show.py (2026-09-12, V2 refactor) so fleet Macs need
/// no Python. Items in file-name order, or the order in show.json. Per item:
/// .pptx/.ppt/.key/.webloc/.url captured in-process by CaptureSession (cached
/// under FOLDER/.arcbuild while the source is unchanged), .arcdeck merged as
/// is, .pdf pages as stills, images as stills on a 16:9 canvas, movies as
/// video slides with a first-frame poster (transcoded to H.264/AAC when they
/// are anything else). Output: slides.pdf, media/, manifest.json (version 2,
/// `source` per slide), notes.json, build_report.json.
@MainActor
final class ShowBuilder {
    struct ItemResult { let file: String; let status: String; let slides: Int; var warnings: [String] = [] }
    struct Result { let deck: URL; let slides: Int; let videos: Int; let notes: Int; let items: [ItemResult] }

    let folder: URL
    var name: String
    var items: [URL]
    var force = false
    var openInPresenter = true
    var log: (String) -> Void = { _ in }
    /// The capture running right now (the monitor can watch it).
    private(set) var currentSession: CaptureSession?

    static let deckExt = ["pptx", "ppt", "key"], linkExt = ["webloc", "url"], pdfExt = ["pdf"]
    static let imageExt = ["png", "jpg", "jpeg", "heic", "tif", "tiff"], movieExt = ["mp4", "mov", "m4v"]

    init(folder: URL, name: String? = nil, items: [URL]? = nil) {
        self.folder = folder
        let showJSON = folder.appendingPathComponent("show.json")
        var resolvedName = name ?? folder.lastPathComponent
        var resolved = items
        if resolved == nil, let data = try? Data(contentsOf: showJSON),
           let spec = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if name == nil, let n = spec["name"] as? String, !n.isEmpty { resolvedName = n }
            // ShowSpec writes each item's file under `source`; the older stack format wrote `path`.
            // Reading only `path` meant a modern show.json yielded NO paths, and because `resolved`
            // was then an EMPTY ARRAY rather than nil, the folder-order fallback below never fired:
            // `--show <a real show folder>` built a show of zero items and said nothing (2026-09-18).
            // An http source is a Google Slides link, not a local file, so it is not a build input.
            let rows = (spec["items"] as? [[String: Any]]) ?? []
            let paths = rows.compactMap { ($0["source"] as? String) ?? ($0["path"] as? String) }
                            .filter { !$0.hasPrefix("http") }
            resolved = paths.isEmpty ? nil : paths.map { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : folder.appendingPathComponent($0) }
        }
        if resolved == nil { resolved = Self.folderItems(folder, excluding: resolvedName + ".arcdeck") }
        self.name = resolvedName
        self.items = resolved ?? []
    }

    static func folderItems(_ folder: URL, excluding: String) -> [URL] {
        let all = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return all.filter { !$0.hasPrefix(".") && !$0.hasPrefix("~$") && $0 != excluding }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { folder.appendingPathComponent($0) }
            .filter { u in
                let e = u.pathExtension.lowercased()
                return (deckExt + linkExt + pdfExt + imageExt + movieExt + ["arcdeck"]).contains(e)
            }
    }

    // MARK: Build

    func build() async throws -> Result {
        let fm = FileManager.default
        let out = folder.appendingPathComponent(name + ".arcdeck")
        let tmp = folder.appendingPathComponent(name + ".arcdeck.building")
        try? fm.removeItem(at: tmp)
        try fm.createDirectory(at: tmp.appendingPathComponent("media"), withIntermediateDirectories: true)
        let work = folder.appendingPathComponent(".arcbuild")
        try? fm.createDirectory(at: work, withIntermediateDirectories: true)
        // A source and its own capture side by side (1.02 handout.pdf next to
        // 1.02 handout.arcdeck) would build twice: keep the arcdeck, say so.
        var seenStems: [String: URL] = [:]
        var deduped: [URL] = []
        for u in items {
            let stem = u.deletingPathExtension().lastPathComponent
            if let other = seenStems[stem] {
                let keep = u.pathExtension.lowercased() == "arcdeck" ? u : other
                let drop = keep == u ? other : u
                log("  WARNING: \(drop.lastPathComponent) and \(keep.lastPathComponent) share a name; using \(keep.lastPathComponent) only")
                deduped.removeAll { $0 == drop }
                if !deduped.contains(keep) { deduped.append(keep) }
                seenStems[stem] = keep
            } else { seenStems[stem] = u; deduped.append(u) }
        }
        items = deduped
        log("show \(name): \(items.count) item(s)")

        let doc = PDFDocument()
        var entries: [[String: Any]] = []
        var media: [(src: URL, key: String, index: Int, isItemMovie: Bool)] = []
        var notes: [Int: String] = [:]          // 0-based entry index -> note
        var results: [ItemResult] = []

        for item in items {
            let f = item.lastPathComponent, ext = item.pathExtension.lowercased(), n0 = entries.count
            guard fm.fileExists(atPath: item.path) else { log("  missing, skipped: \(f)"); results.append(ItemResult(file: f, status: "missing", slides: 0)); continue }
            if ext == "arcdeck" {
                let (man, deckNotes) = Self.readDeck(item)
                if let src = PDFDocument(url: item.appendingPathComponent("slides.pdf")) { Self.append(src, to: doc) }
                for (k, e) in man.enumerated() {
                    var e = e; e["source"] = f
                    if let note = deckNotes[k + 1] { notes[entries.count] = note }
                    for key in ["file", "entryFile"] { if let rel = e[key] as? String { media.append((item.appendingPathComponent(rel), key, entries.count, false)) } }
                    entries.append(e)
                }
                results.append(ItemResult(file: f, status: "merged", slides: man.count))
            } else if Self.deckExt.contains(ext) || Self.linkExt.contains(ext) {
                let (deck, report) = try await capture(item, work: work)
                guard let deck else { results.append(ItemResult(file: f, status: "FAILED", slides: 0, warnings: [report?.error ?? "no report"])); continue }
                let (man, _) = Self.readDeck(deck)
                if let src = PDFDocument(url: deck.appendingPathComponent("slides.pdf")) { Self.append(src, to: doc) }
                let srcNotes = Self.deckExt.dropLast().contains(ext) ? Self.pptxNotes(item) : [:]
                for e in man {
                    var e = e; e["source"] = f
                    if let p = e["pptxSlide"] as? Int, let note = srcNotes[p] { notes[entries.count] = note }
                    for key in ["file", "entryFile"] { if let rel = e[key] as? String { media.append((deck.appendingPathComponent(rel), key, entries.count, false)) } }
                    entries.append(e)
                }
                results.append(ItemResult(file: f, status: "captured", slides: man.count, warnings: report?.warnings ?? []))
            } else if Self.pdfExt.contains(ext) {
                if let src = PDFDocument(url: item) {
                    Self.append(src, to: doc)
                    for i in 0..<src.pageCount { entries.append(["type": "image", "source": f, "sourcePage": i + 1]) }
                    results.append(ItemResult(file: f, status: "pages", slides: src.pageCount))
                }
            } else if Self.imageExt.contains(ext) {
                if let img = NSImage(contentsOf: item), let page = Self.canvasPage(img) { doc.insert(page, at: doc.pageCount) }
                entries.append(["type": "image", "source": f]); results.append(ItemResult(file: f, status: "still", slides: 1))
            } else if Self.movieExt.contains(ext) {
                let poster = Self.firstFrame(item)
                if let poster, let page = Self.canvasPage(poster) { doc.insert(page, at: doc.pageCount) } else { doc.insert(PDFPage(), at: doc.pageCount) }
                media.append((item, "file", entries.count, true))
                entries.append(["type": "video", "source": f]); results.append(ItemResult(file: f, status: "video", slides: 1))
            }
            log("  + \(f): slides \(n0 + 1)..\(entries.count)")
        }

        // Renumber, copy media (transcoding item movies when needed), notes.
        for i in entries.indices { entries[i]["slide"] = i + 1; entries[i].removeValue(forKey: "file"); entries[i].removeValue(forKey: "entryFile") }
        for m in media {
            let rel = String(format: "media/slide_%03d%@.mov", m.index + 1, m.key == "entryFile" ? "_in" : "")
            let dst = tmp.appendingPathComponent(rel)
            if m.isItemMovie { log("  media \(m.src.lastPathComponent): \(Self.copyOrTranscode(m.src, to: dst))") }
            else { try fm.copyItem(at: m.src, to: dst) }
            entries[m.index][m.key] = rel
        }
        ARCCredit.stamp(doc)
        try doc.write(to: tmp.appendingPathComponent("slides.pdf"))
        let manifest: [String: Any] = ["version": 2, "show": name, "slides": entries]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]).write(to: tmp.appendingPathComponent("manifest.json"))
        if !notes.isEmpty {
            let byPage = Dictionary(uniqueKeysWithValues: notes.map { (String($0.key + 1), $0.value) })
            try JSONSerialization.data(withJSONObject: byPage, options: [.prettyPrinted, .sortedKeys]).write(to: tmp.appendingPathComponent("notes.json"))
        }
        let videos = entries.filter { ($0["type"] as? String) == "video" }.count
        let report: [String: Any] = ["show": name, "slides": entries.count, "video": videos, "notes": notes.count,
                                     "items": results.map { ["file": $0.file, "status": $0.status, "slides": $0.slides, "warnings": $0.warnings] }]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted]).write(to: tmp.appendingPathComponent("build_report.json"))
        try? fm.removeItem(at: out)
        try fm.moveItem(at: tmp, to: out)
        log("wrote \(out.path): \(entries.count) slides, \(videos) video, \(notes.count) slide(s) with notes")
        if openInPresenter { log(await Self.handBack(out) ? "  handed to ARC Presenter" : "  ARC Presenter not running; open the deck by hand") }
        return Result(deck: out, slides: entries.count, videos: videos, notes: notes.count, items: results)
    }

    // MARK: Capture with cache

    private func capture(_ item: URL, work: URL) async throws -> (URL?, CaptureReport?) {
        let ext = item.pathExtension.lowercased()
        let base = item.deletingPathExtension().lastPathComponent
        let outDir = work.appendingPathComponent(base)
        let reportURL = outDir.appendingPathComponent("report.json")
        let fm = FileManager.default
        var source = item
        if Self.linkExt.contains(ext) {
            guard let link = Self.linkURL(item) else { log("  \(item.lastPathComponent): no URL in the link file"); return (nil, nil) }
            source = link
        }
        // Reuse a capture that is newer than its source.
        if !force, let data = try? Data(contentsOf: reportURL), let rep = try? JSONDecoder.arc.decode(CaptureReport.self, from: data), rep.ok,
           let out = rep.output, fm.fileExists(atPath: out),
           (try? fm.attributesOfItem(atPath: reportURL.path)[.modificationDate] as? Date) ?? .distantPast >= ((try? fm.attributesOfItem(atPath: item.path)[.modificationDate] as? Date) ?? .distantFuture) {
            log("  reuse  \(base)")
            return (URL(fileURLWithPath: out), rep)
        }
        try? fm.removeItem(at: outDir); try fm.createDirectory(at: outDir, withIntermediateDirectories: true)
        log("  capture \(base) …")
        let session = CaptureSession()
        session.sourceFile = source; session.outputDirectory = outDir
        currentSession = session
        defer { currentSession = nil }
        let t0 = Date()
        do {
            let rep = try await session.run()
            try? rep.write(to: reportURL)
            log("          \(rep.ok ? "ok" : "FAILED \(rep.error ?? "")") in \(Int(Date().timeIntervalSince(t0))) s, \(rep.slides.count) slides")
            return (rep.output.map { URL(fileURLWithPath: $0) }, rep)
        } catch {
            log("          FAILED \(error.localizedDescription)")
            return (nil, session.report)
        }
    }

    // MARK: Helpers

    /// PDFKit has no document append: copy the pages across.
    static func append(_ src: PDFDocument, to doc: PDFDocument) {
        for i in 0..<src.pageCount { if let p = src.page(at: i) { doc.insert(p, at: doc.pageCount) } }
    }

    static func readDeck(_ deck: URL) -> ([[String: Any]], [Int: String]) {
        var slides: [[String: Any]] = []; var notes: [Int: String] = [:]
        if let data = try? Data(contentsOf: deck.appendingPathComponent("manifest.json")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { slides = (json["slides"] as? [[String: Any]]) ?? [] }
        if let data = try? Data(contentsOf: deck.appendingPathComponent("notes.json")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            for (k, v) in json { if let n = Int(k) { notes[n] = v } }
        }
        return (slides, notes)
    }

    static func linkURL(_ file: URL) -> URL? {
        if file.pathExtension.lowercased() == "webloc", let data = try? Data(contentsOf: file),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any], let s = plist["URL"] as? String { return URL(string: s) }
        if let text = try? String(contentsOf: file, encoding: .utf8) {
            for line in text.split(separator: "\n") where line.hasPrefix("URL=") { return URL(string: String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)) }
        }
        return nil
    }

    /// A 1920x1080 black page with the image fitted, like the Python builder.
    static func canvasPage(_ image: NSImage) -> PDFPage? {
        let canvas = NSImage(size: NSSize(width: 1920, height: 1080))
        canvas.lockFocus()
        NSColor.black.setFill(); NSRect(x: 0, y: 0, width: 1920, height: 1080).fill()
        let s = image.size; let scale = min(1920 / max(s.width, 1), 1080 / max(s.height, 1))
        let w = s.width * scale, h = s.height * scale
        image.draw(in: NSRect(x: (1920 - w) / 2, y: (1080 - h) / 2, width: w, height: h), from: .zero, operation: .sourceOver, fraction: 1)
        canvas.unlockFocus()
        return PDFPage(image: canvas)
    }

    static func firstFrame(_ movie: URL) -> NSImage? {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: movie)); gen.appliesPreferredTrackTransform = true
        guard let cg = try? gen.copyCGImage(at: CMTime(seconds: 0.2, preferredTimescale: 600), actualTime: nil) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    /// PowerPoint speaker notes, 1-based slide -> text, read straight from the zip.
    nonisolated static func pptxNotes(_ pptx: URL) -> [Int: String] {
        func entry(_ name: String) -> String? {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip"); p.arguments = ["-p", pptx.path, name]
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
            return p.terminationStatus == 0 ? String(data: data, encoding: .utf8) : nil
        }
        func matches(_ pattern: String, _ text: String) -> [[String]] {
            let re = try! NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
            let ns = text as NSString
            return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in (1..<m.numberOfRanges).map { ns.substring(with: m.range(at: $0)) } }
        }
        guard let pres = entry("ppt/presentation.xml"), let prels = entry("ppt/_rels/presentation.xml.rels") else { return [:] }
        let targets = Dictionary(matches(#"<Relationship[^>]*Id="([^"]+)"[^>]*Target="([^"]+)""#, prels).map { ($0[0], $0[1]) } + matches(#"<Relationship[^>]*Target="([^"]+)"[^>]*Id="([^"]+)""#, prels).map { ($0[1], $0[0]) }, uniquingKeysWith: { a, _ in a })
        let order = matches(#"<p:sldId [^>]*r:id="([^"]+)""#, pres).compactMap { targets[$0[0]] }
        var notes: [Int: String] = [:]
        for (n, target) in order.enumerated() {
            let slide = (target as NSString).lastPathComponent
            guard let srels = entry("ppt/slides/_rels/\(slide).rels"),
                  let ns = matches(#"<Relationship[^>]*Target="([^"]*notesSlide[^"]*)""#, srels).first?.first,
                  let xml = entry("ppt/notesSlides/" + (ns as NSString).lastPathComponent) else { continue }
            // Body placeholder only (the slide-number placeholder is skipped).
            var paras: [String] = []
            for sp in matches(#"(<p:sp>.*?</p:sp>)"#, xml).map({ $0[0] }) where sp.contains(#"type="body""#) {
                for p in matches(#"<a:p>(.*?)</a:p>"#, sp).map({ $0[0] }) {
                    let t = matches(#"<a:t>([^<]*)</a:t>"#, p).map { $0[0] }.joined().trimmingCharacters(in: .whitespaces)
                    if !t.isEmpty { paras.append(t) }
                }
            }
            let text = paras.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { notes[n + 1] = text }
        }
        return notes
    }

    static func copyOrTranscode(_ src: URL, to dst: URL) -> String {
        let ffprobe = PPTXAnalyzer.ffprobeURL, ffmpeg = PPTXAnalyzer.ffmpegURL
        var video = "", audio = ""
        if let ffprobe {
            let p = Process(); p.executableURL = ffprobe
            p.arguments = ["-v", "error", "-show_entries", "stream=codec_type,codec_name", "-of", "json", src.path]
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
            if (try? p.run()) != nil {
                let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let streams = json["streams"] as? [[String: Any]] {
                    video = streams.first { ($0["codec_type"] as? String) == "video" && ($0["codec_name"] as? String) != "mjpeg" }?["codec_name"] as? String ?? ""
                    audio = streams.first { ($0["codec_type"] as? String) == "audio" }?["codec_name"] as? String ?? ""
                }
            }
        }
        let ext = src.pathExtension.lowercased()
        if video == "h264", audio.isEmpty || audio == "aac", ["mov", "mp4", "m4v"].contains(ext) {
            try? FileManager.default.copyItem(at: src, to: dst); return "copied"
        }
        guard let ffmpeg else { try? FileManager.default.copyItem(at: src, to: dst); return "copied (no ffmpeg to transcode \(video)/\(audio))" }
        let p = Process(); p.executableURL = ffmpeg
        p.arguments = ["-nostdin", "-v", "error", "-y", "-i", src.path, "-map", "0:v:0", "-map", "0:a?", "-c:v", "h264_videotoolbox", "-b:v", "16M", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart", dst.path]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        if (try? p.run()) != nil { p.waitUntilExit() }
        return "transcoded from \(video)/\(audio)"
    }

    static func handBack(_ deck: URL) async -> Bool {
        guard let url = URL(string: "http://localhost:8760/open?path=" + (deck.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? deck.path)) else { return false }
        var req = URLRequest(url: url); req.httpMethod = "POST"; req.timeoutInterval = 20
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }
}

extension JSONDecoder {
    /// Reports carry ISO dates written by CaptureReport.write.
    static var arc: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}

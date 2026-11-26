//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation
import AVFoundation
import AppKit
import PDFKit
import CryptoKit
import ARCShowFormat

/// A slide that LINKS to an online video (a picture with a hyperlink to YouTube, an "online video" PowerPoint
/// inserted) has no movie in the source: a click on it in the room opens a browser, and the capture records a
/// black page or the browser. 2026-09-19: "any link to a YouTube video should use ARC Grab to download
/// and convert the video and then play it locally." The analyzer names the link per slide, ARC Grab fetches
/// it (once per show folder, `state/grabs/<id>.mp4`), and the splitter makes the download the page's clip,
/// started by the page's click, as it does for a click-started source movie. A link that cannot be fetched
/// lands in REVIEW as R13; the page is never left as a silent black.
enum OnlineVideo {
    /// The video's id on its site, or nil when the URL is not one ARC Grab is asked for (YouTube, Vimeo).
    static func id(of url: String) -> String? {
        guard let c = URLComponents(string: url.trimmingCharacters(in: .whitespacesAndNewlines)), let host = c.host?.lowercased() else { return nil }
        let path = c.path
        func clean(_ s: String) -> String? { let t = s.filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }; return t.isEmpty ? nil : t }
        if host == "youtu.be" { return path.split(separator: "/").first.flatMap { clean(String($0)) } }
        if host.hasSuffix("youtube.com") || host.hasSuffix("youtube-nocookie.com") {
            if let v = c.queryItems?.first(where: { $0.name == "v" })?.value { return clean(v) }
            let parts = path.split(separator: "/").map(String.init)
            if parts.count >= 2, ["embed", "shorts", "live", "v"].contains(parts[0]) { return clean(parts[1]) }
            return nil
        }
        if host.hasSuffix("vimeo.com") {
            let digits = path.split(separator: "/").map(String.init).last { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
            return digits.map { "vimeo-" + $0 }
        }
        return nil
    }

    /// A stable file stem for the download: the site's id, the file share's handle, or a hash of the URL.
    static func stem(for url: String) -> String {
        if let id = id(of: url) { return id }
        if let s = FileShare.source(of: url) { return FileShare.stem(s, url: url) }
        return "grab-" + SHA256.hash(data: Data(url.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    /// A link this path takes: a streaming player ARC Grab fetches, or a file a sharing service hands out.
    static func isVideoLink(_ url: String) -> Bool { id(of: url) != nil || FileShare.source(of: url) != nil }

    /// The online-video links a slide's rels carry (`TargetMode="External"` relationships whose Target is a
    /// video page), in file order, `&amp;` unescaped.
    static func links(inRels rels: String) -> [String] {
        let ns = rels as NSString
        let tag = try! NSRegularExpression(pattern: #"<Relationship\b[^>]*>"#, options: [.caseInsensitive])
        let target = try! NSRegularExpression(pattern: #"\bTarget="([^"]+)""#, options: [.caseInsensitive])
        var out: [String] = []
        for m in tag.matches(in: rels, range: NSRange(location: 0, length: ns.length)) {
            let t = ns.substring(with: m.range)
            guard t.range(of: #"TargetMode="External""#, options: .caseInsensitive) != nil,
                  let tm = target.firstMatch(in: t, range: NSRange(location: 0, length: (t as NSString).length)) else { continue }
            let raw = (t as NSString).substring(with: tm.range(at: 1))
                .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&quot;", with: "\"")
            if isVideoLink(raw), !out.contains(raw) { out.append(raw) }
        }
        return out
    }
}

/// ARC Grab from ARC Capture: `ARC Grab --grab URL --into DIR --name STEM` (HeadlessGrab in arc-grab, 1.5.0).
/// One line back, `GRABBED <path>` or `FAILED <why>`. Found at `/Applications/ARC Grab.app`, or where the
/// `arcGrabApp` default points. A fetch already in the folder is reused: the show is built more than once.
enum ArcGrabBridge {
    static let appKey = "arcGrabApp"
    static let timeout: TimeInterval = 15 * 60

    static func app() -> URL? {
        var candidates: [String] = []
        if let d = UserDefaults.standard.string(forKey: appKey), !d.isEmpty { candidates.append((d as NSString).expandingTildeInPath) }
        candidates += ["/Applications/ARC Grab.app", ("~/Applications/ARC Grab.app" as NSString).expandingTildeInPath]
        for c in candidates {
            let exe = URL(fileURLWithPath: c).appendingPathComponent("Contents/MacOS/ARC Grab")
            if FileManager.default.isExecutableFile(atPath: exe.path) { return URL(fileURLWithPath: c) }
        }
        return nil
    }

    /// The download, or why there is none. Never throws; the caller words the review row.
    static func grab(_ url: String, into dir: URL, log: (String) -> Void) async -> Result<URL, GrabError> {
        let fm = FileManager.default
        let stem = OnlineVideo.stem(for: url)
        let cached = dir.appendingPathComponent(stem + ".mp4")
        if let have = FileShare.cached(stem: stem, in: dir) {
            log("online video \(stem): already here (\(have.lastPathComponent))"); return .success(have)
        }
        _ = cached
        guard let app = app() else { return .failure(GrabError("ARC Grab is not installed (looked in /Applications)")) }
        let version = (Bundle(url: app)?.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
        guard version.compare("1.5.0", options: .numeric) != .orderedAscending else {
            return .failure(GrabError("ARC Grab \(version) at \(app.path) is too old; 1.5.0 fetches for Capture"))
        }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        log("online video \(stem): fetching with ARC Grab \(version) …")
        let exe = app.appendingPathComponent("Contents/MacOS/ARC Grab")
        let p = Process(); p.executableURL = exe
        p.arguments = ["--grab", url, "--into", dir.path, "--name", stem, "--quality", "1080"]
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return .failure(GrabError("ARC Grab could not be started: \(error.localizedDescription)")) }
        let t0 = Date()
        let text: String = await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                cont.resume(returning: String(decoding: data, as: UTF8.self))
            }
        }
        _ = t0
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        if let g = lines.last(where: { $0.hasPrefix("GRABBED ") }) {
            let path = String(g.dropFirst(8))
            guard (try? fm.attributesOfItem(atPath: path)[.size] as? Int) ?? 0 > 1000 else { return .failure(GrabError("ARC Grab reported a file that is not there: \(path)")) }
            log("online video \(stem): fetched in \(Int(Date().timeIntervalSince(t0))) s")
            return .success(URL(fileURLWithPath: path))
        }
        let why = lines.last(where: { $0.hasPrefix("FAILED ") }).map { String($0.dropFirst(7)) } ?? "ARC Grab exited \(p.terminationStatus) without a verdict"
        return .failure(GrabError(why))
    }

    struct GrabError: Error, CustomStringConvertible { let description: String; init(_ s: String) { description = s } }
}

extension BuildSplitter {
    enum OnlinePlacement {
        /// The page with the fetched video as its clip, started by the page's click.
        case placed(DeckManifest.Slide)
        /// The page annotated with the link and why it was not placed (R13 in the review).
        case notPlaced(DeckManifest.Slide, why: String)
        /// Nothing to do (a logo page, or the video is already in place).
        case untouched
    }

    /// A page with builds keeps them: the movie is its clip, played by Presenter on the click after the last
    /// build (Deck.movieAfterBuilds, Presenter 5.2); no hold is made, the state stills are the page until then.
    static func useOnlineVideo(_ page: DeckManifest.Slide, in deck: URL, url: String, grabDir: URL?, log: (String) -> Void) async -> OnlinePlacement {
        let stem = OnlineVideo.stem(for: url)
        func annotate(_ why: String) -> OnlinePlacement {
            var p = page
            var m = (p.media ?? []).filter { $0.url != url }
            // The way round any of it: the operator downloads the file by hand and puts it in the grabs folder under this name.
            let byHand = "; or put the file at state/grabs/\(stem).mp4 by hand and FETCH IT AGAIN"
            m.append(DeckManifest.Media(kind: .video, name: "not fetched: \(why)\(byHand)", url: url))
            p.media = m
            log("slide \(page.slide): links to an online video (\(url)) that is not placed: \(why)")
            return .notPlaced(p, why: why + byHand)
        }
        guard page.role == nil else { return .untouched }
        guard !(page.sourceMovie == true && page.media?.contains(where: { $0.url == url }) == true) else { return .untouched }
        guard let grabDir else { return annotate("no folder for downloads in this run") }
        guard let ffmpeg = PPTXAnalyzer.ffmpegURL else { return annotate("ffmpeg is missing") }
        let fetched: URL
        if OnlineVideo.id(of: url) != nil {
            // A streaming player: ARC Grab.
            switch await ArcGrabBridge.grab(url, into: grabDir, log: log) {
            case .success(let u): fetched = u
            case .failure(let e): return annotate(e.description)
            }
        } else {
            // A file on a sharing service, or a direct link: Capture's own download (FileShare.swift).
            switch await FileShare.fetch(url: url, into: grabDir, log: log) {
            case .success(let u): fetched = u
            case .failure(let e) where e.notVideo:
                log("slide \(page.slide): the link (\(url)) is left alone, \(e.description)")
                return .untouched
            case .failure(let e): return annotate(e.description)
            }
        }
        let fm = FileManager.default
        let asset = AVURLAsset(url: fetched)
        guard let seconds = try? await asset.load(.duration).seconds, seconds > 0.5,
              let track = try? await asset.loadTracks(withMediaType: .video).first,
              let size = try? await track.load(.naturalSize) else { return annotate("the download has no playable picture") }
        let pageStem = page.file.map { ($0 as NSString).lastPathComponent }.map { ($0 as NSString).deletingPathExtension } ?? String(format: "slide_%03d", page.slide)
        let movieRel = "media/\(pageStem).mp4"
        let movieURL = deck.appendingPathComponent(movieRel)
        try? fm.createDirectory(at: movieURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: movieURL)
        do { try fm.copyItem(at: fetched, to: movieURL) } catch { return annotate("the download could not be copied into the deck: \(error.localizedDescription)") }
        var out = page
        // The way in: what was recorded of the page before its click stays as the hold on the poster, unless it
        // ends black (nothing drawn). A still page that is not black gets a one-second hold of its picture, so
        // the room sees the slide, not the movie's first frame, until the click.
        if let rel = page.file {
            let clip = deck.appendingPathComponent(rel)
            if page.entryFile == nil, movieRel != rel, !(await BlackPages.clipTailIsBlack(clip)) {
                let inRel = "media/\(pageStem)_in.mov"
                try? fm.removeItem(at: deck.appendingPathComponent(inRel))
                try? fm.moveItem(at: clip, to: deck.appendingPathComponent(inRel))
                out.entryFile = inRel; out.entryClicks = [0]
            } else if movieRel != rel {
                try? fm.removeItem(at: clip)
            }
        } else if let ef = page.entryFile, await BlackPages.clipTailIsBlack(deck.appendingPathComponent(ef)) {
            try? fm.removeItem(at: deck.appendingPathComponent(ef)); out.entryFile = nil; out.entryClicks = nil
        } else if page.entryFile == nil, (page.builds ?? []).isEmpty, let hold = await stillHold(of: page, in: deck, stem: pageStem, ffmpeg: ffmpeg) {
            out.entryFile = hold; out.entryClicks = [0]
        }
        out.type = .video
        out.file = movieRel
        out.clicks = [0]; out.entryClick = nil; out.stopAt = nil; out.transition = nil; out.loop = nil; out.loopStart = nil
        out.sourceMovie = true
        out.mediaStart = .inClickSequence
        var media = (page.media ?? []).filter { $0.url == nil }
        media.append(DeckManifest.Media(kind: .video, name: (movieRel as NSString).lastPathComponent, seconds: seconds, width: Int(size.width), height: Int(size.height),
                                        videoCodec: "h264", fillsSlide: true, url: url))
        out.media = media
        let after = (page.builds ?? []).isEmpty ? "" : " after its \(page.builds!.count) build(s)"
        log("slide \(page.slide): the online video it links to (\(stem), \(String(format: "%.0f", seconds)) s) is the clip, fetched by ARC Grab; starts on the page's click\(after)")
        return .placed(out)
    }

    /// A one-second clip of the page's still (slides.pdf), for the hold before the click. nil when the page is
    /// black or cannot be drawn.
    private static func stillHold(of page: DeckManifest.Slide, in deck: URL, stem: String, ffmpeg: URL) async -> String? {
        guard let pdf = PDFDocument(url: deck.appendingPathComponent("slides.pdf")), let pg = pdf.page(at: page.slide - 1) else { return nil }
        let bounds = pg.bounds(for: .mediaBox)
        let w = 1920.0, h = (bounds.height / max(1, bounds.width) * 1920).rounded(.down)
        let img = pg.thumbnail(of: CGSize(width: w, height: h), for: .mediaBox)
        guard !BlackPages.isBlack(img), let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("hold-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard (try? png.write(to: tmp)) != nil else { return nil }
        let rel = "media/\(stem)_in.mov"
        let dest = deck.appendingPathComponent(rel)
        try? FileManager.default.removeItem(at: dest)
        let p = Process(); p.executableURL = ffmpeg
        p.arguments = ["-nostdin", "-v", "error", "-y", "-loop", "1", "-i", tmp.path, "-t", "1", "-r", "30", "-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2",
                       "-c:v", "h264_videotoolbox", "-b:v", "8M", "-pix_fmt", "yuv420p", "-movflags", "+faststart", dest.path]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0, (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int) ?? 0 > 1000 else { try? FileManager.default.removeItem(at: dest); return nil }
        return rel
    }
}

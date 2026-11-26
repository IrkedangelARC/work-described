//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation
import AVFoundation
import ARCShowFormat

/// A page whose movie plays on entry and fills the frame gets the SOURCE MOVIE as its clip, copied out of
/// the pptx, instead of a recording of PowerPoint playing it. The way in (the transition) is still the
/// recording, as its own `entryFile`; Presenter plays that, then the movie.
///
/// Why (2026-09-17): a recording of an on-entry movie carried its sound 350-590 ms ahead of its picture,
/// and the gap DRIFTED within a clip, in both directions, on both machines measured with the flash+click
/// reference deck, while PowerPoint's own output was in sync in the room. PowerPoint presents the movie's
/// picture on a timeline that slips against the audio it plays; no fixed offset can correct a recording of
/// that. The source file has no such problem, and it is the original quality, and it takes seconds to copy
/// where the recording took the movie's whole length.
extension BuildSplitter {
    /// Why a page cannot use its source movie; nil when it can.
    /// `forced`: the recording is black, or the reviewer asked (USE THE SOURCE MOVIE): a movie that starts on a
    /// click, or already has its way in separate, is taken too; the hold on its poster is kept as the way in
    /// and the page's one click starts the movie, as the capture writes such a page (2026-09-19: "the fact
    /// that you know there are movies on those slides should be the reason these were not skipped").
    static func sourceMovieObstacle(_ page: DeckManifest.Slide, forced: Bool = false) -> String? {
        guard page.role == nil else { return "a logo page" }
        guard page.type == .video, page.file != nil else { return "no clip" }
        guard forced || page.entryFile == nil else { return "already has its way in separate" }
        guard page.loop != true else { return "a looping movie (the loop separator owns it)" }
        guard forced || page.mediaStart == .onEntry else { return "the movie does not play on entry" }
        guard (page.builds ?? []).isEmpty else { return "the slide has builds" }
        guard forced || (page.clicks ?? []).count <= (page.entryClick ?? -1) + 1 else { return "the slide has clicks of its own after entry" }
        let movies = (page.media ?? []).filter { $0.kind == .video }
        guard movies.count == 1, let m = movies.first else { return movies.isEmpty ? "no movie on the slide" : "\(movies.count) movies on the slide" }
        guard (page.media ?? []).count == 1 else { return "other media on the slide besides the movie" }
        guard m.fillsSlide == true else { return "the movie does not fill the slide" }
        guard let codec = m.videoCodec, ["h264", "hevc", "prores", "mpeg4"].contains(codec.lowercased()) else { return "video codec \(m.videoCodec ?? "?") is not one Presenter plays" }
        guard ["mp4", "m4v", "mov"].contains((m.name as NSString).pathExtension.lowercased()) else { return "container .\((m.name as NSString).pathExtension) is not one Presenter plays" }
        guard let seconds = m.seconds, seconds > 0.5 else { return "no duration" }
        return nil
    }

    /// ffmpeg arguments that turn the source movie into the page's clip: a plain stream copy unless
    /// PowerPoint trims it or mutes it. A trim re-encodes the picture so the cut lands on the frame (a
    /// stream-copy seek snaps to the keyframe before it). The sound is never re-encoded for VOLUME: PowerPoint
    /// writes vol="80000" on every movie it inserts, so honouring it would quieten every deck by 2 dB on a
    /// default, and the room's level is the operator's anyway; the value is kept in the manifest.
    static func sourceMovieArgs(source: URL, dest: URL, trimStart: Double?, trimEnd: Double?, volume: Double?, muted: Bool?) -> [String] {
        var a = ["-y", "-hide_banner", "-loglevel", "error"]
        let trimmed = (trimStart ?? 0) > 0 || (trimEnd ?? 0) > 0
        if let st = trimStart, st > 0 { a += ["-ss", String(format: "%.3f", st)] }
        a += ["-i", source.path]
        if let en = trimEnd, en > 0 { a += ["-to", String(format: "%.3f", en - (trimStart ?? 0))] }
        if trimmed { a += ["-c:v", "h264_videotoolbox", "-q:v", "70", "-pix_fmt", "yuv420p"] } else { a += ["-c:v", "copy"] }
        if muted == true { a += ["-an"] } else { a += ["-c:a", "copy"] }
        a += ["-map", "0:v:0", "-map", muted == true ? "-0:a" : "0:a:0?", "-movflags", "+faststart", dest.path]
        return a
    }

    /// The page with its movie swapped in, or nil when it does not qualify or the pptx lacks the file.
    /// `freshMedia`: the pptx's media for this slide as the analyzer reads it NOW. A deck captured by an
    /// older Capture carries media entries without the placement fields, and a reprocess must not be
    /// refused on the strength of what an older writer did not know.
    static func useSourceMovie(_ page: DeckManifest.Slide, in deck: URL, pptx: URL, freshMedia: [DeckManifest.Media]? = nil, forced: Bool = false, log: (String) -> Void) async throws -> DeckManifest.Slide? {
        var page = page
        if let fresh = freshMedia, !fresh.isEmpty { page.media = fresh }
        if let why = sourceMovieObstacle(page, forced: forced) {
            if page.mediaStart == .onEntry || forced, page.type == .video { log("slide \(page.slide): recording kept, \(why)") }
            return nil
        }
        let clickStarted = page.mediaStart != .onEntry
        guard let m = page.media?.first, let rel = page.file, let ffmpeg = PPTXAnalyzer.ffmpegURL else { return nil }
        let fm = FileManager.default
        // The movie, out of the pptx (a zip) into a temp file.
        let tmp = fm.temporaryDirectory.appendingPathComponent("srcmovie-\(UUID().uuidString)").appendingPathExtension((m.name as NSString).pathExtension)
        defer { try? fm.removeItem(at: tmp) }
        let unzip = Process(); unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-p", pptx.path, "ppt/media/\(m.name)"]
        fm.createFile(atPath: tmp.path, contents: nil)
        unzip.standardOutput = try FileHandle(forWritingTo: tmp); unzip.standardError = FileHandle.nullDevice
        try unzip.run(); unzip.waitUntilExit()
        guard unzip.terminationStatus == 0, (try? fm.attributesOfItem(atPath: tmp.path)[.size] as? Int) ?? 0 > 1000 else {
            log("slide \(page.slide): recording kept, ppt/media/\(m.name) is not in \(pptx.lastPathComponent)"); return nil
        }
        // The way in: from the entry click to where PowerPoint starts the movie (transition + margin), as the loop separator cuts it.
        let clip = deck.appendingPathComponent(rel)
        let total = try await AVURLAsset(url: clip).load(.duration).seconds
        let mark = page.entryClick.flatMap { i in page.clicks.flatMap { $0.indices.contains(i) ? $0[i] : nil } } ?? 0
        // On entry: the way in runs to where PowerPoint starts the movie. Click-started: to the click that starts it.
        let from = clickStarted ? min(total, page.clicks?.last ?? mark) : min(total, mark + max(0, page.transitionSeconds ?? 0) + 0.15)
        let dir = clip.deletingLastPathComponent(), stem = clip.deletingPathExtension().lastPathComponent
        var out = page
        if let existing = page.entryFile {
            // A way in already separate stays, unless it ends black: the hold on the poster PowerPoint never drew.
            if await BlackPages.clipTailIsBlack(deck.appendingPathComponent(existing)) {
                try? fm.removeItem(at: deck.appendingPathComponent(existing)); out.entryFile = nil; out.entryClicks = nil
                log("slide \(page.slide): the recorded way in is black and goes; the movie's first frame is the poster")
            }
        } else if from - mark > 0.2 {
            let inRel = "media/\(stem)_in.mov"
            try await cut(source: clip, from: mark, to: from, into: deck.appendingPathComponent(inRel))
            if await BlackPages.clipTailIsBlack(deck.appendingPathComponent(inRel)) {
                try? fm.removeItem(at: deck.appendingPathComponent(inRel))
                log("slide \(page.slide): the recorded way in is black and goes; the movie's first frame is the poster")
            } else {
                out.entryFile = inRel; out.entryClicks = [0]
            }
        }
        // The movie itself, as the page's clip.
        let ext = (m.name as NSString).pathExtension.lowercased()
        let movieRel = "media/\(stem).\(ext)"
        let movieURL = deck.appendingPathComponent(movieRel)
        try? fm.removeItem(at: movieURL)
        let p = Process(); p.executableURL = ffmpeg
        p.arguments = sourceMovieArgs(source: tmp, dest: movieURL, trimStart: m.trimStart, trimEnd: m.trimEnd, volume: m.volume, muted: m.muted)
        let err = Pipe(); p.standardError = err; p.standardOutput = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0, (try? fm.attributesOfItem(atPath: movieURL.path)[.size] as? Int) ?? 0 > 1000 else {
            let e = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            try? fm.removeItem(at: movieURL); if let ef = out.entryFile { try? fm.removeItem(at: deck.appendingPathComponent(ef)) }
            log("slide \(page.slide): recording kept, ffmpeg failed on the source movie: \(e.suffix(160))"); return nil
        }
        if movieRel != rel { try? fm.removeItem(at: clip) }
        out.file = movieRel
        // A click-started movie keeps ONE click of its own, at the head of its clip: Presenter holds on the first
        // frame until it, as it does for such a page the capture wrote.
        out.clicks = clickStarted ? [0] : nil; out.entryClick = nil; out.stopAt = nil; out.transition = nil; out.loopStart = nil
        out.sourceMovie = true
        let how = (m.trimStart ?? 0) > 0 || (m.trimEnd ?? 0) > 0 ? "trimmed as PowerPoint trims it" : (m.muted == true ? "muted as PowerPoint mutes it" : "copied")
        let wayIn = out.entryFile == nil ? "a cut, no way in to keep" : "the way in (\(String(format: "%.1f", from - mark)) s) is recorded"
        log("slide \(page.slide): the source movie \(m.name) (\(String(format: "%.1f", m.seconds ?? 0)) s) is the clip, \(how); \(wayIn)\(clickStarted ? "; starts on the page's click" : "")\(forced ? " (forced: the recording was black or the reviewer asked)" : "")")
        return out
    }
}

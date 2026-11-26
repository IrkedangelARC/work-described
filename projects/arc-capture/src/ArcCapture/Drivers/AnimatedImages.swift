//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation

/// How long does the animation on this slide take to come back round?
///
/// Google Slides stores an animated GIF as an IMAGE, so neither the Slides API
/// nor `viewerData` calls it a video. Capture therefore treated those slides as
/// ordinary motion slides and let the settle end them: a client deck's slide 34 holds a
/// 45.6 s animation and got a 2.1 s clip, and slide 19's 30 s animation was
/// captured as a still. A small animated region cannot move enough of the frame
/// to clear `FrameAnalysis.settleThreshold`, so the slide looks finished while
/// it is still playing.
///
/// The fix is to know the loop length up front, which makes the slide behave
/// exactly like a "Loop until Stopped" movie: record ONE pass and mark the
/// entry `loop: true`, so Presenter loops it until the operator clicks.
///
/// **A GIF is periodic, so one period recorded from ANY starting phase loops
/// seamlessly** — the last frame is followed by the first by construction.
/// That is why the capture never has to find the animation's loop point.
///
/// Measured 2026-09-15 on a client deck's slide 34: the URL in `viewerData` field 13
/// serves the real GIF (36.6 MB, 228 frames, 45.6 s), byte-identical in length
/// to the copy in the deck's PPTX export. No API and no OAuth involved.
enum AnimatedImages {
    /// Loop length of an animated image, or nil for a still.
    struct Loop: Equatable {
        var seconds: TimeInterval
        var frames: Int
    }

    /// GIF is the only animated still-image format Slides serves. APNG and
    /// animated WebP are not produced by the Slides image service today; if
    /// that changes this is where to add them.
    static func isGIF(_ head: Data) -> Bool { head.count >= 6 && head.prefix(3) == Data("GIF".utf8) }

    /// `ffprobe -count_frames` on a file -> loop length. Split out and pure so
    /// the parsing is testable without a network or a real GIF.
    static func parseProbe(_ output: String) -> Loop? {
        let fields = output.split(whereSeparator: \.isNewline).map(String.init)
        guard let frames = fields.compactMap({ Int($0) }).first,
              let seconds = fields.compactMap({ Double($0) }).last,
              frames > 1, seconds > 0 else { return nil }
        return Loop(seconds: (seconds * 1000).rounded() / 1000, frames: frames)
    }

    /// Fetch just enough bytes to tell a GIF from a PNG, then measure only the
    /// GIFs. A deck's pictures are mostly large PNGs and pulling them all would
    /// cost hundreds of MB for nothing.
    static func loop(at urlString: String,
                     head: @escaping @Sendable (URL) async -> Data? = Self.firstBytes,
                     download: @escaping @Sendable (URL) async -> URL? = Self.toTempFile) async -> Loop? {
        guard let url = URL(string: urlString), let magic = await head(url), isGIF(magic) else { return nil }
        guard let file = await download(url) else { return nil }
        defer { try? FileManager.default.removeItem(at: file) }
        guard let ffprobe = PPTXAnalyzer.ffprobeURL else {
            DebugLog.log("Driver", "no ffprobe: cannot measure an animated GIF's loop")
            return nil
        }
        let p = Process()
        p.executableURL = ffprobe
        p.arguments = ["-v", "error", "-count_frames",
                       "-show_entries", "stream=nb_read_frames",
                       "-show_entries", "format=duration",
                       "-of", "default=nw=1:nk=1", file.path]
        let out = Pipe()
        p.standardOutput = out; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return parseProbe(String(data: data, encoding: .utf8) ?? "")
    }

    /// Longest animation per slide. A slide is held open for its LONGEST loop,
    /// so every animation on it completes at least once; a shorter one on the
    /// same slide will not line up with the loop point unless its period
    /// divides the longest (a client deck's slide 25 carries 19.1 s and 59.9 s, which do
    /// not divide, so that one visibly re-starts mid-clip).
    static func loopsBySlide(in deck: SlidesInfo,
                             head: @escaping @Sendable (URL) async -> Data? = Self.firstBytes,
                             download: @escaping @Sendable (URL) async -> URL? = Self.toTempFile) async -> [Int: Loop] {
        var result: [Int: Loop] = [:]
        for slide in deck.slides where !slide.imageURLs.isEmpty {
            var longest: Loop?
            for u in slide.imageURLs {
                guard let l = await loop(at: u, head: head, download: download) else { continue }
                if longest == nil || l.seconds > longest!.seconds { longest = l }
            }
            if let longest {
                result[slide.index] = longest
                DebugLog.log("Driver", "slide \(slide.index): animated image, \(longest.frames) frames, one loop \(longest.seconds) s")
            }
        }
        return result
    }

    // MARK: network

    private static func firstBytes(_ url: URL) async -> Data? {
        var req = URLRequest(url: url)
        req.setValue("bytes=0-5", forHTTPHeaderField: "Range")
        req.timeoutInterval = 15
        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return nil }
        return data
    }

    private static func toTempFile(_ url: URL) async -> URL? {
        var req = URLRequest(url: url)
        req.timeoutInterval = 120
        guard let (tmp, _) = try? await URLSession.shared.download(for: req) else { return nil }
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("arc-gif-\(UUID().uuidString).gif")
        try? FileManager.default.moveItem(at: tmp, to: dest)
        return FileManager.default.fileExists(atPath: dest.path) ? dest : nil
    }
}

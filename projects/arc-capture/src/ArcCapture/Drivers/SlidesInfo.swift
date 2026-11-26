//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation

/// Google Slides facts for a capture: slide order (objectIds), skipped
/// slides, and which slides carry video.
///
/// 2026-09-15 (second pass): this used to be fetched from the Slides + Drive
/// APIs with an OAuth token. That path is dead — the client needs
/// `drive.readonly`, a restricted scope, and Google hard-blocks an unverified
/// client asking for one, so no crew laptop could ever sign in. The facts now
/// come out of the present-mode page itself; see `SlidesViewerData`.
///
/// Video lengths are no longer part of this struct. They are not in the page
/// model, and the driver reads each one live off the slide it is on (the
/// embed iframe carries `length_seconds`), which is both exact and always
/// current.
struct SlidesInfo: Equatable {
    struct Video: Equatable {
        var source: String          // "DRIVE" or "YOUTUBE"
        var id: String              // Drive file id, or the YouTube video id
        var name: String            // file name / video title as Slides shows it
        var elementID: String       // page element objectId
        var muted: Bool
        var start: Double           // trim in, seconds (0 = none)
        var end: Double             // trim out, seconds (0 = none)
        var autoPlay: Bool
        var seconds: Double?
        /// Only a Drive-hosted video's length can be read off its embed.
        var isMeasurable: Bool { source == "DRIVE" }
    }
    struct Slide: Equatable {
        var index: Int              // 1-based
        var objectId: String
        var skipped: Bool
        var buildSteps: Int
        /// Where each picture element's bytes come from; an animated GIF is
        /// found by fetching these (see `AnimatedImages`).
        var imageURLs: [String] = []
        var videos: [Video]
    }
    var id: String
    var title: String
    var slides: [Slide]

    var presentURL: String { "https://docs.google.com/presentation/d/\(id)/present" }
    var hidden: Set<Int> { Set(slides.filter(\.skipped).map(\.index)) }
    var videoSlides: Set<Int> { Set(slides.filter { !$0.videos.isEmpty }.map(\.index)) }
    var autoPlaySlides: Set<Int> { Set(slides.filter { $0.videos.contains(where: \.autoPlay) }.map(\.index)) }
    /// Animation entries per slide from the page model.
    ///
    /// NOT a click count, and NOT safe to feed the capture's click walk: it
    /// read 1 on a client deck's slides 18 and 36 where one click starts the movie, and
    /// also 1 on slides 23 and 30 where a click advances the show and loses
    /// the slide (measured 2026-09-15). Kept only so the value is available to
    /// whoever decodes `docData[1][i][7]` properly.
    var animationEntries: [Int: Int] {
        var c: [Int: Int] = [:]
        for s in slides where s.buildSteps > 0 { c[s.index] = s.buildSteps }
        return c
    }
    /// Longest known video per slide. Empty at analysis time by design; the
    /// driver supplies each length live when the show reaches the slide.
    var slideDurations: [Int: TimeInterval] {
        var d: [Int: TimeInterval] = [:]
        for s in slides { if let m = s.videos.compactMap(\.seconds).max() { d[s.index] = m } }
        return d
    }

    enum FetchError: LocalizedError {
        case badArgument(String)
        var errorDescription: String? {
            switch self {
            case .badArgument(let a): "not a Google Slides link or id: \(a)"
            }
        }
    }

    /// A deck id from a presentation URL or a bare id.
    ///
    /// `name:<title>` lookup is gone with the Drive API: searching Drive by
    /// name needed the restricted scope that is now blocked. Pass the deck's
    /// URL (what an operator pastes anyway) or its id.
    static func deckID(_ arg: String) throws -> String {
        if let r = arg.range(of: #"/presentation/d/([A-Za-z0-9_-]+)"#, options: .regularExpression) {
            return String(arg[r]).replacingOccurrences(of: "/presentation/d/", with: "")
        }
        guard arg.range(of: #"^[A-Za-z0-9_-]{20,}$"#, options: .regularExpression) != nil else {
            throw FetchError.badArgument(arg)
        }
        return arg
    }

    /// Seconds a video actually plays, given the element's trim points.
    static func trimmed(full: Double, start: Double, end: Double) -> Double {
        var f = full
        if end > 0, end > start { f = min(f, end) - start } else if start > 0 { f = max(0, f - start) }
        return (f * 1000).rounded() / 1000
    }
}

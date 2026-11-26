//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation

/// Is a deck's YouTube video still there?
///
/// A Google Slides deck keeps playing a video that YouTube has since removed:
/// the slide renders a static "Video unavailable" card, and a capture happily
/// records that card for the whole unknown-length hold. A client speaker deck's slide
/// 9 cost ten minutes of dead air that way on 2026-09-15, and the run still
/// reported `ok: true` — nothing downstream can tell an unavailable video from
/// a silent one.
///
/// So ask YouTube at ANALYSIS time, which is days before show day rather than
/// during it. The oEmbed endpoint answers without a key, without a quota and
/// without the restricted OAuth scope that killed the Slides API path:
///
///   200        the video is there
///   401 / 403  the owner has disabled embedding (it exists, but will not play here)
///   404        removed, private, or never existed
///
/// Anything else is reported as unknown and NEVER as a dead link — an offline
/// laptop or a blocked network must not make a healthy deck look broken.
enum YouTubeAvailability {
    enum Status: Equatable {
        case available
        /// Will not play in the deck. The string says why, in an operator's words.
        case unavailable(String)
        /// Could not be determined. Never warned about.
        case unknown(String)

        var isUnavailable: Bool { if case .unavailable = self { return true }; return false }
    }

    static func oEmbedURL(for videoID: String) -> URL? {
        var c = URLComponents(string: "https://www.youtube.com/oembed")
        c?.queryItems = [URLQueryItem(name: "url", value: "https://www.youtube.com/watch?v=\(videoID)"),
                         URLQueryItem(name: "format", value: "json")]
        return c?.url
    }

    /// Pure: HTTP code -> verdict. Split out so the mapping is testable without
    /// the network.
    static func status(forHTTP code: Int) -> Status {
        switch code {
        case 200: .available
        case 401, 403: .unavailable("the owner has disabled embedding, so it will not play in the deck")
        case 404: .unavailable("removed, private, or deleted")
        default: .unknown("YouTube answered HTTP \(code)")
        }
    }

    /// One video. `http` is injectable so tests never touch the network.
    static func check(_ videoID: String,
                      http: @escaping @Sendable (URL) async -> Int? = Self.statusCode) async -> Status {
        guard !videoID.isEmpty, let url = oEmbedURL(for: videoID) else { return .unknown("no video id") }
        guard let code = await http(url) else { return .unknown("no answer from YouTube") }
        return status(forHTTP: code)
    }

    /// Warnings for every dead YouTube link in a deck, in slide order.
    ///
    /// Drive-hosted videos are not checked: the embed hands us their length at
    /// play time, which is itself proof they resolve, and the Drive API refuses
    /// files that were never shared with us even when they play perfectly well
    /// (measured on a client deck, three of four videos 404 from Drive and all four
    /// played).
    static func deadLinkWarnings(in deck: SlidesInfo,
                                 http: @escaping @Sendable (URL) async -> Int? = Self.statusCode) async -> [String] {
        let targets: [(slide: Int, video: SlidesInfo.Video)] = deck.slides.flatMap { s in
            s.videos.filter { $0.source == "YOUTUBE" && !$0.id.isEmpty }.map { (s.index, $0) }
        }
        guard !targets.isEmpty else { return [] }

        var found: [(Int, String)] = []
        await withTaskGroup(of: (Int, String, Status).self) { group in
            for t in targets {
                group.addTask { (t.slide, t.video.name, await check(t.video.id, http: http)) }
            }
            for await (slide, name, status) in group {
                if case .unavailable(let why) = status {
                    let title = name.isEmpty ? "the YouTube video" : "\"\(name)\""
                    found.append((slide, "slide \(slide): \(title) is UNAVAILABLE on YouTube (\(why)); "
                                       + "the slide will record as a static error card"))
                }
            }
        }
        return found.sorted { $0.0 < $1.0 }.map(\.1)
    }

    private static func statusCode(_ url: URL) async -> Int? {
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return nil }
        return (resp as? HTTPURLResponse)?.statusCode
    }
}

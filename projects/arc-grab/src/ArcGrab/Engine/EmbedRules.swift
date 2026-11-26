//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation

/// What an embedded player needs from us, by URL. Pure: every rule is a string in, strings out, so it is
/// unit-tested without a network (PLAN_arc_grab_multisite, step 2, 2026-09-17).
///
/// The tool is for the video a client has EMBEDDED on a page ("this tool is for embedded streaming
/// links"): a Vimeo, Wistia, Brightcove, JW Player, Kaltura or Panopto player, a Zoom recording, an HLS
/// manifest. Three things get pasted: the page, the player URL, or the manifest.
enum EmbedRules {
    /// The URL yt-dlp is given. A Vimeo PAGE (`vimeo.com/<id>`, `vimeo.com/<id>/<hash>`) is rewritten to its
    /// player endpoint: measured 2026-09-17, `vimeo.com/76979871` answers "the web client only works when
    /// logged-in" while `player.vimeo.com/video/76979871`, the embed every site uses, delivers with no login.
    /// Everything else is passed as pasted.
    static func normalize(_ url: String) -> String {
        guard let u = URL(string: url), let host = u.host?.lowercased() else { return url }
        if host == "vimeo.com" || host == "www.vimeo.com" {
            let parts = u.pathComponents.filter { $0 != "/" }
            // /<id> or /<id>/<hash>; never /showcase, /channels, /groups, /manage…
            if let id = parts.first, parts.count <= 2, id.allSatisfy(\.isNumber) {
                var out = "https://player.vimeo.com/video/\(id)"
                let hash = parts.count == 2 ? parts[1] : queryValue(u, "h")
                if let hash, !hash.isEmpty { out += "?h=\(hash)" }
                return out
            }
        }
        return url
    }

    /// An HLS / DASH manifest pasted straight: Generic extractor, one stream, label STREAM.
    static func isManifest(_ url: String) -> Bool {
        let path = (URL(string: url)?.path ?? url).lowercased()
        return path.hasSuffix(".m3u8") || path.hasSuffix(".mpd")
    }

    /// Hosts yt-dlp has a dedicated extractor for. Anything else goes through the Generic extractor, which
    /// is where a Cloudflare-fronted page or CDN wants a browser identity.
    static func isKnownPlayerHost(_ url: String) -> Bool {
        guard let host = URL(string: url)?.host?.lowercased() else { return false }
        let known = ["youtube.com", "youtu.be", "vimeo.com", "wistia.net", "wistia.com", "brightcove.net",
                     "jwplayer.com", "jwplatform.com", "kaltura.com", "panopto.com", "zoom.us", "vidyard.com",
                     "twitch.tv", "facebook.com", "instagram.com", "tiktok.com", "x.com", "twitter.com"]
        return known.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// The arguments an embed needs beyond the download itself. `referer` is the page the player lives on:
    /// a domain-locked Vimeo embed plays only when asked from there. `password` covers Vimeo review links
    /// and Zoom recordings. Unknown hosts and manifests get `generic:impersonate` (measured: a plain `.mp4`
    /// behind Cloudflare is a 403 without it; the bundled yt-dlp carries curl_cffi with Chrome-136 and
    /// Safari-18 targets).
    static func extraArgs(url: String, referer: String, password: String) -> [String] {
        var a: [String] = []
        let r = referer.trimmingCharacters(in: .whitespaces)
        if !r.isEmpty { a += ["--referer", r] }
        let p = password.trimmingCharacters(in: .whitespaces)
        if !p.isEmpty { a += ["--video-password", p] }
        if !isKnownPlayerHost(url) { a += ["--extractor-args", "generic:impersonate"] }
        return a
    }

    private static func queryValue(_ u: URL, _ name: String) -> String? {
        URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }
}

//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation

/// What `yt-dlp -J --flat-playlist` tells us about a URL before downloading.
struct MediaInfo: Equatable {
    var id: String
    var title: String
    var url: String
    var duration: Double?
    var thumbnail: String?
    var uploader: String?
    var maxHeight: Int?
    /// yt-dlp's `extractor_key` (Youtube, Vimeo, GoogleDrive, Dropbox, Generic, Zoom, Panopto…). The app
    /// used to assume YouTube everywhere; this is what it assumes now (PLAN_arc_grab_multisite, 2026-09-17).
    var extractorKey: String?
    /// A direct media file (Generic extractor, `direct: true`): no page, no streams to merge.
    var isDirectFile = false
    /// True when no video-only stream exists, so the download is ONE stream and the progress bar has one
    /// phase. nil = unknown (flat playlist entries carry no formats).
    var singleStream: Bool?
    /// A pasted HLS / DASH manifest (Generic extractor, every format m3u8 or dash).
    var isManifest = false

    /// What the row calls the site: YOUTUBE, VIMEO, DRIVE, DROPBOX, FILE, WEB, or the extractor's own name.
    var siteLabel: String {
        switch extractorKey {
        case nil, "": return "WEB"
        case "Youtube", "YoutubeTab": return "YOUTUBE"
        case "GoogleDrive": return "DRIVE"
        case "Generic": return isManifest ? "STREAM" : (isDirectFile ? "FILE" : "WEB")
        case let k?: return k.uppercased()
        }
    }

    /// Same video: the generic extractor's ids collide across sites, so the site is part of the key.
    var duplicateKey: String { "\(extractorKey ?? "")/\(id)" }

    struct Playlist: Equatable {
        var title: String
        var entries: [MediaInfo]
    }

    enum Parsed: Equatable {
        case single(MediaInfo)
        case playlist(Playlist)
    }

    enum ParseError: Error, LocalizedError {
        case notJSON, missingID
        var errorDescription: String? {
            switch self {
            case .notJSON: return "yt-dlp returned no JSON"
            case .missingID: return "yt-dlp JSON had no id"
            }
        }
    }

    /// `sourceURL` is what the person pasted: the fallback when yt-dlp gives no usable URL for an entry.
    static func parse(_ data: Data, sourceURL: String? = nil) throws -> Parsed {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ParseError.notJSON
        }
        if (obj["_type"] as? String) == "playlist" {
            let raw = obj["entries"] as? [[String: Any]] ?? []
            let parentKey = obj["extractor_key"] as? String
            let entries = try raw.compactMap { e -> MediaInfo? in
                guard e["id"] != nil else { return nil }
                return try entry(e, fallbackUploader: obj["uploader"] as? String, parentKey: parentKey, sourceURL: nil)
            }
            return .playlist(Playlist(title: obj["title"] as? String ?? "Playlist", entries: entries))
        }
        return .single(try entry(obj, fallbackUploader: nil, parentKey: nil, sourceURL: sourceURL))
    }

    private static func entry(_ e: [String: Any], fallbackUploader: String?, parentKey: String?, sourceURL: String?) throws -> MediaInfo {
        guard let id = e["id"] as? String else { throw ParseError.missingID }
        var thumb = e["thumbnail"] as? String
        if thumb == nil, let thumbs = e["thumbnails"] as? [[String: Any]] {
            thumb = thumbs.last?["url"] as? String
        }
        // A flat playlist entry names its extractor as `ie_key`; a full entry as `extractor_key`. A YouTube
        // tab's entries carry the video key even when the tab does not.
        let key = (e["extractor_key"] as? String) ?? (e["ie_key"] as? String) ?? parentKey
        var url = e["webpage_url"] as? String ?? e["url"] as? String ?? ""
        if url.isEmpty || !url.hasPrefix("http") {
            // Only a YouTube id can be rebuilt into a page; anything else keeps what was pasted.
            if key?.hasPrefix("Youtube") == true { url = "https://www.youtube.com/watch?v=\(id)" }
            else { url = sourceURL ?? url }
        }
        var maxH: Int? = nil
        var single: Bool? = nil
        var manifest = false
        if let formats = e["formats"] as? [[String: Any]] {
            maxH = formats.compactMap { $0["height"] as? Int }.max()
            func none(_ v: Any?) -> Bool { let s = v as? String; return s == nil || s == "none" }
            let videoOnly = formats.contains { !none($0["vcodec"]) && none($0["acodec"]) }
            single = !videoOnly
            let protocols = formats.compactMap { $0["protocol"] as? String }
            manifest = key == "Generic" && !protocols.isEmpty
                && protocols.allSatisfy { $0.hasPrefix("m3u8") || $0.hasPrefix("http_dash") || $0 == "dash" }
        }
        let dur: Double? = (e["duration"] as? Double) ?? (e["duration"] as? Int).map(Double.init)
        return MediaInfo(id: id,
                         title: e["title"] as? String ?? id,
                         url: url,
                         duration: dur,
                         thumbnail: thumb,
                         uploader: (e["uploader"] as? String) ?? (e["channel"] as? String) ?? fallbackUploader,
                         maxHeight: maxH,
                         extractorKey: key,
                         isDirectFile: (e["direct"] as? Bool) ?? false,
                         singleStream: single,
                         isManifest: manifest)
    }
}

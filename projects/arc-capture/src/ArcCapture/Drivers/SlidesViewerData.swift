//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation

/// Google Slides deck facts read out of the present-mode page itself
/// (`window.viewerData`) instead of the Slides API.
///
/// Why: the Slides/Drive API path needed an OAuth client holding
/// `drive.readonly`, a RESTRICTED scope. An unverified client asking for a
/// restricted scope is hard-blocked by Google at
/// `accounts.google.com/signin/oauth/warning` ("This app is blocked"), so
/// SIGN IN could never succeed on a crew laptop no matter which browser ran
/// it (measured in the field on laptop-04, 2026-09-15, in the operator's
/// ordinary extension-enabled Chrome). Present mode is already open in a
/// Chrome signed in as the house account for the capture itself, and it carries
/// everything the analysis needs — so the deck tells us about itself and
/// there is no token, no consent screen and no sign-in on a fresh Mac.
///
/// FIELD POSITIONS ARE MEASURED, NOT INFERRED (2026-09-15, three real decks,
/// every value cross-checked against the Slides/Drive API):
///
///   viewerData.slidePageCount  total slides, skipped ones INCLUDED
///                              (4 on a 4-slide deck with 2 skipped; 35; 5)
///   viewerData.title / .docId  deck title and id
///   viewerData.docData[1]      one row per slide, 15 fields each:
///     row[0]  String  slide objectId
///     row[1]  Int     0-based slide index
///     row[4]  Array   video records, empty when the slide has no video
///     row[7]  Array   [buildSteps, bool, delayMs] animation data
///     row[12] Int     1 = presentable, 0 = SKIPPED
///
///   video record fields used here:
///     v[0]  String  Drive file id, or the YouTube video id
///     v[1]  Int     1 = YouTube, 2 = Drive
///     v[4]  Int     1 = muted
///     v[5]  Int?    START trim in ms (null = none)
///     v[6]  Int?    END trim in ms (null = none)
///     v[8]  String  file name / video title
///     v[10] String  page element objectId
///
/// Video DURATION is deliberately absent here: it is not in viewerData. It
/// is read live off the slide by `GoogleSlidesDriver.liveVideoDuration()`
/// from the embed iframe's `length_seconds`, which matched Drive's
/// `durationMillis` exactly (5.769 s vs 5769 ms).
///
/// The TRIM, however, IS here and is NOT in the embed URL — measured on
/// a client deck's slide 18, a 34.625 s video the API reports as
/// `videoProperties.end = 30000`: the embed still advertises the full 34.625 s
/// and carries no start/end parameters, because Slides applies the trim inside
/// the player. So the length is read live and the trim is applied from here.
enum SlidesViewerData {
    /// Field offsets in a `docData[1]` slide row. Measured, see above.
    private enum Row {
        static let objectID = 0, index = 1, videos = 4, builds = 7, presentable = 12, imageMap = 13
        static let width = 15
    }
    /// Field offsets in a `row[4]` video record. Measured, see above.
    private enum Vid {
        static let videoID = 0, kind = 1, muted = 4, startMS = 5, endMS = 6, name = 8, elementID = 10
        /// `kind` values.
        static let youTube = 1, drive = 2
    }

    enum ParseError: LocalizedError {
        case missing(String)
        var errorDescription: String? {
            switch self {
            case .missing(let what): "Google Slides present page did not expose \(what)"
            }
        }
    }

    /// `window.viewerData` (the subset the driver asks for) -> deck facts.
    static func parse(_ v: [String: Any]) throws -> SlidesInfo {
        guard let rows = v["slides"] as? [[Any]] else { throw ParseError.missing("docData slide rows") }
        let id = v["docId"] as? String ?? ""
        let title = v["title"] as? String ?? ""

        var slides: [SlidesInfo.Slide] = []
        for (i, row) in rows.enumerated() {
            guard row.count >= Row.width else { throw ParseError.missing("a full slide row (got \(row.count) fields, expected \(Row.width))") }
            // Trust the row's own index when it is there; fall back to position.
            let index = (row[Row.index] as? Int ?? i) + 1
            let objectID = row[Row.objectID] as? String ?? ""
            // 1 = presentable, 0 = skipped. Anything unexpected counts as
            // presentable so an unknown value can never silently drop a slide.
            let skipped = (row[Row.presentable] as? Int) == 0

            var videos: [SlidesInfo.Video] = []
            for case let rec as [Any] in (row[Row.videos] as? [Any] ?? []) {
                func str(_ i: Int) -> String { rec.count > i ? (rec[i] as? String ?? "") : "" }
                func ms(_ i: Int) -> Double { rec.count > i ? ((rec[i] as? Double) ?? Double(rec[i] as? Int ?? 0)) / 1000 : 0 }
                // A Drive video is rendered by a youtube.googleapis.com embed
                // that advertises `length_seconds`; a real YouTube video gets a
                // www.youtube.com embed that does not. Only the first can be
                // measured, which is also true of the API path this replaces.
                let isDrive = (rec.count > Vid.kind ? rec[Vid.kind] as? Int : nil) != Vid.youTube
                videos.append(SlidesInfo.Video(source: isDrive ? "DRIVE" : "YOUTUBE",
                                               id: str(Vid.videoID), name: str(Vid.name),
                                               elementID: str(Vid.elementID),
                                               muted: (rec.count > Vid.muted ? rec[Vid.muted] as? Int : 0) == 1,
                                               start: ms(Vid.startMS), end: ms(Vid.endMS),
                                               autoPlay: false, seconds: nil))
            }
            // row[13] maps each picture element to the URL its bytes come
            // from. For an animated GIF that URL serves the real GIF, which is
            // the only way to learn its loop length without the Slides API.
            let images = (row[Row.imageMap] as? [String: Any])?.values.compactMap { $0 as? String } ?? []
            slides.append(SlidesInfo.Slide(index: index, objectId: objectID, skipped: skipped,
                                           buildSteps: buildSteps(row[Row.builds]),
                                           imageURLs: images.sorted(), videos: videos))
        }

        // slidePageCount counts skipped slides too, so it must agree with the
        // row count; if it ever does not, the rows are what we walk.
        if let count = v["slidePageCount"] as? Int, count != slides.count {
            DebugLog.log("Driver", "viewerData slidePageCount \(count) != \(slides.count) slide rows; using the rows")
        }
        return SlidesInfo(id: id, title: title, slides: slides)
    }

    /// row[7] is `[buildSteps, bool, delayMs]`; the first element's count is
    /// the number of click-driven animation steps on the slide (0 = none).
    private static func buildSteps(_ field: Any) -> Int {
        guard let a = field as? [Any], let first = a.first as? [Any] else { return 0 }
        return first.count
    }
}

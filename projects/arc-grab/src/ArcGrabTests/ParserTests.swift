//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import XCTest
@testable import ArcGrabTests

final class ParserTests: XCTestCase {
    func testDownloadProgressLine() {
        let p = ProgressParser.parseDownload("ARCP|downloading|64512|252182|NA|48974287.7|0")
        XCTAssertEqual(p?.status, "downloading")
        XCTAssertEqual(p?.downloaded, 64512)
        XCTAssertEqual(p?.total, 252182)
        XCTAssertEqual(p!.fraction!, 0.2558, accuracy: 0.001)
        XCTAssertEqual(p?.eta, 0)
        let est = ProgressParser.parseDownload("ARCP|downloading|10|NA|100|NA|NA")
        XCTAssertEqual(est?.total, 100)
        XCTAssertNil(est?.speed)
        XCTAssertNil(ProgressParser.parseDownload("[download] Destination: x"))
    }

    func testFinalPathAndError() {
        XCTAssertEqual(ProgressParser.parseFinalPath("ARCFILE|/a/b c.mkv"), "/a/b c.mkv")
        XCTAssertEqual(ProgressParser.parseError("ERROR: [youtube] x: Video unavailable"), "[youtube] x: Video unavailable")
        XCTAssertNil(ProgressParser.parseError("WARNING: x"))
    }

    func testFFmpegSeconds() {
        XCTAssertEqual(ProgressParser.parseFFmpegSeconds("out_time_us=1500000"), 1.5)
        XCTAssertNil(ProgressParser.parseFFmpegSeconds("frame=12"))
    }

    func testFormatters() {
        XCTAssertEqual(ProgressParser.formatBytesPerSec(12_400_000), "12.4 MB/s")
        XCTAssertEqual(ProgressParser.formatClock(75), "1:15")
        XCTAssertEqual(ProgressParser.formatClock(3661), "1:01:01")
    }

    func testMediaInfoSingle() throws {
        let json = """
        {"_type":"video","id":"abc","title":"T","duration":19,"thumbnail":"https://i/x.jpg","uploader":"jawed",
         "webpage_url":"https://www.youtube.com/watch?v=abc",
         "formats":[{"height":144},{"height":240,"vcodec":"av01"},{"height":null}]}
        """
        guard case .single(let m) = try MediaInfo.parse(Data(json.utf8)) else { return XCTFail() }
        XCTAssertEqual(m.id, "abc"); XCTAssertEqual(m.duration, 19); XCTAssertEqual(m.maxHeight, 240)
        XCTAssertEqual(m.uploader, "jawed")
    }

    func testMediaInfoPlaylist() throws {
        let json = """
        {"_type":"playlist","title":"PL","uploader":"ch","extractor_key":"YoutubeTab","entries":[
          {"id":"a","title":"A","url":"https://www.youtube.com/watch?v=a","duration":10,"thumbnails":[{"url":"https://i/a.jpg"}],"ie_key":"Youtube"},
          {"id":"b","title":"B","url":"b","ie_key":"Youtube"}]}
        """
        guard case .playlist(let p) = try MediaInfo.parse(Data(json.utf8)) else { return XCTFail() }
        XCTAssertEqual(p.entries.count, 2)
        XCTAssertEqual(p.entries[0].thumbnail, "https://i/a.jpg")
        XCTAssertEqual(p.entries[1].url, "https://www.youtube.com/watch?v=b")
        XCTAssertEqual(p.entries[1].uploader, "ch")
    }

    /// Real shapes: YouTube (DASH, video-only streams), Vimeo (progressive, every format carries audio), a
    /// direct file (Generic, `direct`), a Drive file, and a flat playlist whose entries carry `ie_key`.
    func testMediaInfoSites() throws {
        let yt = """
        {"_type":"video","id":"jNQXAC9IVRw","title":"Me at the zoo","extractor_key":"Youtube","webpage_url":"https://www.youtube.com/watch?v=jNQXAC9IVRw",
         "formats":[{"height":240,"vcodec":"av01","acodec":"none"},{"vcodec":"none","acodec":"opus"}]}
        """
        guard case .single(let y) = try MediaInfo.parse(Data(yt.utf8)) else { return XCTFail() }
        XCTAssertEqual(y.siteLabel, "YOUTUBE"); XCTAssertEqual(y.singleStream, false); XCTAssertEqual(y.duplicateKey, "Youtube/jNQXAC9IVRw")

        let vimeo = """
        {"_type":"video","id":"76979871","title":"Player","extractor_key":"Vimeo","webpage_url":"https://vimeo.com/76979871",
         "formats":[{"height":720,"vcodec":"avc1","acodec":"mp4a"},{"height":1080,"vcodec":"avc1","acodec":"mp4a"}]}
        """
        guard case .single(let v) = try MediaInfo.parse(Data(vimeo.utf8)) else { return XCTFail() }
        XCTAssertEqual(v.siteLabel, "VIMEO"); XCTAssertEqual(v.singleStream, true); XCTAssertEqual(v.maxHeight, 1080)

        let file = """
        {"_type":"video","id":"BigBuckBunny_320x180","title":"BigBuckBunny_320x180","extractor_key":"Generic","direct":true,
         "webpage_url":"https://x.org/BigBuckBunny_320x180.mp4","formats":[{"format_id":"0","vcodec":null,"acodec":null}]}
        """
        guard case .single(let f) = try MediaInfo.parse(Data(file.utf8)) else { return XCTFail() }
        XCTAssertEqual(f.siteLabel, "FILE"); XCTAssertEqual(f.singleStream, true)

        // No usable url and not YouTube: the pasted link is kept, never a youtube.com one.
        let drive = """
        {"_type":"video","id":"1AbC","title":"Reel.mov","extractor_key":"GoogleDrive","url":""}
        """
        guard case .single(let d) = try MediaInfo.parse(Data(drive.utf8), sourceURL: "https://drive.google.com/file/d/1AbC/view") else { return XCTFail() }
        XCTAssertEqual(d.siteLabel, "DRIVE"); XCTAssertEqual(d.url, "https://drive.google.com/file/d/1AbC/view"); XCTAssertNil(d.singleStream)
        XCTAssertNotEqual(d.duplicateKey, f.duplicateKey)

        let flat = """
        {"_type":"playlist","title":"Showcase","extractor_key":"VimeoShowcase","entries":[
          {"id":"1","title":"A","url":"https://vimeo.com/1","ie_key":"Vimeo"},
          {"id":"2","title":"B","url":"https://vimeo.com/2"}]}
        """
        guard case .playlist(let p) = try MediaInfo.parse(Data(flat.utf8)) else { return XCTFail() }
        XCTAssertEqual(p.entries[0].siteLabel, "VIMEO")
        XCTAssertEqual(p.entries[1].siteLabel, "VIMEOSHOWCASE")     // the parent's key, until the entry is analysed
    }

    func testProbeParse() {
        let json = """
        {"streams":[{"codec_type":"video","codec_name":"h264","width":320,"height":240},{"codec_type":"audio","codec_name":"aac"}],
         "format":{"duration":"19.0"}}
        """
        let r = ProbeResult.parse(Data(json.utf8))
        XCTAssertEqual(r.videoCodec, "h264"); XCTAssertEqual(r.audioCodec, "aac"); XCTAssertEqual(r.duration, 19)
    }
}

//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import XCTest
@testable import ArcGrabTests

/// Every input here is a line yt-dlp really printed (2026-09-17 probes, or earlier fleet reports).
final class ErrorMapperTests: XCTestCase {
    func testMeasuredFailures() {
        XCTAssertEqual(ErrorMapper.map("[vimeo] 76979871: The web client only works when logged-in. Use --cookies, --cookies-from-browser, --username and --password, --netrc-cmd, or --netrc (vimeo) to provide account credentials.").hint, .cookies)
        XCTAssertEqual(ErrorMapper.map("This format is DRM protected; Try selecting another format with --format or add --check-formats to automatically fallback to the next best format").hint, .drm)
        XCTAssertEqual(ErrorMapper.map("[vimeo] 56015672: No video formats found!; please report this issue on  https://github.com/yt-dlp/yt-dlp/issues?q= , filling out the appropriate issue template.").hint, .updateEngine)
        XCTAssertEqual(ErrorMapper.map("[generic] BigBuckBunny_320x180: Unable to download webpage: HTTP Error 403: Forbidden (caused by <HTTPError 403: Forbidden>)").hint, .updateEngine)
        XCTAssertEqual(ErrorMapper.map("[JWPlatform] kUKS4JHi: Unable to download JSON metadata: HTTP Error 404: Not Found (caused by <HTTPError 404: Not Found>)").hint, .removed)
        XCTAssertEqual(ErrorMapper.map("[youtube] x: Video unavailable").hint, .removed)
        // 2026-09-26: an engine without libmp3lame; "not found" must not read as a removed video.
        XCTAssertEqual(ErrorMapper.map("Postprocessing: audio conversion failed: Error opening output files: Encoder not found").hint, .updateApp)
        XCTAssertEqual(ErrorMapper.map("[youtube] x: Sign in to confirm you’re not a bot. Use --cookies-from-browser or --cookies for the authentication.").hint, .cookies)
        XCTAssertEqual(ErrorMapper.map("[vimeo] 1: This video is protected by a password, use the --video-password option").hint, .password)
        XCTAssertEqual(ErrorMapper.map("[vimeo] 1: The video is not available from this domain").hint, .referer)
        XCTAssertEqual(ErrorMapper.map("HTTP Error 429: Too Many Requests").hint, .rateLimited)
        XCTAssertEqual(ErrorMapper.map("Unsupported URL: https://events.client.com/session/12").hint, .badLink)
        XCTAssertEqual(ErrorMapper.map("[youtube] x: The uploader has not made this video available in your country").hint, .geo)
        XCTAssertEqual(ErrorMapper.map("[vimeo] 1084537: Unable to download webpage: HTTP Error 401: Unauthorized").hint, .cookies)
        XCTAssertNil(ErrorMapper.map("yt-dlp exited 1").hint)
    }

    func testRowLineIsShort() {
        let f = ErrorMapper.map("[vimeo] 56015672: No video formats found!; please report this issue on https://github.com/…")
        XCTAssertEqual(f.reason, "[vimeo] 56015672: No video formats found!")
        XCTAssertEqual(f.line, "[vimeo] 56015672: No video formats found! · TRY UPDATE ENGINE")
        XCTAssertEqual(ErrorMapper.firstSentence("ERROR: [generic] x: Unable to download webpage: HTTP Error 403: Forbidden (caused by <HTTPError 403: Forbidden>)"),
                       "[generic] x: Unable to download webpage: HTTP Error 403: Forbidden")
    }
}

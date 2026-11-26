//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation

/// The machine-readable verdict of one capture run. This is the headless
/// contract: `tools/capture_suite.py` reads it, the UI's complete screen
/// summarises it, and nothing else defines success.
struct CaptureReport: Codable {
    struct Slide: Codable {
        /// 1-based index in the captured sequence (and in slides.pdf).
        let index: Int
        /// PowerPoint's own slide number when it was asked, else nil.
        let pptxSlide: Int?
        let type: SlideType
        /// Relative path inside the .arcdeck for video slides.
        let file: String?
        /// Milliseconds from the advance to the settle that ended this slide.
        let settleMs: Int
        /// Changed frames seen while recording this slide.
        let motionFrames: Int
        /// Clip duration in seconds for video slides.
        let durationS: Double?
        /// How this slide ended: settled, timeout, duplicate, error.
        let endedBy: String
    }

    var version = 1
    var app: String = "ARC Capture"
    var appVersion: String
    var source: String
    var output: String?
    var ok: Bool
    var error: String?
    var startedAt: Date
    var finishedAt: Date?
    var analysis: PPTXAnalysis
    var expectedSlides: Int
    var slides: [Slide]
    var warnings: [String]
    /// V3: the deck verifier's verdict on the written deck (nil on a failed run).
    var verified: Bool? = nil
    var verifyDetail: String? = nil
    /// Did the run capture the whole deck? False for a STOP AND KEEP, which
    /// writes a verified deck of what was captured so far (V3, plan 1.5).
    /// `ok` can be true while this is false: the deck is sound, just short.
    var complete: Bool = true
    /// How the run ended: finished | stoppedByOperator | cancelled | error.
    var endedBy: String? = nil
    /// Milliseconds per phase: launch, findWindow, capture, assemble.
    var timingsMs: [String: Int]

    var slideCount: Int { slides.count }
    var videoSlideCount: Int { slides.filter { $0.type == .video }.count }
    var wallSeconds: Double { (finishedAt ?? Date()).timeIntervalSince(startedAt) }

    func write(to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(self).write(to: url)
    }
}

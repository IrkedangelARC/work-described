//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation

/// Abstracts slideshow automation for a presentation app. The session only
/// ever talks to this protocol, so a scripted driver can stand in for
/// PowerPoint in tests.
protocol PresentationDriver {
    var bundleIdentifier: String { get }
    var displayName: String { get }
    /// Substring of the show window's title (picker preference).
    var windowTitleHint: String { get }
    /// Points of window chrome above the slide (0 when the whole window is
    /// the slide, as in Keynote's in-window show; 28 for a titled window).
    var windowTitleBarHeight: CGFloat { get }

    /// Deck facts when the driver, not the PPTX analyzer, knows them
    /// (Google Slides). nil = analyse the file as PPTX.
    func analyze(_ url: URL) -> PPTXAnalysis?

    func openFile(_ url: URL) async throws
    func startSlideshow() async throws
    /// Start the show on `from` and end it after `to` (V3 changed-slides
    /// recapture). Drivers that cannot fall back to the whole show.
    var supportsRange: Bool { get }
    func startSlideshow(from: Int, to: Int) async throws
    func advanceSlide() async throws
    func stopSlideshow() async throws
    /// Close the presentation opened by `openFile` without saving, so the
    /// app is left with no stray document windows after a capture.
    func closeFile(_ url: URL) async throws

    /// Trigger the next click/animation event on the current slide without
    /// advancing to the next slide. Used for click-to-play videos. Needs the
    /// app frontmost (it is a keystroke); prefer `playCurrentSlideMedia`.
    func sendNextClick() async throws

    /// Start every movie on the slide the show is on, through the app's own
    /// scripting (no keystroke, no focus change). Returns the number of
    /// players started; 0 means the slide had no movie the app would play.
    func playCurrentSlideMedia() async throws -> Int

    /// Total slides in the open presentation.
    func slideCount() async throws -> Int
    /// The slide number the running slideshow is showing (1-based).
    func currentSlideNumber() async throws -> Int

    /// Length of the video on the slide the show is on, when the driver can
    /// read it live and the up-front analysis could not. nil = no live source;
    /// the session falls back to `analysis.slideDurations`.
    func liveVideoDuration(onSlide slide: Int) async -> TimeInterval?
}

extension PresentationDriver {
    var supportsRange: Bool { false }
    func startSlideshow(from: Int, to: Int) async throws { try await startSlideshow() }
    func analyze(_ url: URL) -> PPTXAnalysis? { nil }
    var windowTitleBarHeight: CGFloat { 28 }
    func liveVideoDuration(onSlide slide: Int) async -> TimeInterval? { nil }
}

enum DriverError: LocalizedError {
    case appleScriptFailed(String)
    case applicationNotFound(String)
    case slideshowNotRunning
    /// A deck's facts could not be read. Distinct from `appleScriptFailed`,
    /// which this used to be reported as: a Google Slides lookup failure
    /// surfaced to the operator as "AppleScript error: no Google Slides deck
    /// resolved", and a whole field debug went after the wrong cause
    /// (2026-09-15). Google Slides is driven over DevTools, not AppleScript.
    case lookupFailed(String)

    var errorDescription: String? {
        switch self {
        case .appleScriptFailed(let msg): "AppleScript error: \(msg)"
        case .applicationNotFound(let name): "\(name) is not installed"
        case .slideshowNotRunning: "No slideshow is currently running"
        case .lookupFailed(let msg): msg
        }
    }
}

/// osascript helpers shared by AppleScript-based drivers.
enum AppleScriptRunner {
    /// Run a script; returns trimmed stdout. Throws on a non-zero exit with stderr.
    @discardableResult
    static func run(_ script: String) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        // 20 s Apple event timeout: the default is 2 minutes, which is what
        // a "This file is still closing" dialog cost on 2026-09-11.
        p.arguments = ["-e", "with timeout of 20 seconds\n" + script + "\nend timeout"]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown error"
            throw DriverError.appleScriptFailed(msg)
        }
        return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import PDFKit
import ARCShowFormat
import AppKit
import AVFoundation
import ScreenCaptureKit
import CoreMedia

/// The capture state machine and nothing else: open, start the show, capture
/// every slide (recording each transition so animated slides become clips),
/// advance through build steps until PowerPoint's slide number moves, detect
/// the end, hand the slides to DeckWriter, and produce a CaptureReport.
///
/// Everything it talks to is injected (driver, frame source, recorder) so a
/// scripted driver and replayed frames can exercise it without PowerPoint.
/// `run()` awaits the whole thing and returns the report; the SwiftUI views
/// observe the same properties and call `beginCapture()` for the fire-and-
/// observe style.
@MainActor @Observable
final class CaptureSession {

    enum State: String {
        case idle, launching, findingWindow, capturing, recording, advancing, assembling, complete, error
    }

    // MARK: observed state
    var state: State = .idle
    var errorMessage: String?
    var slides: [CaptureResult] = []
    var currentSlideIndex: Int = 0
    var outputURL: URL?
    var report: CaptureReport?
    var expectedTotalSlides: Int = 0

    var slideCount: Int { slides.count }
    var videoSlideCount: Int { slides.filter(\.isVideo).count }
    var staticSlideCount: Int { slides.count - videoSlideCount }

    // MARK: configuration
    var sourceFile: URL?
    var outputDirectory: URL?
    /// Seconds after a settle before the next advance; complex slides finish drawing.
    var dwellTime: TimeInterval = 0.3
    /// Longest a non-video slide may record before it is cut and kept.
    var maxRecordingTime: TimeInterval = 30
    /// Also write the flat folder with PNGs for mixed decks.
    var keepPNGs = false
    /// Clips with fewer changed frames than this become stills.
    let minMotionFrames = 3
    /// A recording shorter than this is an instant (appear) build, not an
    /// animation worth a clip; keep the settled image instead. builds8c had
    /// 0.13-0.17 s clips on flat-transition decks.
    let minClipSeconds: Double = 0.3
    /// Build walk: a click is sent only once the previous build's animation
    /// has stopped producing frames for this long, up to maxBuildSeconds.
    let buildQuietMs = 600
    let maxBuildSeconds: TimeInterval = 8
    /// Build steps to walk before deciding PowerPoint will not move on.
    let maxBuildStepsPerSlide = 40
    /// Ceilings on the FIRST slide's settle, which had none at all: a movie
    /// that plays on entry and never stills (a music video) gave the gate no
    /// quiet stream to wait for and stopped the whole show run, 14 to 20
    /// minutes on four machines before a hand kill (ARC Test Show 02
    /// 2026-09-20, items 2.07 and 3.07; 1.06
    /// settled by luck). A movie the analyzer says starts on entry
    /// needs only long enough to tell a slow first draw from playback;
    /// anything else gets the longer ceiling, because the opening slide of a
    /// heavy deck can take seconds to appear.
    /// `var` so a test can shrink them and the field can raise them.
    var firstSettleMovieGrace: TimeInterval = 4
    var firstSettleCeiling: TimeInterval = 25

    // MARK: engine
    let frameCapture: any FrameSource
    var driver: any PresentationDriver
    let recorder: VideoRecorder

    /// The review's decisions for this item, handed to the splitter (docs/PLAN_review_queue.md).
    var splitOverrides: [ReviewOverride] = []
    /// Where ARC Grab's downloads of linked online videos are kept (the show folder's `state/grabs`); nil = beside the deck.
    var grabDirectory: URL?

    init(driver: any PresentationDriver, frameSource: any FrameSource, recorder: VideoRecorder) {
        self.driver = driver
        self.frameCapture = frameSource
        self.recorder = recorder
    }

    /// The production wiring: PowerPoint over AppleScript, ScreenCaptureKit, AVAssetWriter.
    convenience init() {
        self.init(driver: PowerPointDriver(), frameSource: FrameCapture(), recorder: VideoRecorder())
    }

    // MARK: private run state
    var slideshowWindow: CaptureTarget?
    var analysis = PPTXAnalysis.empty
    var previousFingerprint: [UInt8]?
    var duplicateSettleCount = 0
    var motionThumbnail: NSImage?
    var motionFrameCount = 0
    var totalAdvances = 0
    var maxAdvances = 300
    var recordingTimeoutTask: Task<Void, Never>?
    var advanceTimeoutTask: Task<Void, Never>?
    /// Ends the wait for the first slide's settle. The first settle cancels
    /// it, so on a deck that behaves it costs nothing.
    var firstSettleWatchdog: Task<Void, Never>?
    var advanceStartedAt = Date()
    var pptxSlideNow: Int?
    /// PowerPoint slide number of the last captured slide, to tell a real
    /// repeat from "moved, but not drawn yet".
    var lastCapturedPptx: Int?
    var redrawWaits = 0
    /// Consecutive image slides whose settled pixels equalled the previous
    /// slide although PowerPoint's position moved. Two in a row is what a
    /// capture attached to the wrong window looks like (builds8b).
    var frozenRun = 0
    var firstSlideVideoTried = false
    /// Wall time the current recording started, to place the movie click
    /// inside the clip (loopStart).
    var recordingStartedAt = Date()
    var movieClickAt: Date?
    /// Clip times of every click fired while the current clip records.
    var clickTimes: [Double] = []
    var entryClickIndex: Int?
    func noteClick() { clickTimes.append(recorder.clipTime() ?? 0) }

    // MARK: Logo pages and the last slide's builds

    /// Opening and closing logo pages (default on; never on a range recapture, which is merged into a deck that has them).
    var addBumpers = true
    /// A show's own art for them; nil = the ARC mark.
    var bumperImageURL: URL?
    private(set) var tail: Bumper.Tail?
    /// The last slide's builds are walked once, after it is captured and before the show ends.
    var lastSlideBuildsWalked = false
    /// Clicks that drew nothing and moved nothing (each is also a warning line): a red flag, counted.
    var noOpClicks = 0
    /// The deck's pages as written (logo pages included), for the report.
    private(set) var pages: [CaptureResult]?

    /// The show is over and the recorder holds what happened while LEAVING the
    /// last slide: its builds. It was cancelled here, so the last slide's
    /// builds never reached a deck. Kept for the closing page instead.
    func keepTailRecording() async {
        guard addBumpers, captureRange == nil, recorder.isRecording else { recorder.cancel(); return }
        var marks = clickTimes
        guard let url = try? await recorder.stopRecording() else { return }
        let k = analysis.clickCounts[pptxSlideNow ?? 0] ?? -1
        if k >= 0 {
            if marks.count > k + 1 { marks = Array(marks.prefix(k + 1)) }       // clicks after the show stopped moving are not builds
            if marks.count == k, k > 0 { marks.append(clipDuration(url) ?? (marks.last! + 1)) }   // no leaving click: the last build runs to the end
        }
        tail = Bumper.Tail(clip: url, clicks: marks)
        DebugLog.log("Session", "kept the recording made leaving the last slide: \(max(0, marks.count - 1)) build(s), marks \(marks.map { String(format: "%.2f", $0) }.joined(separator: ", "))")
    }
    /// A transition clip split off before the slide's own clicks, waiting
    /// for the slide to be finalised.
    var pendingEntry: (url: URL, clicks: [Double])?
    let audioMeter = AudioMeter()
    /// Set by the playback-stop rule for the slide being finalised.
    var stopAtForCurrent: Double?

    /// The transition into `slide` has settled: close the running clip as
    /// the slide's entry object and roll a fresh one for its own clicks.
    /// The picture is static at this instant, so the 40 ms gap is invisible.
    func splitEntryClip(for slide: Int) async {
        guard recorder.isRecording, let url = try? await recorder.stopRecording() else { return }
        let d = clipDuration(url) ?? 0
        pendingEntry = (url, clickTimes)
        CaptureMonitor.shared.transitionsCaptured += 1
        CaptureMonitor.shared.lastCaptured = "TRANSITION into slide \(slide), \(String(format: "%.1f", d)) s (own clip)"
        DebugLog.log("Session", "slide \(slide): TRANSITION captured as its own clip, \(String(format: "%.1f", d)) s, marks [\(clickTimes.map { String(format: "%.2f", $0) }.joined(separator: ", "))]; movie clip starts now")
        clickTimes = []; entryClickIndex = nil; recordingStartedAt = Date(); movieClickAt = nil
        let next = FileManager.default.temporaryDirectory.appendingPathComponent("slide_\(slide)_\(UUID().uuidString).mov")
        do { try recorder.startRecording(to: next, width: frameCapture.capturePixelWidth, height: frameCapture.capturePixelHeight) } catch {
            warnings.append("slide \(slide): recording could not restart after the transition: \(error.localizedDescription)")
        }
    }
    /// How long after an advance an unchanged frame is treated as "not drawn
    /// yet" rather than a genuinely identical slide. Measured 2026-09-11: real
    /// redraws land within ~1.5 s; duplicate slides in 1.04 cost 26 s each
    /// under a count-based wait.
    let redrawGrace: TimeInterval = 4.5
    /// Highest visible slide number; the show ends there, hidden slides are skipped.
    var lastVisibleSlide = 0
    /// PowerPoint's slide count including hidden ones; a show position above
    /// it is the "end of slide show" black screen, not a slide.
    var totalSlideCount = 0
    /// Set when PowerPoint has already left the show (end screen or an advance
    /// error), so finish does not try to exit a show that is gone.
    var showEnded = false
    var warnings: [String] = []
    /// The operator pressed STOP AND KEEP: the deck is written from what was
    /// captured and marked incomplete (V3, plan 1.5).
    private(set) var stoppedByOperator = false
    var timings: [String: Int] = [:]
    var startedAt = Date()
    var phaseStart = Date()
    var completion: CheckedContinuation<CaptureReport, Error>?
    var finishing = false

    // MARK: - Run (awaitable)

    /// Run one capture end to end and return its report. Throws if the run
    /// failed; the report is also kept in `report` either way.
    func run() async throws -> CaptureReport {
        try await withCheckedThrowingContinuation { cont in
            self.completion = cont
            Task { await self.beginCapture() }
        }
    }

    // MARK: - Begin

    /// Screen Recording (ScreenCaptureKit) and Accessibility (System Events
    /// moves the show window and posts clicks). Prompts the system once per
    /// app version for each; returns a message naming what is still missing.
    static func missingPermissions() async -> String? {
        var missing: [String] = []
        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
            try? await Task.sleep(for: .milliseconds(300))
            if !CGPreflightScreenCaptureAccess() { missing.append("Screen & System Audio Recording") }
        }
        if !AXIsProcessTrusted() {
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
            let key = "accessibilityPromptedFor"
            if UserDefaults.standard.string(forKey: key) != version {
                UserDefaults.standard.set(version, forKey: key)
                _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
            }
            missing.append("Accessibility")
        }
        guard !missing.isEmpty else { return nil }
        var text = "ARC Capture needs " + missing.joined(separator: " and ") + " in System Settings, Privacy & Security. Switch it on for ARC Capture, then TRY AGAIN."
        // Screen Recording is attributed to the RESPONSIBLE process. A binary
        // exec'd from a shell (ssh, Terminal) has that shell's session as its
        // responsible process, and no grant on the app can satisfy the check
        // (2026-09-18: three grants, three failures, until `open -a`). launchd
        // is pid 1; anything else as parent means a shell started us.
        if missing.contains("Screen & System Audio Recording"), getppid() != 1 {
            text += " This run was started from a shell, so macOS charges Screen Recording to the shell's session, not to ARC Capture: launch it with  open -n -a \"ARC Capture\" --args --headless …  instead."
        }
        return text
    }

    /// V3 changed-slides recapture: capture only these pptx slides (the show
    /// starts on the lower bound and ends after the upper). nil = the whole show.
    var captureRange: ClosedRange<Int>?

    // MARK: - Checkpoint and resume (V3, plan 1.1/1.2)

    /// Every finished slide, written to `<name>.arcdeck.partial` as it is
    /// captured. Also what lets a slide let go of its 2x bitmap.
    var checkpoint: CaptureCheckpoint?
    /// Pick up a crashed run instead of starting over, when a partial for
    /// this source is on disk.
    var resumeRequested = false
    /// The show position the resumed run started on; nil for a fresh run.
    private(set) var resumedFromPptx: Int?
    /// Slides already in hand when this run started (0, or the restored
    /// count on a resume). The first-slide-movie rule keys off it.
    var slidesAtRunStart = 0
    /// The deck's name, fixed once the analysis is in so the partial and the
    /// finished deck agree on it.
    var deckBaseName = "Captured"
    /// Where the deck (and the partial beside it) is written.
    var resolvedOutputDir: URL { outputDirectory ?? sourceFile?.deletingLastPathComponent() ?? FileManager.default.temporaryDirectory }

    /// Is there a run to pick up for this source? The setup screen asks
    /// before a capture starts; nil when there is nothing to resume.
    func resumable() -> (url: URL, progress: CaptureCheckpoint.Progress)? {
        guard let sourceFile else { return nil }
        return CaptureCheckpoint.findResumable(source: sourceFile, baseName: nil, in: resolvedOutputDir)
    }

    func beginCapture() async {
        guard let sourceFile else { fail("No file selected."); return }
        // A .key deck gets the Keynote driver whatever the session was built with.
        if sourceFile.pathExtension.lowercased() == "key", !(driver is KeynoteDriver) { driver = KeynoteDriver() }
        if sourceFile.scheme?.hasPrefix("http") == true, !(driver is GoogleSlidesDriver) { driver = GoogleSlidesDriver() }
        if sourceFile.pathExtension.lowercased() == "pdf" { await importPDF(sourceFile); return }
        slides = []; currentSlideIndex = 0; totalAdvances = 0; outputURL = nil; report = nil
        checkpoint = nil; resumedFromPptx = nil; slidesAtRunStart = 0; stoppedByOperator = false
        previousFingerprint = nil; duplicateSettleCount = 0; motionThumbnail = nil; motionFrameCount = 0
        warnings = []; timings = [:]; finishing = false; lastSlideBuildsWalked = false; noOpClicks = 0; pptxSlideNow = nil; lastCapturedPptx = nil; redrawWaits = 0; frozenRun = 0; showEnded = false; firstSlideVideoTried = false
        startedAt = Date(); phaseStart = startedAt
        state = .launching
        DebugLog.log("Session", "begin: \(sourceFile.lastPathComponent)")

        let mon = CaptureMonitor.shared
        mon.reset(); mon.phase = "checking permissions"
        // The app launched on its own is its own TCC client: the headless
        // runs from a terminal borrowed the terminal's grants, so the GUI's
        // first run failed with "declined TCCs" and an unmoved show window
        // (2026-09-12). Ask once, then stop with a plain message.
        // Real screen capture only: a scripted frame source (tests) needs no grants.
        if frameCapture is FrameCapture, let missing = await Self.missingPermissions() { fail(missing); return }
        // Backstop for the launch pass: the Apple Event consent this deck's app and System Events need, asked for
        // before the show opens rather than by the driver's first command (a declined launch prompt, a new app).
        if frameCapture is FrameCapture, !(driver is GoogleSlidesDriver) {
            for t in [AutomationPermission.systemEvents] + AutomationPermission.all.filter({ $0.id == driver.bundleIdentifier }) {
                guard AutomationPermission.current(t) != .granted else { continue }
                mon.phase = "asking to control \(t.name)"
                if await AutomationPermission.request(t) == .denied {
                    fail("ARC Capture is not allowed to control \(t.name). System Settings > Privacy & Security > Automation > ARC Capture: switch on \(t.name), then TRY AGAIN."); return
                }
            }
        }
        mon.phase = "analysing deck"
        analysis = driver.analyze(sourceFile) ?? PPTXAnalyzer.analyze(sourceFile)
        // A deck with media and no ffprobe is NOT captured. Without the probe the movie slides are unknown:
        // a 40 s movie came out as a 31 s timeout clip and the run still said ok and verified (2026-11-25,
        // public build with ffmpeg taken away). The fleet build bundles both; the public build asks for them.
        if analysis.warnings.contains(where: { $0.hasPrefix("ffprobe not found") }) {
            fail("This deck holds movies or sound and ffmpeg and ffprobe were not found. Install your own (Homebrew: brew install ffmpeg), check the FFMPEG row in READY?, then TRY AGAIN."); return
        }
        mon.hiddenSlides = analysis.hiddenSlides.count; mon.movieSlides = analysis.videoSlides.count
        mon.loopSlides = analysis.loopingSlides.count; mon.autoAdvanceSlides = analysis.autoAdvanceSlides.count
        mon.phase = "opening presentation"
        warnings.append(contentsOf: analysis.warnings.map { "analysis: \($0)" })
        deckBaseName = analysis.title.map { $0.replacingOccurrences(of: "/", with: "-") }
            ?? sourceFile.deletingPathExtension().lastPathComponent

        // Pick up a crashed run before the show opens: the slides already on
        // disk come back as they were and the show starts after the last one.
        var resumeAt: Int? = nil
        if resumeRequested, !driver.supportsRange {
            warnings.append("\(driver.displayName) cannot start a show on a chosen slide, so a run cannot be resumed; captured from the start")
            DebugLog.log("Session", "resume asked for but \(driver.displayName) has no starting slide")
        } else if resumeRequested, let found = CaptureCheckpoint.findResumable(source: sourceFile, baseName: deckBaseName, in: resolvedOutputDir),
           let restored = CaptureCheckpoint.restore(from: found.url) {
            slides = restored.slides
            currentSlideIndex = restored.slides.map(\.id).max() ?? restored.slides.count
            slidesAtRunStart = slides.count
            lastCapturedPptx = restored.slides.compactMap(\.pptxSlide).max()
            deckBaseName = restored.progress.baseName
            if let last = lastCapturedPptx { resumeAt = last + 1; resumedFromPptx = resumeAt }
            warnings.append("resumed from \(slides.count) slide(s) already captured; the show restarts on slide \(resumeAt.map(String.init) ?? "1")")
            DebugLog.log("Session", "resume: \(slides.count) slide(s) restored from \(found.url.lastPathComponent), restarting on \(resumeAt.map(String.init) ?? "1")")
        } else if resumeRequested, driver.supportsRange {
            warnings.append("nothing to resume for this deck; captured from the start")
            DebugLog.log("Session", "resume asked for but no matching partial; starting over")
        }
        do {
            checkpoint = try CaptureCheckpoint(baseName: deckBaseName, in: resolvedOutputDir, source: sourceFile,
                                               resuming: resumeAt != nil,
                                               app: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
                                               host: Host.current().localizedName,
                                               system: ProcessInfo.processInfo.operatingSystemVersionString)
        } catch {
            // Not fatal: the run works the old way, holding every slide in
            // memory, and says so.
            warnings.append("no per-slide checkpoint (\(error.localizedDescription)): a crash would lose this run")
            DebugLog.log("Session", "checkpoint unavailable: \(error.localizedDescription)")
        }
        DebugLog.log("Session", "analysis: \(analysis.slideCount) slides, video on \(analysis.videoSlides.sorted()), durations \(analysis.slideDurations)")

        do {
            try await driver.openFile(sourceFile)
            let total = (try? await driver.slideCount()) ?? analysis.slideCount
            totalSlideCount = total
            // Hidden slides are skipped by the show: expect the visible ones.
            expectedTotalSlides = max(0, total - analysis.hiddenSlides.count)
            mon.totalSlides = expectedTotalSlides
            lastVisibleSlide = (1...max(total, 1)).filter { !analysis.hiddenSlides.contains($0) }.last ?? total
            if !analysis.hiddenSlides.isEmpty { warnings.append("\(analysis.hiddenSlides.count) hidden slide(s) skipped: \(analysis.hiddenSlides.sorted())") }
            if let range = captureRange, driver.supportsRange {
                let lo = max(1, range.lowerBound), hi = min(max(total, 1), range.upperBound)
                // The show ends after `hi`: PowerPoint reports hi+1 (its end screen).
                totalSlideCount = hi
                lastVisibleSlide = (lo...max(hi, lo)).filter { !analysis.hiddenSlides.contains($0) }.last ?? hi
                expectedTotalSlides = (lo...max(hi, lo)).filter { !analysis.hiddenSlides.contains($0) }.count
                mon.totalSlides = expectedTotalSlides
                DebugLog.log("Session", "range capture: slides \(lo)...\(hi) of \(total)")
            } else if captureRange != nil {
                warnings.append("this driver cannot start on a slide; the whole show is captured")
            }
            maxAdvances = expectedTotalSlides > 0 ? expectedTotalSlides * maxBuildStepsPerSlide : 600
            mon.phase = "starting slide show"
            if let range = captureRange, driver.supportsRange {
                try await driver.startSlideshow(from: max(1, range.lowerBound), to: min(max(total, 1), range.upperBound))
            } else if var at = resumeAt {
                // A run that died after the last slide but before the deck
                // was written has nothing left to capture. Give the last
                // slide back and capture it again, so the show has a slide
                // to open on and the walk ends where it always does.
                if at > max(total, 1), let last = slides.last {
                    slides.removeLast()
                    currentSlideIndex = slides.map(\.id).max() ?? 0
                    slidesAtRunStart = slides.count
                    at = last.pptxSlide ?? max(total, 1)
                    resumedFromPptx = at
                    resumeAt = at          // the position check below compares against this
                    DebugLog.log("Session", "resume landed past the last slide; recapturing slide \(at)")
                }
                try await driver.startSlideshow(from: max(1, min(at, max(total, 1))), to: 0)
            } else {
                try await driver.startSlideshow()
            }
            mark("launch")
            mon.phase = "finding the show window"

            state = .findingWindow
            let window = try await frameCapture.findSlideshowWindow(bundleIdentifier: driver.bundleIdentifier, titleHint: driver.windowTitleHint)
            slideshowWindow = window
            DebugLog.log("Session", "window \(Int(window.frame.width))x\(Int(window.frame.height))")
            frameCapture.titleBarHeight = driver.windowTitleBarHeight
            try await frameCapture.startCapture(
                target: window,
                onSettled: { [weak self] image in Task { @MainActor in self?.handleSettled(image) } },
                onMotionFrame: { [weak self] pb, ts in Task { @MainActor in self?.handleMotionFrame(pb, ts) } }
            )
            // Audio goes straight to the recorder on the capture queue; the
            // recorder drops samples until the clip's first frame.
            let rec = recorder
            let meter = audioMeter
            frameCapture.onAudio = { sb in rec.appendAudio(sb); meter.note(sb) }
            mark("findWindow")
            pptxSlideNow = try? await driver.currentSlideNumber()

            // Did the show actually open where it was told to? PowerPoint
            // 16.113 accepts `starting slide`, reads it back, and then opens
            // on slide 1 anyway (measured on the mini, 2026-09-18), so a
            // resume that trusted the driver spliced a second copy of the
            // whole deck onto the restored pages. Check the position; when it
            // is not the one asked for, give the restored slides up and
            // capture the deck from the start rather than write a wrong deck.
            if let want = resumeAt, let now = pptxSlideNow, now != want {
                warnings.append("\(driver.displayName) opened the show on slide \(now), not \(want): the run could not be resumed and the whole deck was captured again")
                DebugLog.log("Session", "resume failed: asked for slide \(want), the show opened on \(now); starting over")
                slides = []; currentSlideIndex = 0; slidesAtRunStart = 0
                resumedFromPptx = nil; lastCapturedPptx = nil
                // A fresh partial: the restored ids would collide with the ones
                // this run is about to write.
                checkpoint = try? CaptureCheckpoint(baseName: deckBaseName, in: resolvedOutputDir, source: sourceFile,
                                                    resuming: false,
                                                    app: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
                                                    host: Host.current().localizedName,
                                                    system: ProcessInfo.processInfo.operatingSystemVersionString)
            } else if let range = captureRange, driver.supportsRange, let now = pptxSlideNow, now != max(1, range.lowerBound) {
                // The same driver limit, on the changed-slides recapture path.
                warnings.append("\(driver.displayName) opened the show on slide \(now), not \(max(1, range.lowerBound)): this deck is NOT the requested range")
                DebugLog.log("Session", "range capture: asked for slide \(max(1, range.lowerBound)), the show opened on \(now)")
            }
            mon.pptxSlide = pptxSlideNow ?? 0; mon.phase = "waiting for the first slide to settle"
            advanceStartedAt = Date()
            state = .capturing
            DebugLog.log("Session", "capturing \(frameCapture.capturePixelWidth)x\(frameCapture.capturePixelHeight), waiting for first settle")
            armFirstSettleWatchdog()
        } catch {
            fail(error.localizedDescription)
        }
    }

    // MARK: - Finish

    /// A PDF needs no show: every page becomes a still slide and the deck is
    /// written straight away (2026-09-12: "add PDF to the drag and drop").
    func importPDF(_ url: URL) async {
        slides = []; warnings = []; startedAt = Date(); state = .capturing
        CaptureMonitor.shared.reset(); CaptureMonitor.shared.phase = "reading PDF pages"
        guard let doc = PDFDocument(url: url), doc.pageCount > 0 else { fail("Could not read the PDF."); return }
        expectedTotalSlides = doc.pageCount; CaptureMonitor.shared.totalSlides = doc.pageCount
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let box = page.bounds(for: .cropBox)
            let w: CGFloat = 1920, h = (w * box.height / max(box.width, 1)).rounded()
            let image = page.thumbnail(of: NSSize(width: w, height: h), for: .cropBox)
            slides.append(CaptureResult(id: i + 1, pptxSlide: i + 1, slideType: .image, image: image, videoURL: nil, capturedAt: Date(), settleMs: 0, motionFrames: 0, endedBy: "pdf"))
            CaptureMonitor.shared.pptxSlide = i + 1
        }
        state = .assembling; CaptureMonitor.shared.phase = "writing the deck"
        let outputDir = outputDirectory ?? url.deletingLastPathComponent()
        do {
            deckBaseName = url.deletingPathExtension().lastPathComponent
            let out = try DeckWriter.write(slides: slides, baseName: deckBaseName, into: outputDir, keepPNGs: keepPNGs)
            outputURL = out.deckURL
            // COMPLETE means VERIFIED here too. This path wrote the deck and
            // declared success without ever opening it (V3, plan 1.4).
            CaptureMonitor.shared.phase = "verifying the deck"
            guard let verdict = await verifiedDeck(at: out.deckURL, expectedPages: slides.count) else { return }
            lastVerdict = verdict
            let rep = makeReport(ok: true, error: nil, clipFiles: out.clipFiles)
            report = rep; state = .complete; CaptureMonitor.shared.phase = "complete"
            DebugLog.log("Session", "complete (PDF, \(slides.count) pages): \(out.deckURL.path)")
            completion?.resume(returning: rep); completion = nil
        } catch { fail(error.localizedDescription) }
    }

    /// Operator's STOP AND KEEP: end the show now and write what has been
    /// captured as a real, verified deck marked incomplete (V3, plan 1.5).
    ///
    /// The difference from CANCEL is the whole point: CANCEL keeps nothing.
    /// This is for the moment the room needs to move on and a deck of the
    /// first 30 slides is worth far more than no deck at all.
    func stopAndKeep() async {
        guard !finishing else { return }
        guard !slides.isEmpty else {
            DebugLog.log("Session", "STOP AND KEEP with nothing captured yet; cancelling instead")
            await cancelCapture(); return
        }
        stoppedByOperator = true
        warnings.append("the operator ended the show at slide \(slides.count) of \(expectedTotalSlides > 0 ? String(expectedTotalSlides) : "?"); this deck is what had been captured")
        DebugLog.log("Session", "STOP AND KEEP at \(slides.count) slide(s)")
        CaptureMonitor.shared.phase = "stopping and keeping what was captured"
        await finishCapture()
    }

    /// Operator's CANCEL: stop everything, keep nothing, back to the setup.
    func cancelCapture() async {
        finishing = true
        advanceTimeoutTask?.cancel(); recordingTimeoutTask?.cancel(); firstSettleWatchdog?.cancel(); stallWatcher?.cancel(); loopSettleTask?.cancel(); autoAdvanceWatcher?.cancel()
        recorder.cancel()
        await frameCapture.stopCapture()
        try? await driver.stopSlideshow()
        await closeSourceDocument()
        DebugLog.log("Session", "cancelled by the operator")
        completion?.resume(returning: makeReport(ok: false, error: "cancelled", clipFiles: [:])); completion = nil
        reset()
    }

    /// What the deck was made from, by what, where and when: it travels in the manifest.
    private func deckInfo(size: CGSize) -> DeckManifest.DeckInfo {
        var d = DeckManifest.DeckInfo()
        if let src = sourceFile {
            d.sourceName = src.lastPathComponent; d.sourceKind = src.pathExtension.lowercased()
            let attrs = try? FileManager.default.attributesOfItem(atPath: src.path)
            d.sourceBytes = attrs?[.size] as? Int; d.sourceModified = attrs?[.modificationDate] as? Date
            d.sourceHash = SlideHasher.fileHash(src)
        }
        d.sourceSlideCount = analysis.slideCount > 0 ? analysis.slideCount : nil
        d.sourceHiddenSlides = analysis.hiddenSlides.isEmpty ? nil : analysis.hiddenSlides.sorted()
        d.title = analysis.title
        d.capturedAt = Date()
        d.captureApp = "ARC Capture"
        d.captureVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        d.host = Host.current().localizedName
        d.system = ProcessInfo.processInfo.operatingSystemVersionString
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: driver.bundleIdentifier) {
            d.presentationApp = "\(driver.displayName) \(Bundle(url: app)?.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")"
        }
        d.pixelWidth = Int(size.width); d.pixelHeight = Int(size.height)
        d.complete = stoppedByOperator ? false : nil
        d.warnings = warnings.isEmpty ? nil : warnings
        return d
    }

    /// Slides whose deck entry has fewer builds than the source has build clicks.
    nonisolated static func buildShortfalls(manifest: DeckManifest, sourceBuilds: [Int: Int]) -> [String] {
        manifest.slides.compactMap { s in
            guard s.role == nil, let n = s.pptxSlide, let want = sourceBuilds[n], want > 0 else { return nil }
            let got = s.builds?.count ?? 0
            return got < want ? "slide \(n): the source has \(want) build\(want == 1 ? "" : "s"), the deck has \(got); it would stay \(got == 0 ? "bare" : "part built")" : nil
        }
    }

    /// Slides the deck shows (not hidden, inside the captured range) that have
    /// no captured page. Empty when the driver reports no slide numbers or the
    /// analyzer knows no count: nothing can be claimed then.
    /// The longest own timer (advTm, seconds) the walk waits out instead of clicking.
    nonisolated static let ownTimerWaitLimit: TimeInterval = 15

    nonisolated static func missingSlides(slideCount: Int, hidden: Set<Int>, range: ClosedRange<Int>?, captured: [Int]) -> [Int] {
        guard slideCount > 0, !captured.isEmpty else { return [] }
        let have = Set(captured)
        return (range ?? 1...slideCount).filter { $0 <= slideCount && !hidden.contains($0) && !have.contains($0) }
    }

    /// Verify a freshly written deck and, on top of what the shared verifier
    /// checks, hold it to the page count this run intended. `DeckVerifier`
    /// only catches a manifest that names MORE slides than the PDF has pages;
    /// a PDF with spare pages, or one page short, passes it (V3, plan 1.4).
    ///
    /// Returns nil once `fail` has been called, so callers `guard let` and
    /// return.
    func verifiedDeck(at deck: URL, expectedPages: Int) async -> DeckVerdict? {
        let verdict = await DeckVerifier.verify(arcdeck: deck)
        mark("verify")
        DebugLog.log("Session", "verify: \(verdict.ok ? "OK" : "FAILED") \(verdict.detail)")
        warnings.append(contentsOf: verdict.warnings.map { "verify: \($0)" })
        guard verdict.ok else {
            lastVerdict = verdict
            fail("deck failed verification: \(verdict.detail)")
            return nil
        }
        if expectedPages > 0, verdict.pages != expectedPages {
            lastVerdict = verdict
            fail("the deck has \(verdict.pages) page\(verdict.pages == 1 ? "" : "s") where this run captured \(expectedPages)")
            return nil
        }
        if let m = DeckManifest.load(from: deck.appendingPathComponent("manifest.json")).manifest,
           m.slides.count != verdict.pages {
            lastVerdict = verdict
            fail("the manifest describes \(m.slides.count) slide(s) but slides.pdf has \(verdict.pages) page(s)")
            return nil
        }
        return verdict
    }

    func finishCapture() async {
        guard !finishing else { return }
        finishing = true
        advanceTimeoutTask?.cancel(); advanceTimeoutTask = nil
        recordingTimeoutTask?.cancel(); recordingTimeoutTask = nil
        firstSettleWatchdog?.cancel(); firstSettleWatchdog = nil
        if recorder.isRecording { _ = try? await recorder.stopRecording() }
        await frameCapture.stopCapture()
        if !showEnded {
            do { try await driver.stopSlideshow() } catch { warnings.append("stopSlideshow: \(error.localizedDescription)") }
        }
        await closeSourceDocument()
        mark("capture")

        DebugLog.log("Session", "captured \(slides.count) slides (\(staticSlideCount) image, \(videoSlideCount) video)")
        guard !slides.isEmpty else { fail("No slides were captured."); return }
        if !stoppedByOperator, expectedTotalSlides > 0, slides.count != expectedTotalSlides {
            warnings.append("captured \(slides.count) slides, PowerPoint reports \(expectedTotalSlides)")
        }

        state = .assembling
        CaptureMonitor.shared.phase = "writing the deck"
        let outputDir = resolvedOutputDir
        let baseName = deckBaseName
        do {
            let wrapped = addBumpers && captureRange == nil
            let size = CGSize(width: frameCapture.capturePixelWidth > 0 ? frameCapture.capturePixelWidth : 1920, height: frameCapture.capturePixelHeight > 0 ? frameCapture.capturePixelHeight : 1080)
            let deckPages = wrapped ? Bumper.wrap(slides: slides, tail: tail, logo: Bumper.image(size: size, custom: bumperImageURL)) : slides
            pages = deckPages
            let out = try DeckWriter.write(slides: deckPages, baseName: baseName, into: outputDir, keepPNGs: keepPNGs, analysis: analysis, info: deckInfo(size: size))
            outputURL = out.deckURL
            if let src = sourceFile {
                let n = DeckNotes.write(source: src, into: out.deckURL)
                if n > 0 { DebugLog.log("Session", "speaker notes: \(n) page(s)") }
            }
            mark("assemble")
            // One clip per build, a still per state (manifest version 3), by
            // itself: it was a manual --split-builds step. Also drops what is
            // left of the closing page's clip once the last slide has its builds.
            CaptureMonitor.shared.phase = "splitting the builds"
            let split = outputDir.appendingPathComponent(".\(baseName).split-\(UUID().uuidString).arcdeck")
            do {
                // The slides the warnings name keep their recording for the review (a build the deck has, a click that
                // changed nothing, a movie that stopped or never started, slides passed).
                let flagged = Set(warnings.compactMap { w -> Int? in
                    guard w.hasPrefix("slide "), ["the source has", "changed nothing", "playback stopped", "never started", "not captured", "ended by"].contains(where: w.contains) else { return nil }
                    return w.dropFirst(6).split(whereSeparator: { !$0.isNumber }).first.flatMap { Int($0) }
                })
                if !flagged.isEmpty { DebugLog.log("Split", "recordings kept for review: slides \(flagged.sorted().map(String.init).joined(separator: ", "))") }
                let sum = try await BuildSplitter.convert(deck: out.deckURL, into: split, pptx: sourceFile, overrides: splitOverrides, keepRecordingsFor: flagged,
                                                          grabDir: grabDirectory ?? outputDir.appendingPathComponent("grabs")) { DebugLog.log("Split", $0) }
                try FileManager.default.removeItem(at: out.deckURL)
                try FileManager.default.moveItem(at: split, to: out.deckURL)
                DebugLog.log("Session", "builds: \(sum.slidesWithBuilds) slide(s), \(sum.builds) clip(s), \(sum.stills) still(s)" + (sum.sourceMovies > 0 ? ", \(sum.sourceMovies) source movie(s) in place of recordings" : "") + (sum.onlineVideos > 0 ? ", \(sum.onlineVideos) online video(s) fetched by ARC Grab" : ""))
                for (n, why) in sum.onlineVideosFailed.sorted(by: { $0.key < $1.key }) { warnings.append("slide \(n): the online video it links to was not fetched: \(why)") }
            } catch {
                try? FileManager.default.removeItem(at: split)
                warnings.append("builds were not split (the deck plays as continuous clips): \(error.localizedDescription)")
            }
            // COMPLETE does not yet mean "every build": say so when the deck
            // holds fewer than the source, where the room would see a slide
            // stay bare. A warning, raised by the preflight: the source's
            // click count is a reading of its XML, not a certainty.
            if let m = DeckManifest.load(from: out.deckURL.appendingPathComponent("manifest.json")).manifest {
                let source = analysis.clickCounts.merging(analysis.mediaClicks) { all, media in max(0, all - media) }
                // A range capture keeps no recording of leaving its last slide, so that slide's builds are never
                // walked here: no shortfall is claimed for it (the merge takes the page from the old version).
                let runOut = captureRange.map { $0.upperBound }
                warnings.append(contentsOf: Self.buildShortfalls(manifest: m, sourceBuilds: source).filter { w in
                    guard let runOut, let n = w.split(whereSeparator: { !$0.isNumber }).first.flatMap({ Int($0) }) else { return true }
                    return n != runOut
                })
            }
            mark("split")
            // COMPLETE means VERIFIED (V3): the PDF opens, the manifest parses,
            // every clip exists and plays. A deck that fails stays on disk and
            // the run is an error that names the reason.
            CaptureMonitor.shared.phase = "verifying the deck"
            guard let verdict = await verifiedDeck(at: out.deckURL, expectedPages: deckPages.count) else { return }
            lastVerdict = verdict
            // COMPLETE also means EVERY slide the deck shows has a page. The
            // verifier checks structure, not coverage: 3.01 came out "ready"
            // with 18 pages of 19 after the show moved on by itself between
            // two of our clicks and slide 16 was passed (2026-09-17).
            // A deck the operator cut short is MEANT to be missing slides; the
            // manifest says so and the report says so. Only a run that claimed
            // to finish has to account for every slide.
            let unpaged = stoppedByOperator ? [] :
                Self.missingSlides(slideCount: analysis.slideCount, hidden: analysis.hiddenSlides, range: captureRange,
                                   captured: slides.compactMap(\.pptxSlide))
            // A slide set to advance AT ONCE (advTm 0) that the show passed without stopping is the deck's own
            // doing, and no second capture changes it (1.01 slide 5 failed three runs in a row, 2026-11-25): it
            // is inside the clip into the next slide. Said plainly in the report, not called a failed capture.
            let passed = unpaged.filter { analysis.autoAdvanceSlides[$0] == 0 }
            for n in passed {
                let line = "slide \(n) is set to advance at once (0 s) and the show passed it without stopping: it has no page of its own and is seen inside the clip into the next slide; if it should hold, give it a time in the deck"
                DebugLog.log("Session", line); warnings.append(line)
            }
            let missing = unpaged.filter { !passed.contains($0) }
            guard missing.isEmpty else {
                fail("slide\(missing.count == 1 ? "" : "s") \(missing.map(String.init).joined(separator: ", ")) shown by the deck but not captured (the show moved on its own; capture it again)")
                return
            }
            // Verified and complete: the partial has nothing left to protect.
            checkpoint?.discard(); checkpoint = nil
            let rep = makeReport(ok: true, error: nil, clipFiles: out.clipFiles)
            report = rep
            state = .complete
            CaptureMonitor.shared.phase = "complete"
            DebugLog.log("Session", "complete: \(out.deckURL.path) in \(String(format: "%.1f", rep.wallSeconds)) s")
            completion?.resume(returning: rep); completion = nil
        } catch {
            fail(error.localizedDescription)
        }
    }

    func reset() {
        recordingTimeoutTask?.cancel(); recordingTimeoutTask = nil
        advanceTimeoutTask?.cancel(); advanceTimeoutTask = nil
        firstSettleWatchdog?.cancel(); firstSettleWatchdog = nil
        Task { await frameCapture.stopCapture() }
        recorder.cancel()
        slides = []; currentSlideIndex = 0; totalAdvances = 0; outputURL = nil; sourceFile = nil
        errorMessage = nil; previousFingerprint = nil; duplicateSettleCount = 0
        motionThumbnail = nil; motionFrameCount = 0; report = nil; finishing = false
        // The handle goes; the .partial directory stays. A run that ended any
        // way but verified-complete is a run someone may want to pick up.
        checkpoint = nil; resumedFromPptx = nil; slidesAtRunStart = 0; resumeRequested = false
        state = .idle
    }

    // MARK: - Status for the views

    var statusText: String {
        switch state {
        case .idle: return "Ready"
        case .launching: return "Opening presentation..."
        case .findingWindow: return "Finding slideshow window..."
        case .capturing: return slides.isEmpty ? "Waiting for first slide..." :
            (expectedTotalSlides > 0 ? "Captured \(slides.count) of \(expectedTotalSlides) slides" : "\(slides.count) slide(s) captured")
        case .recording: return "Recording slide \(currentSlideIndex + 1)..."
        case .advancing: return "Advancing to next slide..."
        case .assembling: return "Assembling output..."
        case .complete: return videoSlideCount > 0 ? "Complete: \(staticSlideCount) images, \(videoSlideCount) videos" : "Capture complete: \(slides.count) slides"
        case .error: return errorMessage ?? "An error occurred"
        }
    }

    var progress: Double {
        guard expectedTotalSlides > 0 else { return 0 }
        return min(1.0, Double(slides.count) / Double(expectedTotalSlides))
    }

    // MARK: - Walk and movie state (used by the CaptureSession+ files)
    var autoAdvanceWatcher: Task<Void, Never>?
    var stallWatcher: Task<Void, Never>?
    var loopSettleTask: Task<Void, Never>?
    let movieStallSeconds: TimeInterval = 6
    var clicksWalkedFor: Int?

    // MARK: - Report / errors

    func mark(_ phase: String) {
        timings[phase] = Int(Date().timeIntervalSince(phaseStart) * 1000)
        phaseStart = Date()
    }

    /// The verifier's verdict on the written deck (V3), for the report.
    var lastVerdict: DeckVerdict?

    func makeReport(ok: Bool, error: String?, clipFiles: [Int: String]) -> CaptureReport {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let repSlides = (pages ?? slides).map { s in
            CaptureReport.Slide(index: s.id, pptxSlide: s.pptxSlide, type: s.slideType, file: clipFiles[s.id],
                                settleMs: s.settleMs, motionFrames: s.motionFrames,
                                durationS: s.isVideo ? clipDuration(s.videoURL) : nil, endedBy: s.endedBy)
        }
        var rep = CaptureReport(appVersion: version, source: sourceFile?.path ?? "", output: outputURL?.path, ok: ok, error: error,
                                startedAt: startedAt, finishedAt: Date(), analysis: analysis, expectedSlides: expectedTotalSlides,
                                slides: repSlides, warnings: warnings, timingsMs: timings)
        rep.verified = lastVerdict?.ok
        rep.verifyDetail = lastVerdict?.detail
        rep.complete = !stoppedByOperator
        rep.endedBy = error != nil ? (error == "cancelled" ? "cancelled" : "error")
                                   : (stoppedByOperator ? "stoppedByOperator" : "finished")
        if let from = resumedFromPptx { rep.warnings.append("resumed run: the show restarted on slide \(from)") }
        return rep
    }

    func clipDuration(_ url: URL?) -> Double? {
        guard let url else { return nil }
        let asset = AVURLAsset(url: url)
        let d = asset.duration
        return d.isNumeric ? d.seconds : nil
    }

    /// Leave no presentation window behind (2026-09-11: "close preso
    /// windows when done with them"). Errors are only logged: the deck is
    /// already captured by the time this runs.
    func closeSourceDocument() async {
        guard let sourceFile else { return }
        do { try await driver.closeFile(sourceFile) } catch {
            DebugLog.log("Session", "closeFile: \(error.localizedDescription)")
        }
    }

    func fail(_ message: String) {
        DebugLog.log("Session", "ERROR: \(message)")
        errorMessage = message
        state = .error
        Task { await frameCapture.stopCapture(); await self.closeSourceDocument() }
        recorder.cancel()
        let rep = makeReport(ok: false, error: message, clipFiles: [:])
        report = rep
        completion?.resume(throwing: CaptureFailure(message: message, report: rep)); completion = nil
    }
}

struct CaptureFailure: LocalizedError {
    let message: String
    let report: CaptureReport
    var errorDescription: String? { message }
}

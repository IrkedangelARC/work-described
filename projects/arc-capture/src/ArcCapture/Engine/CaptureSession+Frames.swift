//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import AppKit
import AVFoundation
import ScreenCaptureKit
import CoreMedia
import PDFKit

// Frame events: settle, motion, clip finalisation, slide results. Split from CaptureSession 2026-09-12 (V2 refactor).
extension CaptureSession {
    // MARK: - Frame events

    func handleSettled(_ image: NSImage) {
        guard !finishing else { return }
        advanceTimeoutTask?.cancel(); advanceTimeoutTask = nil
        firstSettleWatchdog?.cancel(); firstSettleWatchdog = nil
        let fingerprint = frameCapture.lastSettledFingerprint
        let settleMs = Int(Date().timeIntervalSince(advanceStartedAt) * 1000)

        if recorder.isRecording {
            Task { await finalizeRecording(settledImage: image, fingerprint: fingerprint, settleMs: settleMs) }
            return
        }
        // Not recording: the first slide, or a repeat after an advance that produced nothing.
        if FrameAnalysis.isDuplicateSlide(previousFingerprint, fingerprint) {
            duplicateSettleCount += 1
            DebugLog.log("Session", "duplicate settle #\(duplicateSettleCount)")
            if duplicateSettleCount >= 3 { Task { await finishCapture() }; return }
            state = .advancing
            Task { await autoAdvance() }
            return
        }
        duplicateSettleCount = 0
        if slides.count == slidesAtRunStart, let first = pptxSlideNow, analysis.videoSlides.contains(first), !firstSlideVideoTried {
            // The opening slide carries a movie: the walk in autoAdvance never
            // runs for slide 1, so play and record it here (1.08 in builds8c
            // came out as a still).
            firstSlideVideoTried = true
            Task { await recordFirstSlideVideo(first) }
            return
        }
        appendSlide(type: .image, image: image, clip: nil, settleMs: settleMs, endedBy: "settled")
        previousFingerprint = fingerprint
        afterSlide()
    }

    /// The first slide never settles.
    ///
    /// `handleSettled` is the ONLY place a movie on the opening slide is
    /// noticed, so a movie that plays on entry and never stills is never
    /// noticed at all: the gate waits for a quiet stream a music video will
    /// not give it, and that wait had no ceiling. One slide stopped a whole
    /// show run (ARC Test Show 02, 2026-09-20: 2.07 and 3.07, 14 to 20
    /// minutes on four machines before a hand kill).
    ///
    /// Armed once the show is up and cancelled by the first settle.
    func armFirstSettleWatchdog() {
        firstSettleWatchdog?.cancel()
        let entry = pptxSlideNow
        let hasMovie = entry.map { analysis.videoSlides.contains($0) } ?? false
        // The analyzer read `mediaStartsOnEntry` out of the slide's XML. When
        // it says the movie plays by itself there is nothing to wait for, so
        // the grace only has to outlast a slow first draw.
        let playsOnEntry = entry.map { analysis.autoPlaySlides.contains($0) } ?? false
        let ceiling = (hasMovie && playsOnEntry) ? firstSettleMovieGrace : firstSettleCeiling
        firstSettleWatchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(ceiling))
            guard let self, !Task.isCancelled, !self.finishing, self.state == .capturing else { return }
            // Nothing captured in this run and no clip rolling: the gate
            // really is still waiting. A settle that landed in the meantime
            // has already changed one of these.
            guard self.slides.count == self.slidesAtRunStart, !self.recorder.isRecording else { return }
            // A movie explains it, so hand over to the movie path, which
            // records rather than waiting for stillness. Keying on
            // `videoSlides` rather than `autoPlaySlides` covers the slide
            // whose XML could not answer (`mediaStartUnknown`): a wrong
            // autoplay guess then costs the grace, not the run.
            if let first = entry, hasMovie, !self.firstSlideVideoTried {
                self.firstSlideVideoTried = true
                self.warnings.append("slide \(first): the opening movie was still playing after \(Int(ceiling)) s; it was recorded instead of waited out")
                DebugLog.log("Session", "first settle: slide \(first) carries a movie and the stream has not stilled after \(Int(ceiling)) s; going to the movie path")
                await self.recordFirstSlideVideo(first)
                return
            }
            // Nothing explains it. Keep the live frame as the first page and
            // let the walk go on: a deck with one suspect page beats a run
            // that never ends. The page is flagged so REVIEW picks it up.
            if let img = self.frameCapture.latestFrame {
                self.warnings.append("the first slide never settled within \(Int(ceiling)) s; the live frame was kept and the walk went on")
                DebugLog.log("Session", "first settle: nothing settled in \(Int(ceiling)) s; keeping the live frame")
                self.appendSlide(type: .image, image: img, clip: nil, settleMs: Int(ceiling * 1000), endedBy: "first-settle timeout")
                self.afterSlide()
            } else {
                self.fail("The first slide never settled within \(Int(ceiling)) s and the capture stream produced no frame.")
            }
        }
    }

    func handleMotionFrame(_ pixelBuffer: CVPixelBuffer, _ timestamp: CMTime) {
        guard recorder.isRecording else { return }
        recorder.appendFrame(pixelBuffer, timestamp: timestamp)
        if frameCapture.isLatestFrameChanged { motionFrameCount += 1 }
    }

    func finalizeRecording(settledImage: NSImage, fingerprint: [UInt8]?, settleMs: Int) async {
        loopSettleTask?.cancel(); loopSettleTask = nil
        stallWatcher?.cancel(); stallWatcher = nil
        // The slide number moved but the pixels still match the previous
        // slide: PowerPoint has not redrawn yet (heavy slides take 1-3 s).
        // Keep recording and re-arm the settle instead of calling it a repeat;
        // the old code ended the show here after three of these.
        if FrameAnalysis.isDuplicateSlide(previousFingerprint, fingerprint),
           let now = pptxSlideNow, now != lastCapturedPptx, !analysis.videoSlides.contains(now),
           Date().timeIntervalSince(advanceStartedAt) < redrawGrace {
            redrawWaits += 1
            DebugLog.log("Session", "settled on the previous slide's pixels after moving to \(now); waiting for redraw (\(redrawWaits))")
            frameCapture.resetSettleKeepMotion()
            return
        }
        if redrawWaits > 0, FrameAnalysis.isDuplicateSlide(previousFingerprint, fingerprint) {
            DebugLog.log("Session", "slide \(pptxSlideNow ?? 0) is pixel-identical to the previous slide; keeping it")
            frozenRun += 1
            if frozenRun == 2 {
                warnings.append("slides \(currentSlideIndex) and \(currentSlideIndex + 1) settled on the previous slide's pixels after the show moved: the capture may be attached to the wrong window or the slide show window may be off screen")
                DebugLog.log("Session", "WARNING: two consecutive frozen slides")
                // Diagnostic: which PowerPoint windows exist right now.
                let wins = (try? AppleScriptRunner.run("""
                    tell application "System Events" to tell process "Microsoft PowerPoint" to get {name, position, size} of every window
                    """)) ?? "?"
                DebugLog.log("Session", "PowerPoint windows: \(wins)")
                // Recovery: re-attach the stream. The return value says whether
                // the screen had moved on without the stream (stale stream).
                let stale = await frameCapture.restartStream()
                warnings.append("capture stream restarted after two frozen slides (screen-vs-stream diff \(stale.map { String(format: "%.3f", $0) } ?? "n/a"))")
                frozenRun = 0
            }
        } else if motionFrameCount > 0 || !FrameAnalysis.isDuplicateSlide(previousFingerprint, fingerprint) {
            frozenRun = 0
        }
        recordingTimeoutTask?.cancel(); recordingTimeoutTask = nil
        var hadMotion = motionFrameCount >= minMotionFrames
        var clipURL: URL? = nil
        let dropped = recorder.droppedFrames
        do { clipURL = try await recorder.stopRecording() } catch {
            warnings.append("slide \(currentSlideIndex + 1): recorder stop failed: \(error.localizedDescription)")
        }
        // A known movie slide keeps its clip whatever the motion count: a
        // talking head on white barely crosses the per-frame change threshold
        // (one deck's slide 44, another's 23/33/43 came out as stills, 2026-09-11).
        if !hadMotion, let now = pptxSlideNow, analysis.videoSlides.contains(now), let c = clipURL,
           let d = clipDuration(c), d >= minClipSeconds {
            DebugLog.log("Session", "slide \(now): movie slide with little pixel motion (\(motionFrameCount) frames); keeping the \(String(format: "%.1f", d)) s clip")
            hadMotion = true
        }
        // A recording that holds BUILD CLICKS is kept whatever the motion count: the previous slide's
        // builds live in it, and a single Appear of a picture (1.03 slide 20) or a thin red outline
        // (slide 23) changes fewer than `minMotionFrames` frames, so the page came out a still, the
        // clip went, and the builds with it (found 2026-09-19). The splitter tells a cut from an
        // animation; the session's job is to keep what the clicks did.
        if !hadMotion, clickTimes.count >= 2, let c = clipURL, let d = clipDuration(c), d >= minClipSeconds {
            DebugLog.log("Session", "slide \(currentSlideIndex + 1): little pixel motion (\(motionFrameCount) frames) but \(clickTimes.count - 1) build click(s) in the recording; keeping the \(String(format: "%.1f", d)) s clip")
            hadMotion = true
        }
        if hadMotion, let c = clipURL, let d = clipDuration(c), d < minClipSeconds {
            DebugLog.log("Session", "clip of \(String(format: "%.2f", d)) s is an instant build; keeping the image")
            hadMotion = false
        }
        if dropped > 0 { warnings.append("slide \(currentSlideIndex + 1): encoder dropped \(dropped) frame(s)") }

        if FrameAnalysis.isDuplicateSlide(previousFingerprint, fingerprint), pptxSlideNow == lastCapturedPptx {
            duplicateSettleCount += 1
            DebugLog.log("Session", "duplicate settle #\(duplicateSettleCount) after recording (no move)")
            if let c = clipURL { try? FileManager.default.removeItem(at: c) }
            if duplicateSettleCount >= 3 { await finishCapture(); return }
            motionThumbnail = nil; motionFrameCount = 0
            state = .advancing
            await autoAdvance()
            return
        }
        duplicateSettleCount = 0
        if hadMotion, let c = clipURL {
            // The page for a movie slide is its SETTLED state, not the frame
            // the recording began on (that was the previous slide's last
            // frame, so the filmstrip showed two identical thumbnails for
            // slides 1 and 2; 2026-09-12). Presenter plays the clip
            // on the output; the page is what the filmstrip and NEXT show.
            appendSlide(type: .video, image: settledImage, clip: c, settleMs: settleMs, endedBy: "settled")
            // After a long movie the window stream goes stale (Sample Deck 45-48
            // after the 198 s movie on 44; another deck after slide 7): the next
            // slides settle on the movie's last frame until a restart. Restart
            // right away instead of waiting for two frozen slides.
            if let d = clipDuration(c), d >= 20 {
                DebugLog.log("Session", "long movie (\(Int(d)) s) finished: restarting the capture stream")
                _ = await frameCapture.restartStream()
            }
        } else {
            if let c = clipURL { try? FileManager.default.removeItem(at: c) }
            appendSlide(type: .image, image: settledImage, clip: nil, settleMs: settleMs, endedBy: "settled")
        }
        previousFingerprint = fingerprint
        afterSlide()
    }

    /// The per-slide recording timeout fired: keep what we have and move on.
    func forceStopRecordingOnTimeout() async {
        recordingTimeoutTask = nil
        guard !finishing else { return }
        var clipURL: URL? = nil
        if recorder.isRecording { clipURL = try? await recorder.stopRecording() }
        let settleMs = Int(Date().timeIntervalSince(advanceStartedAt) * 1000)
        guard let image = motionThumbnail ?? frameCapture.latestFrame else {
            // No frame at all: nothing to keep. The old code stored an empty
            // NSImage here and silently lost a PDF page.
            warnings.append("slide \(currentSlideIndex + 1): timeout with no frame, skipped")
            if let c = clipURL { try? FileManager.default.removeItem(at: c) }
            afterSlide(); return
        }
        if let c = clipURL, FileManager.default.fileExists(atPath: c.path) {
            appendSlide(type: .video, image: image, clip: c, settleMs: settleMs, endedBy: "timeout")
        } else {
            appendSlide(type: .image, image: image, clip: nil, settleMs: settleMs, endedBy: "timeout")
        }
        previousFingerprint = frameCapture.lastSettledFingerprint
        afterSlide()
    }

    func appendSlide(type: SlideType, image: NSImage, clip: URL?, settleMs: Int, endedBy: String) {
        currentSlideIndex += 1
        var r = CaptureResult(id: currentSlideIndex, pptxSlide: pptxSlideNow, slideType: type, image: image,
                              videoURL: clip, capturedAt: Date(), settleMs: settleMs, motionFrames: motionFrameCount, endedBy: endedBy)
        if type == .video, let now = pptxSlideNow, !analysis.videoSlides.contains(now), (analysis.clickCounts[now] ?? 0) == 0 {
            r.transition = true
        }
        // A loop flag belongs to a media slide's clip only; a bare transition
        // clip flagged loop replayed its way in every 9 s (1.25 slide 15,
        // the MP3 the analyzer had missed, 2026-09-12).
        if type == .video, let now = pptxSlideNow, analysis.loopingSlides.contains(now), analysis.videoSlides.contains(now), !r.transition {
            r.loop = true
            if let t = movieClickAt { r.loopStart = max(0, t.timeIntervalSince(recordingStartedAt) + 0.3) }
        }
        if type == .video { r.clicks = clickTimes; r.entryClick = entryClickIndex; r.stopAt = stopAtForCurrent }
        if let now = pptxSlideNow, analysis.transitionSlides.contains(now) { r.transitionIn = true }
        if let now = pptxSlideNow, let adv = analysis.autoAdvanceSlides[now] { r.autoAdvance = adv }
        stopAtForCurrent = nil
        if let pe = pendingEntry {
            if type == .video { r.entryClipURL = pe.url; r.entryClicks = pe.clicks }
            else { try? FileManager.default.removeItem(at: pe.url) }
            pendingEntry = nil
        }
        // Say plainly what was written: a transition clip, a movie clip with
        // its click markers, or a still (2026-09-12: "explicitly note
        // when transitions are captured").
        let mon0 = CaptureMonitor.shared
        let n = pptxSlideNow.map(String.init) ?? "?"
        if r.transition {
            let d = clip.flatMap { clipDuration($0) } ?? 0
            mon0.transitionsCaptured += 1
            mon0.lastCaptured = "TRANSITION into slide \(n), \(String(format: "%.1f", d)) s"
            DebugLog.log("Session", "slide \(n): TRANSITION captured, \(String(format: "%.1f", d)) s clip, the way into the slide (no movie, no clicks)")
        } else if type == .video {
            let d = clip.flatMap { clipDuration($0) } ?? 0
            let marks = r.clicks.map { String(format: "%.2f", $0) }.joined(separator: ", ")
            let own = r.entryClick.map { r.clicks.count - $0 - 1 } ?? r.clicks.count
            let entry = r.entryClick.map { "entry click at \(String(format: "%.2f", r.clicks[$0])) s" } ?? "no entry click"
            mon0.lastCaptured = "MOVIE slide \(n), \(String(format: "%.1f", d)) s, \(own) click(s) after entry" + (r.loop ? ", loops" : "")
            DebugLog.log("Session", "slide \(n): MOVIE clip \(String(format: "%.1f", d)) s, \(entry), \(own) own click(s), click marks [\(marks)]" + (r.loop ? ", loops from \(String(format: "%.2f", r.loopStart ?? 0)) s" : ""))
        } else {
            mon0.lastCaptured = "STILL slide \(n)"
        }
        movieClickAt = nil
        clickTimes = []; entryClickIndex = nil
        // Write the slide before it is counted: the page goes to the partial
        // deck at PDF size, the clip is moved out of /tmp, and the 2x bitmap
        // is released. A crash from here on costs the slide in flight and
        // nothing else (V3, plan 1.1).
        if let cp = checkpoint {
            do { r = try cp.append(r) } catch {
                warnings.append("slide \(r.id): not checkpointed (\(error.localizedDescription))")
                DebugLog.log("Session", "checkpoint failed for slide \(r.id): \(error.localizedDescription)")
            }
        }
        slides.append(r)
        lastCapturedPptx = pptxSlideNow
        CaptureMonitor.shared.recording = false; CaptureMonitor.shared.holdRemaining = 0
        CaptureMonitor.shared.warnings = warnings
        DebugLog.log("Session", "slide \(r.id) (pptx \(pptxSlideNow.map(String.init) ?? "?")) \(type.rawValue) \(endedBy) settle=\(settleMs)ms motion=\(motionFrameCount)")
        motionThumbnail = nil
        motionFrameCount = 0
    }

    func afterSlide() {
        if totalAdvances >= maxAdvances { warnings.append("advance budget exhausted"); Task { await finishCapture() }; return }
        if lastVisibleSlide > 0, let now = pptxSlideNow, now >= lastVisibleSlide {
            // The LAST slide's builds. The capture finished right here, so they
            // were never walked, in any version: a deck that ended on a build
            // slide showed it bare for ever (3.04, ten builds, 0 captured,
            // 2026-09-17). With a closing page to record them against, walk
            // them first; the walk ends when the show stops moving.
            let owed = clicksWalkedFor == now ? 0 : max(0, (analysis.clickCounts[now] ?? 0) - (analysis.mediaClicks[now] ?? 0))
            if addBumpers, captureRange == nil, owed > 0, !lastSlideBuildsWalked {
                lastSlideBuildsWalked = true
                DebugLog.log("Session", "last visible slide captured (\(now)); walking its \(owed) build(s) before the show ends")
                state = .advancing
                Task { await autoAdvance() }
                return
            }
            DebugLog.log("Session", "last visible slide captured (\(now), \(slides.count)/\(expectedTotalSlides))")
            Task { await finishCapture() }; return
        }
        state = .advancing
        Task { await autoAdvance() }
    }
}

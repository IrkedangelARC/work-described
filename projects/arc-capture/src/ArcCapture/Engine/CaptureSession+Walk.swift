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

// The click walk: leave a slide, poll the position, first-slide movie, auto-advance. Split from CaptureSession 2026-09-12 (V2 refactor).
extension CaptureSession {
    /// Slide 1 with an embedded movie: start the recorder, trigger the
    /// movie, and let the normal settle/timeout path finish it.
    func recordFirstSlideVideo(_ slide: Int) async {
        state = .capturing
        let clipURL = FileManager.default.temporaryDirectory.appendingPathComponent("slide_\(slide)_\(UUID().uuidString).mov")
        do { try recorder.startRecording(to: clipURL, width: frameCapture.capturePixelWidth, height: frameCapture.capturePixelHeight) } catch {
            warnings.append("slide 1: recording could not start: \(error.localizedDescription)")
            if let img = frameCapture.latestFrame { appendSlide(type: .image, image: img, clip: nil, settleMs: 0, endedBy: "settled") }
            afterSlide(); return
        }
        motionFrameCount = 0; motionThumbnail = nil
        clickTimes = []; entryClickIndex = nil
        advanceStartedAt = Date()
        await triggerVideo(on: slide)
    }
    /// After a build click: let the animation start, then wait until the
    /// stream has been quiet for `buildQuietMs`. Capped so a looping build
    /// cannot stall the walk.
    func waitForAnimationEnd(step: Int, of expected: Int) async {
        let started = Date()
        try? await Task.sleep(for: .milliseconds(400))            // PowerPoint starts a build late
        let quietFrames = buildQuietMs * 30 / 1000
        while Date().timeIntervalSince(started) < maxBuildSeconds {
            if let age = frameCapture.lastFrameAge, age * 1000 >= Double(buildQuietMs) { break }
            if frameCapture.identicalFrameRun >= quietFrames { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        let took = Date().timeIntervalSince(started)
        if took >= maxBuildSeconds { DebugLog.log("Session", "build \(step)\(expected > 0 ? " of \(expected)" : ""): still moving after \(Int(maxBuildSeconds)) s, clicking on") }
    }
    /// An automatic-advance slide leaves on its own; when the show position
    /// changes, settle immediately so the slide is finalised and the next
    /// walk starts from the live position without clicking.
    func watchAutoAdvance(from slide: Int, after seconds: TimeInterval) {
        autoAdvanceWatcher?.cancel()
        DebugLog.log("Session", "slide \(slide): advances automatically (\(seconds) s); watching the position")
        autoAdvanceWatcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, !self.finishing else { return }
                let pos = (try? await self.driver.currentSlideNumber()) ?? 0
                if pos != 0 && pos != slide {
                    DebugLog.log("Session", "slide \(slide) advanced by itself to \(pos)")
                    self.frameCapture.settleNow()
                    return
                }
            }
        }
    }
    func autoAdvance() async {
        try? await Task.sleep(for: .milliseconds(Int(dwellTime * 1000)))
        guard !finishing, state == .capturing || state == .advancing, slideshowWindow != nil else { return }

        autoAdvanceWatcher?.cancel(); autoAdvanceWatcher = nil
        stallWatcher?.cancel(); stallWatcher = nil
        loopSettleTask?.cancel(); loopSettleTask = nil
        var before = pptxSlideNow ?? 0
        if before == 0 { before = (try? await driver.currentSlideNumber()) ?? 0 }
        // The show may have moved on by itself (automatic advance): then no
        // click is owed, the slide we are on is the one to capture.
        let live = (try? await driver.currentSlideNumber()) ?? 0
        let alreadyMoved = live != 0 && live != before && before != 0
        if alreadyMoved { DebugLog.log("Session", "show advanced by itself from \(before) to \(live); no click") }
        let clipURL = FileManager.default.temporaryDirectory.appendingPathComponent("slide_\(before + 1)_\(UUID().uuidString).mov")
        state = .recording
        motionThumbnail = frameCapture.latestFrame
        motionFrameCount = 0
        recordingStartedAt = Date(); movieClickAt = nil
        clickTimes = []; entryClickIndex = nil; pendingEntry = nil
        CaptureMonitor.shared.recording = true; CaptureMonitor.shared.clicksDone = 0
        CaptureMonitor.shared.clicksExpected = analysis.clickCounts[before] ?? -1
        CaptureMonitor.shared.phase = (analysis.clickCounts[before] ?? 0) > 0
            ? "walking \(analysis.clickCounts[before] ?? 0) build(s) of slide \(before), then the transition into \(before + 1)"
            : "recording the transition from slide \(before) into \(before + 1)"
        do {
            try recorder.startRecording(to: clipURL, width: frameCapture.capturePixelWidth, height: frameCapture.capturePixelHeight)
        } catch {
            // Never hang in .capturing: report and carry on without a clip.
            warnings.append("slide \(before + 1): recording start failed: \(error.localizedDescription)")
        }
        frameCapture.forceMotionMode()
        advanceStartedAt = Date()

        // Walk build steps until PowerPoint's slide number moves. Each `go to
        // next slide` is one click; a slide with N builds takes N+1. The
        // recorder is rolling, so the builds land in the clip. After every
        // click the walk waits for the animation to END (the frame stream
        // goes quiet) before the next one; clicking 150 ms apart made the
        // builds overlap and cut each other short (2026-09-11 13:50).
        let expectedClicks = clicksWalkedFor == before ? 0 : (analysis.clickCounts[before] ?? -1)
        clicksWalkedFor = nil
        // No settle may fire while the walk is in progress: one did, and a
        // second walk started on top of the first (30/29 on one deck).
        // Released explicitly after the walk: a `defer` here ran AFTER the
        // video hold was set and wiped it (slide 7 clip 10 s instead of 226 s).
        frameCapture.holdSettle(seconds: 600)
        var moved = alreadyMoved
        if alreadyMoved { pptxSlideNow = live; redrawWaits = 0; before = live - 1 }
        var steps = 0
        // A click that draws NOTHING and moves nothing is never a normal result (2026-09-19: "a click
        // will affect something, a build or a transition; any click that does nothing is a big red flag").
        // The frame count before each click is kept and read once the next animation wait is over.
        var pendingNoOp: (click: Int, changedBefore: Int, picture: [UInt8]?)? = nil
        while !moved && steps < maxBuildStepsPerSlide {
            if expectedClicks < 0 || steps <= expectedClicks {
                // Also before the FIRST click: the entry transition must be over.
                await waitForAnimationEnd(step: steps, of: expectedClicks)
            }
            if let p = pendingNoOp, let was = p.picture, let now = frameCapture.currentFingerprint {
                // Net of the click: the same picture as before it (a single glitch frame does not count).
                let net = FrameAnalysis.difference(was, now)
                let frames = frameCapture.changedFrameCount - p.changedBefore
                DebugLog.log("Session", "slide \(before) click \(p.click): \(frames) frame(s) changed since the click, picture differs by \(String(format: "%.4f", net))")
                // The fingerprint is coarse (two thin red boxes read 0.0005): only a FLAT reading is called out
                // here; the exact verdict is the splitter's, from the stills before and after the click.
                if net < 0.0001 {
                    let line = "slide \(before) click \(p.click): changed nothing on screen (the click landed, the show stayed put and the picture is the same as before it as far as the capture can tell: a dropped click, or a build that draws nothing here)"
                    DebugLog.log("Session", "ERROR " + line)
                    warnings.append(line)
                    noOpClicks += 1
                }
            }
            // The show may have moved while the walk waited for the picture to go quiet: then no click is owed.
            if steps > 0 || analysis.autoAdvanceSlides[before] != nil {
                let live2 = (try? await driver.currentSlideNumber()) ?? 0
                if live2 != 0 && live2 != before && !(totalSlideCount > 0 && live2 > totalSlideCount) {
                    DebugLog.log("Session", "slide \(before): the show is already on \(live2) before click \(steps + 1); no click")
                    pptxSlideNow = live2; moved = true; redrawWaits = 0
                    if steps > 0 { entryClickIndex = clickTimes.count - 1 }
                    CaptureMonitor.shared.pptxSlide = live2; CaptureMonitor.shared.phase = "entering slide \(live2)"
                    break
                }
            }
            // Only a SHORT timer is waited for: a click cannot race a timer minutes away, and waiting out
            // 1.04's long timers took 661 s for a deck that captures in 56 (same day, first version of this).
            // A slide that advances by itself (advTm) is LEFT ALONE once its builds are walked: the deck's own
            // timer is running, and a click sent beside it lands on the NEXT slide and passes it. 2.03 lost
            // three slides of ten that way and 1.01 lost slide 5, on every run (2026-11-25, public 3.4.1
            // suite, field laptop). The recorder is rolling, so the way in is captured as it happens. A
            // timer that never fires falls back to the click.
            if let adv = analysis.autoAdvanceSlides[before], adv <= Self.ownTimerWaitLimit, steps >= max(expectedClicks, 0) {
                let wait = adv + (analysis.transitionDurations[before + 1] ?? 0) + 8
                DebugLog.log("Session", "slide \(before): advances by itself, no click; waiting up to \(Int(wait)) s for the show to move")
                let until = Date().addingTimeInterval(wait)
                var own = 0
                repeat {
                    try? await Task.sleep(for: .milliseconds(100))
                    own = (try? await driver.currentSlideNumber()) ?? 0
                } while (own == 0 || own == before) && Date() < until && !finishing
                if finishing { frameCapture.releaseSettleHold(); return }
                if own != 0 && own != before {
                    if totalSlideCount > 0 && own > totalSlideCount {
                        DebugLog.log("Session", "show position \(own) is past the last slide (\(totalSlideCount)): end of show")
                        showEnded = true
                        await keepTailRecording()
                        await finishCapture()
                        return
                    }
                    DebugLog.log("Session", "slide \(before) advanced by itself to \(own)")
                    pptxSlideNow = own; moved = true; redrawWaits = 0
                    CaptureMonitor.shared.pptxSlide = own; CaptureMonitor.shared.phase = "entering slide \(own)"
                    break
                }
                DebugLog.log("Session", "slide \(before): did not advance by itself in \(Int(wait)) s, clicking")
            }
            DebugLog.log("Session", "slide \(before): click \(steps + 1) (the slide expects \(expectedClicks) build click(s))")
            pendingNoOp = (steps + 1, frameCapture.changedFrameCount, frameCapture.currentFingerprint)
            noteClick()
            do { try await driver.advanceSlide() } catch {
                DebugLog.log("Session", "advance failed (show over): \(error.localizedDescription)")
                showEnded = true
                await keepTailRecording()
                await finishCapture()
                return
            }
            totalAdvances += 1
            steps += 1
            CaptureMonitor.shared.clicksDone = steps
            // After the last expected build, the click must move the show;
            // PowerPoint reports the new position late when it is tearing a
            // movie down (one deck's slide 9 and another's slide 99 were skipped by
            // a second click). Poll for it instead of clicking again.
            var after = 0
            let allBuildsDone = expectedClicks >= 0 && steps > expectedClicks
            // PowerPoint reports the new position only after the entry
            // transition has finished. Wait the declared transition length
            // plus margin, and never re-click while the picture is moving:
            // a 3 s poll re-clicked during 3.4 s transitions, the second
            // click became the entry mark and Presenter started after the
            // transition (1.25 slides 3 and 7, 2026-09-12).
            let declared = analysis.transitionDurations[before + 1] ?? 0
            // Unknown click count (Keynote): any click may be the leaving
            // one, so give every click the transition wait; a 0.15 s poll
            // double-clicked through Keynote's 1 s dissolve (key1, 2026-09-12).
            let unknownClicks = expectedClicks < 0
            var deadline = Date().addingTimeInterval(allBuildsDone || unknownClicks ? max(unknownClicks ? 1.5 : 3.0, declared + 2.0) : 0.15)
            let hardStop = Date().addingTimeInterval(15)
            repeat {
                try? await Task.sleep(for: .milliseconds(100))
                after = (try? await driver.currentSlideNumber()) ?? 0
                if after != before && after != 0 { break }
                if allBuildsDone || unknownClicks, frameCapture.identicalFrameRun < 3, (frameCapture.lastFrameAge ?? 1) < 0.2, Date() < hardStop {
                    deadline = max(deadline, Date().addingTimeInterval(1.0))   // still animating: keep waiting
                }
            } while Date() < deadline
            if totalSlideCount > 0 && after > totalSlideCount {
                // PowerPoint's end-of-show screen (position = count + 1): the
                // deck is done, this is not a slide to capture.
                DebugLog.log("Session", "show position \(after) is past the last slide (\(totalSlideCount)): end of show")
                showEnded = true
                await keepTailRecording()
                await finishCapture()
                return
            }
            if after != before && after != 0 { pptxSlideNow = after; moved = true; redrawWaits = 0; entryClickIndex = clickTimes.count - 1; CaptureMonitor.shared.pptxSlide = after; CaptureMonitor.shared.phase = "entering slide \(after)"; break }
            // Last slide: stop once its builds are walked and one more click has
            // done nothing. It used to stop after TWO clicks whatever the slide
            // held, so a last slide with five builds lost three of them.
            if before >= lastVisibleSlide && lastVisibleSlide > 0 && steps >= max(2, expectedClicks + 1) { break }
        }
        frameCapture.releaseSettleHold()
        if !moved {
            DebugLog.log("Session", "slide number stayed \(before) after \(steps) advances: end of show")
            await keepTailRecording()
            await finishCapture()
            return
        }
        if steps > 1 { DebugLog.log("Session", "slide \(before) had \(steps - 1) build step(s)") }
        frameCapture.resetSettleKeepMotion()

        let nowSlide = pptxSlideNow ?? before + 1
        if analysis.videoSlides.contains(nowSlide) {
            await triggerVideo(on: nowSlide)
        } else {
            armRecordingTimeout(maxRecordingTime, slide: nowSlide)
        }
        if let adv = analysis.autoAdvanceSlides[nowSlide] { watchAutoAdvance(from: nowSlide, after: adv) }
        // Safety net when nothing settles and nothing records: the window went away.
        advanceTimeoutTask?.cancel()
        advanceTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard let self, !Task.isCancelled, !self.recorder.isRecording, !self.finishing else { return }
            self.warnings.append("no frame activity for 10 s after slide \(nowSlide)")
            await self.finishCapture()
        }
    }
}

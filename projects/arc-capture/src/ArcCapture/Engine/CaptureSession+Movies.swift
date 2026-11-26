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

// Movie slides: start click, hold, stall, freeze and stop rules. Split from CaptureSession 2026-09-12 (V2 refactor).
extension CaptureSession {
    /// Video slide: the movie sits somewhere in the slide's click sequence
    /// (1.08 slide 20: second of nine clicks). Walk every click by script
    /// with the recorder rolling, and hold the settle for the clicks plus
    /// the movie's length. `go to next slide` fires click events without a
    /// focus change, so nothing here touches the operator's app.
    func triggerVideo(on nowSlide: Int) async {
        var clicks = analysis.clickCounts[nowSlide] ?? 0
        // Google Slides lengths are not known until the show is on the slide:
        // the embed iframe carries `length_seconds` and only exists for the
        // current slide. Ask the driver first, fall back to the analysis.
        // The read waits for the embed to load, so hold the settle across it
        // or the slide can finalise while we are still asking.
        frameCapture.holdSettle(seconds: 30)
        let known = await driver.liveVideoDuration(onSlide: nowSlide) ?? analysis.slideDurations[nowSlide]
        let clickGap: TimeInterval = 1.5
        // A movie is recorded in FULL as PowerPoint plays it, however long:
        // compositing the source file into its box was considered and
        // rejected (trims, crops, corners, overlays; 2026-09-11 15:20).
        // Capture time equals the movie's length; the report notes long ones.
        // An unknown length (no ffprobe) still gets the 30 s cap.
        // Unknown length (a YouTube link yt-dlp cannot read, a client deck's slide 9):
        // the stop rule ends the clip when picture and sound stop, so the
        // hold can be long instead of the 30 s cap that cut that video.
        let movie = known ?? max(maxRecordingTime, 600)
        if known == nil { warnings.append("slide \(nowSlide): movie length unknown; recording until playback stops (10 min cap)") }
        if movie > 60 { warnings.append("slide \(nowSlide): movie runs \(Int(movie)) s, recorded in full") }
        // "Loop until Stopped": one pass is the clip; Presenter loops it
        // (manifest loop: true). Without this the loop never settles and
        // the recording runs to its timeout.
        let loops = analysis.loopingSlides.contains(nowSlide)
        // "Loop until Stopped": the clip is exactly ONE pass, measured from the
        // click that starts the movie (or from play, when it starts on
        // entry). A fixed 236 s window recorded 8 s of the second pass on the
        // 226 s song of Sample Deck slide 4, so the loop point jumped (
        // 2026-09-12: "the song looped but we are still recording").
        func armOnePass(from start: Date) {
            let end = start.addingTimeInterval(movie + 0.25)
            DebugLog.log("Session", "slide \(nowSlide): movie loops until stopped; recording one pass, settling at +\(String(format: "%.1f", movie + 0.25)) s")
            loopSettleTask?.cancel()
            loopSettleTask = Task { [weak self] in
                let wait = end.timeIntervalSinceNow
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                guard !Task.isCancelled, let self, !self.finishing, self.pptxSlideNow == nowSlide, self.recorder.isRecording else { return }
                DebugLog.log("Session", "slide \(nowSlide): one pass recorded, settling")
                self.frameCapture.settleNow()
            }
        }
        if analysis.mediaStartUnknown.contains(nowSlide) {
            // Did the media start by itself? Listen and look for 2.5 s, with
            // the settle held so the slide cannot be finalised meanwhile
            // (key5: a 1.6 s clip and slide 3 skipped, 2026-09-12).
            frameCapture.holdSettle(seconds: 6)
            let entered = Date()
            await waitForAnimationEnd(step: 0, of: 1)
            try? await Task.sleep(for: .milliseconds(2500))
            let heard = audioMeter.lastAudibleAt > entered
            let moving = frameCapture.identicalFrameRun < 3 && (frameCapture.lastFrameAge ?? 1) < 0.3
            if heard || moving {
                DebugLog.log("Session", "slide \(nowSlide): media started on entry (\(heard ? "sound" : "motion")); no start click")
                clicks = 0
            } else {
                DebugLog.log("Session", "slide \(nowSlide): nothing started on entry; one click to start the media")
                clicks = 1
            }
        }
        if clicks > 0 {
            let hold = Double(clicks) * clickGap + movie + 8.5
            DebugLog.log("Session", "slide \(nowSlide): video slide with \(clicks) click(s); walking them, settle held \(Int(hold)) s")
            CaptureMonitor.shared.phase = analysis.loopingSlides.contains(nowSlide) ? "slide \(nowSlide): looping movie, recording one pass" : "slide \(nowSlide): movie, recording in full"
            CaptureMonitor.shared.holdTotal = hold; CaptureMonitor.shared.holdRemaining = hold; CaptureMonitor.shared.clicksExpected = clicks
            frameCapture.forceMotionMode()
            frameCapture.holdSettle(seconds: hold)
            armRecordingTimeout(hold + 15, slide: nowSlide)
            clicksWalkedFor = nowSlide
            // The slide's entry transition may still be running; a click
            // during a transition is swallowed by PowerPoint and the movie
            // never starts (Sample Deck TEST slides 2 and 4, 2026-09-11 20:30).
            await waitForAnimationEnd(step: 0, of: clicks)
            if !clickTimes.isEmpty { await splitEntryClip(for: nowSlide) }
            watchForStalledMovie(on: nowSlide, hold: hold)
            for i in 0..<clicks {
                if i == clicks - 1 { movieClickAt = Date() }     // the movie is the last click of its sequence
                noteClick()
                try? await driver.advanceSlide()
                totalAdvances += 1
                try? await Task.sleep(for: .seconds(clickGap))
                // Safety: if the click count was wrong and the show moved on,
                // stop clicking and account for the slide we are now on.
                if let pos = try? await driver.currentSlideNumber(), pos != nowSlide, pos != 0 {
                    warnings.append("slide \(nowSlide): click \(i + 1) of \(clicks) moved the show to \(pos); its click count was wrong")
                    pptxSlideNow = pos
                    break
                }
            }
            if loops, let t = movieClickAt { armOnePass(from: t) }
            return
        }
        // Fresh stream at every movie start: the freezes above never began on
        // a slide right after a restart.
        _ = await frameCapture.restartStream()
        if analysis.autoPlaySlides.contains(nowSlide) {
            CaptureMonitor.shared.phase = "slide \(nowSlide): movie plays on entry, recording"
            CaptureMonitor.shared.holdTotal = movie + 9; CaptureMonitor.shared.holdRemaining = movie + 9
            watchForStalledMovie(on: nowSlide, hold: movie + 9)
            // Plays on entry: a click here would advance the slide. On slide 1
            // the movie started with the show, before capture attached; the
            // dictionary's `go to slide` is editor-only and `go to first
            // slide` STOPS the movie (measured 2026-09-11), so the opening
            // fraction of a second is accepted as lost and noted.
            if slides.isEmpty { warnings.append("slide 1: movie plays on entry; capture attached after the show started, opening moments not recorded") }
            DebugLog.log("Session", "slide \(nowSlide): movie plays on entry, no click")
        } else {
            var played = 0
            do { played = try await driver.playCurrentSlideMedia() } catch {
                DebugLog.log("Session", "slide \(nowSlide): scripted play unavailable")
            }
            if played > 0 {
                DebugLog.log("Session", "slide \(nowSlide): started \(played) player(s) by script")
            } else {
                noteClick()
                try? await driver.sendNextClick()
            }
            // This branch had no stall watch. A "When Clicked On" video (an
            // interactive sequence with togglePause: it plays only when the
            // PICTURE is clicked) starts on neither the script nor the key, and
            // the poster was recorded for the movie's whole length and reported
            // "recorded in full" (3.02 slide 3, 107 s of a still, 2026-09-17).
            watchForStalledMovie(on: nowSlide, hold: movie + 9)
        }
        frameCapture.forceMotionMode()
        if loops { armOnePass(from: Date()) }
        // Hold the settle for the movie's length so subtle motion cannot end
        // the clip early; an unknown length gets a 6 s hold and the timeout.
        frameCapture.holdSettle(seconds: movie + 0.5)
        let timeout = movie + 15
        DebugLog.log("Session", "slide \(nowSlide): embedded video, timeout \(Int(timeout)) s")
        armRecordingTimeout(timeout, slide: nowSlide)
    }
    func armRecordingTimeout(_ timeout: TimeInterval, slide nowSlide: Int) {
        recordingTimeoutTask?.cancel()
        recordingTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard let self, !Task.isCancelled, self.recorder.isRecording else { return }
            DebugLog.log("Session", "timeout on slide \(nowSlide) after \(Int(timeout)) s")
            await self.forceStopRecordingOnTimeout()
        }
    }
    /// While a movie slide's hold runs, watch the stream: if nothing has
    /// changed for `movieStallSeconds` after the last click, the movie did
    /// not start. Warn, release the hold, settle, and carry on.
    /// While a movie records: PowerPoint's window stops being redrawn now
    /// and then with the audio still playing (slide 4 of Sample Deck short,
    /// 2026-09-12: 2,400 identical frames while the song went on). A restart
    /// of the capture stream wakes it. `restartStream` measures whether the
    /// stream really was stale (fresh screenshot against the last frame);
    /// a picture that is genuinely still (movie ended on a frame, audio
    /// only) gets a 30 s back-off instead of a restart every 6 s.
    func watchFrozenPicture(on slide: Int, until deadline: Date) async {
        let frozenFrames = Int(movieStallSeconds) * 30
        var backoffUntil = Date.distantPast
        let movieStart = movieClickAt ?? Date()
        // Is the SOURCE silent over [from, to] (seconds into the movie)? The
        // analyzer measured its quiet stretches; a movie with no audio
        // track is silent throughout.
        // The meter's silence can begin a few seconds before the source's
        // measured stretch (1.25 slide 14: meter quiet from 12 s, source
        // stretch from 13.9 s). A source stretch covering the LAST 5 s of the
        // window is enough to say the source is quiet here.
        // Returns the END of the source's silent stretch covering the window
        // (nil = the source has sound there, so silence means a stop).
        let sourceSilentUntil: (Double, Double) -> Double? = { [analysis] from, to in
            guard let sil = analysis.slideSilences[slide] else { return nil }
            return sil.first { $0[0] <= max(from, to - 5.0) && $0[1] >= to - 1.0 }?[1]
        }
        while !Task.isCancelled, !finishing, pptxSlideNow == slide, recorder.isRecording, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(500))
            // Picture AND sound still: playback has stopped (PowerPoint gave
            // up on Sample Deck short slide 4 at 68 s). End the clip there rather
            // than record silence to the movie's nominal length.
            let heard = audioMeter.lastAudibleAt
            let silentFor = Date().timeIntervalSince(heard)
            // A quiet still stretch that the source itself has here is not a
            // stop (1.25 slide 16); only after 30 s does it count regardless.
            let since = Date().timeIntervalSince(movieStart)
            // Known quiet stretch in the source: wait until it ends (plus the
            // usual 8 s) before calling a stop; 1.25 slide 14 has 39 s of
            // silence at 94 s and a flat 30 s fallback cut it (2026-09-12).
            var needed: TimeInterval = movieStallSeconds + 2
            if let end = sourceSilentUntil(since - silentFor, since) {
                needed = max(30, (end - (since - silentFor)) + movieStallSeconds + 2)
            }
            if frameCapture.identicalFrameRun >= frozenFrames, heard > movieStart, silentFor >= needed {
                let at = Date().timeIntervalSince(movieStart) - silentFor
                let msg = "slide \(slide): playback stopped \(Int(at)) s into the movie (picture and sound both still for \(Int(silentFor)) s); clip ends there"
                if let now = recorder.clipTime() { stopAtForCurrent = max(0, now - silentFor + 0.5) }
                DebugLog.log("Session", "STOP: " + msg)
                warnings.append(msg)
                loopSettleTask?.cancel(); loopSettleTask = nil
                frameCapture.settleNow()
                return
            }
            // A movie that NEVER started: the picture left the poster (to black) and stayed there, and no sound was
            // ever heard, while the source has sound here. PowerPoint sat black on a 617 MB embedded movie for the
            // whole 266 s hold (one deck's slide 3, 2026-09-19, the operator: "seems stuck"). Two back-offs is enough to know.
            if heard <= movieStart, since >= 2 * 30 + movieStallSeconds, frameCapture.identicalFrameRun >= frozenFrames,
               sourceSilentUntil(max(0, since - silentFor), since) == nil, analysis.slideDurations[slide] != nil {
                let msg = "slide \(slide): the movie never started (black and silent \(Int(since)) s after its click); moving on. The source movie is used in its place when it fills the slide; otherwise recapture the slide"
                stopAtForCurrent = 0.5
                DebugLog.log("Session", "STALL: " + msg)
                warnings.append(msg)
                CaptureMonitor.shared.stalls += 1
                loopSettleTask?.cancel(); loopSettleTask = nil
                frameCapture.settleNow()
                return
            }
            guard Date() >= backoffUntil, frameCapture.identicalFrameRun >= frozenFrames else { continue }
            // Sound already gone quiet: the stop rule above will end the clip
            // in a few seconds; a restart here only delays it (short5: 12 s).
            if heard > movieStart, silentFor >= 3 { continue }
            let stale = await frameCapture.restartStream()
            // Screenshot-versus-stream noise on the same picture is ~0.008
            // (short4); a truly different picture reads > 0.3.
            if stale == nil || stale! >= 0.05 {
                // Stale, or not measurable: the restart has happened either
                // way; note it and give the stream 30 s before judging again.
                DebugLog.log("Session", "slide \(slide): picture frozen \(Int(movieStallSeconds)) s mid-movie, stream \(stale.map { String(format: "stale %.3f", $0) } ?? "staleness unknown"); restarted")
                warnings.append("slide \(slide): PowerPoint stopped drawing mid-movie; capture stream restarted")
                CaptureMonitor.shared.stalls += 1
                backoffUntil = Date().addingTimeInterval(30)
            } else {
                DebugLog.log("Session", "slide \(slide): picture still \(Int(movieStallSeconds)) s, stream not stale (\(stale.map { String(format: "%.3f", $0) } ?? "n/a")), sound \(silentFor < 1 ? "playing" : "silent \(Int(silentFor)) s"); backing off 30 s")
                backoffUntil = Date().addingTimeInterval(30)
            }
        }
    }
    /// A picture that stays still once the slide's movie has had its whole length to play is the movie's END,
    /// not a stall. The ARC TEST movie is 6 s and ends on a held card; the poster check needs 6 s of stillness
    /// plus a stream restart, so it always concluded after the movie had finished and reported every run
    /// "movie did not start" (2026-09-30). The price: a SHORT movie that truly never starts is not reported.
    nonisolated static func movieHasRunItsLength(_ length: TimeInterval?, elapsed: TimeInterval) -> Bool {
        guard let length, length > 0 else { return false }
        return elapsed >= length + 0.5
    }

    func watchForStalledMovie(on slide: Int, hold: TimeInterval) {
        stallWatcher?.cancel()
        let armed = Date()
        let length = analysis.slideDurations[slide]
        let clicks = analysis.clickCounts[slide] ?? 0
        let clickPhase = Double(clicks) * 1.5 + 1.0
        // "Did not start" means the slide still shows its POSTER: the frame
        // as it was before any click. A dark movie can differ from black by
        // less than any tiny threshold (Sample Deck slide 2, red logo on
        // black), so comparing frame-to-frame over time was wrong too.
        let poster = frameCapture.currentFingerprint
        stallWatcher = Task { [weak self] in
            try? await Task.sleep(for: .seconds(clickPhase))        // let the clicks and their animations go by
            let started = Date()
            var samePosterSince: Date? = nil
            // A movie that played and then rewound to its poster ("Rewind
            // after playing", Sample Deck slide 2) is not a stall: once the
            // frame has left the poster, the watcher is done.
            while !Task.isCancelled, let self, !self.finishing, self.pptxSlideNow == slide,
                  Date().timeIntervalSince(started) < hold {
                try? await Task.sleep(for: .milliseconds(500))
                guard let fp = self.frameCapture.currentFingerprint, let poster else { continue }
                // A still picture with sound is a movie that started (1.25
                // slide 19: 12 s of static frame under loud audio; the
                // MP3 slides never move at all).
                let audible = self.audioMeter.lastAudibleAt > started
                let onPoster = FrameAnalysis.difference(poster, fp) < 0.002 && !audible
                if !onPoster {
                    DebugLog.log("Session", "slide \(slide): movie is playing")
                    await self.watchFrozenPicture(on: slide, until: started.addingTimeInterval(hold))
                    return
                }
                if samePosterSince == nil { samePosterSince = Date() }
                if Date().timeIntervalSince(samePosterSince!) >= self.movieStallSeconds {
                    // PowerPoint's own rendering freezes now and then while
                    // the audio keeps playing (Sample Deck runs 4 and 5: 29-42,
                    // 44-47); every recovery so far followed a stream restart.
                    // Restart, give it two seconds, and only then give up.
                    DebugLog.log("Session", "slide \(slide): frozen on its poster; restarting the capture stream")
                    _ = await self.frameCapture.restartStream()
                    try? await Task.sleep(for: .seconds(2))
                    if let fp2 = self.frameCapture.currentFingerprint, FrameAnalysis.difference(poster, fp2) >= 0.002 {
                        DebugLog.log("Session", "slide \(slide): rendering resumed after the restart")
                        self.warnings.append("slide \(slide): PowerPoint stopped drawing during its movie; recovered by restarting the capture stream")
                        samePosterSince = nil
                        continue
                    }
                    if Self.movieHasRunItsLength(length, elapsed: Date().timeIntervalSince(armed)) {
                        DebugLog.log("Session", "slide \(slide): its \(String(format: "%.1f", length ?? 0)) s movie has run its length; the still picture is where it ended, not a stall")
                        self.frameCapture.settleNow()
                        return
                    }
                    let msg = "slide \(slide): movie did not start (still on its poster frame \(Int(self.movieStallSeconds)) s after its click); moving on. If it is set to start When Clicked On, set Start to In Click Sequence or Automatically in PowerPoint"
                    DebugLog.log("Session", "STALL: " + msg)
                    self.warnings.append(msg)
                    self.frameCapture.settleNow()
                    return
                }
            }
        }
    }
}

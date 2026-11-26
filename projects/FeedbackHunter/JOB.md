# Spotting feedback from a phone in my pocket

| Tool | Status | Stack |
|---|---|---|
| FeedbackHunter | partial | Swift, SwiftUI, AVAudioEngine, Accelerate, WatchConnectivity (iOS and watchOS) |

## The job
During a show the sound tech is rarely standing where the problem is. I am at the mix position, or walking the room, or behind the stage fixing something else, and a lavalier starts to ring at the edge of hearing. The usual tool is ears, a guess at the frequency, and a hand on the graphic EQ. Most phone RTA apps just draw bars. They do not say which bar matters, and I cannot stare at a phone while running a show.

This was my first attempt at a tool for that. An RTA on the phone that marks the band it thinks is feeding back, and a watch face that shows the level and the peak band at a glance.

## Why it is hard
- A phone mic is not a measurement mic. It has its own response and gain stage, so absolute SPL from it is a rough number.
- Feedback and music look alike in a single frame. A loud band is not feedback. What separates them is behaviour over time. Feedback is narrow, stays put, and grows.
- A 4096 point FFT at 48 kHz gives about 12 Hz bins and an 85 ms window. That is coarse in the low end and slow for a fast onset.
- Thresholds that work in a quiet room fire constantly in a loud one. Any fixed number is wrong somewhere.
- The watch link is slow and lossy. It can carry a level and a band a few times a second, not a spectrum.

## What the machine does now
The iOS app captures the microphone, runs a 4096 point FFT with 50 percent overlap, groups the bins into octave fraction bands and draws them as bars with an SPL readout. A detector flags a band on three tests. It stands 8 dB above the median of all bands, it has held that level for half a second, and a linear fit over the last half second shows it rising at 3 dB per second or more. Bands under -60 dB are ignored. A toggle switches the bars for a waterfall that keeps 600 frames, about ten seconds, in grey scale. A companion watch app shows an SPL gauge and the current peak band, fed from the phone.

## What still needs a person
Everything that follows detection. The app does not touch a mixer. The person decides whether the flagged band is a ring or a singer holding a note, finds it on the EQ, and makes the cut. The thresholds were set by ear on a desk, not validated on a PA. The SPL figure is uncalibrated. I stopped work on this when I understood that looking for a rising tone was the wrong model. The better signature is a tail that outlasts a hit, and that became a separate desktop tool (ARC Audio Scope).

## Rebuilding it
Four small pieces. A capture manager installs a tap on the input node and buffers samples until it has one FFT frame, then advances by half a frame. An FFT processor returns magnitudes in dB using vDSP. A band analyzer sums bins into bands and keeps a short history per band. A detector reads those histories and sets three flags per band, prominent, sustained and increasing, and raises an alert when they agree.

Decisions worth keeping. Make every threshold a published setting, because no fixed value survives a change of room. Use the median, not the mean, as the reference level so one loud band does not lift the bar for the rest. Send the watch only two numbers. Cap the waterfall at a fixed frame count so memory cannot grow.

Traps. The tap's buffer size is a request, not a promise, so count samples yourself. Read the session sample rate instead of assuming 48 kHz. If I did it again I would detect on decay after an impulse and use two FFT sizes.

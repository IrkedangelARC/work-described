# Knowing which slide was on screen, and when, after the show is over

| Tool | Status | Stack |
|---|---|---|
| ARC Slide Log | working on the bench | Swift (ScreenCaptureKit, AVFoundation, CGEvent tap) on macOS, C# on .NET 8 (Windows Graphics Capture, Media Foundation, WASAPI) on Windows, Python rebuild tool |

## The job
When I edit a recorded talk, the slides go back in as clean full frame images cut against the camera. I need to know which slide was up at every moment. My own player knows. In a breakout room where presenters use their own apps, nobody knows.

At one multi-room event the only record of the slides was a camera pointed at the screen. Working out the slide changes took an overnight pipeline of screen tracking, page matching, text recognition on blown out screens and matching speech to deck text. It still needed a person to settle the doubtful ones by eye.

## Why it is hard
- I do not control the presentation app. Preview, Chrome, PowerPoint and Keynote each expose different state, some none. Probing apps for a page number was the first design and I threw it away.
- A full resolution recording of every room is gigabytes nobody wants. But ScreenCaptureKit sends no frame while the picture is static, so a tiny variable rate recording is a change log. A frame's timestamp is the time the picture changed.
- On Windows the fragmented MP4 sink keeps sample durations and drops timestamp gaps. A 45 second session came out 27 seconds long. Each frame has to be written with its hold as its duration when the next change arrives.
- WASAPI loopback delivers nothing when nothing plays, so silence must be filled in. In one file with the picture, the sink held sound 10 seconds behind, so sound is a separate file on Windows.

## What the machine does now
A menu bar app (tray app on Windows) records three things into a session folder.
1. A proxy of the program display, 640 pixels on the long side, up to 10 frames a second, H.264 at about 300 kb/s, with the presentation's own sound. About 100 to 250 MB per two hours.
2. `track.jsonl` with every click impulse, its monotonic and wall time, key or mouse, the key name, and the app in front. Keys are never logged as typed text.
3. A 16 kHz mono scratch recording from a chosen input, for cross-correlation against camera audio.

A header file carries the clock offsets. The session cannot be repeated, so the proxy is written in 5 second fragments and the WAV header is rewritten every 5 seconds. A kill at 18 seconds left 12 seconds playable. It restarts the scratch input when a device disappears and refuses to start under 2 GB free.

A rebuild tool renders the deck to pages, matches every proxy frame to a page, and lays the clean pages on the proxy's timeline. In the end to end test, 14 of 14 visible slides were identified, each keystroke landed on the track within 14 ms of when it was sent, and the picture changed 23 to 49 ms after each key.

## What still needs a person
- Collecting the deck files afterward. Without them there is nothing to match.
- Embedded video. The rebuild shows the still. Placing the deck's media on the timeline is not built.
- The importer into the editing pipeline is designed, not built.
- Display loss recovery is coded and not drilled. The Windows build is unsigned, and a fresh Windows 11 blocks unsigned executables by reputation.
- Tapping the HDMI feed with a capture device, for rooms where I cannot install software, is plan only.

## Rebuilding it
Four parts. A proxy recorder (display stream into an asset writer), a click logger (listen-only event tap on its own thread), a scratch audio writer, and a session object that owns the folder, the clocks and the status line. Same folder format on both systems.

Record evidence and do not interpret at the show. Interpretation can be redone, a missed recording cannot. Log impulses, not text. Two clocks on every event.

Traps. Under the hardened runtime the microphone is denied silently unless the audio input entitlement is present. On Windows, cast every integer attribute to unsigned or the encoder refuses the media type. Enable low latency on the writer or a kill loses 9 seconds of picture.

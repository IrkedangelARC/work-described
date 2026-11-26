# Turning a presenter's deck into something that cannot surprise me

| Tool | Status | Stack |
|---|---|---|
| ARC Capture | working on the bench | Swift, SwiftUI, ScreenCaptureKit, AVFoundation, AppleScript and Accessibility, ffmpeg, Python test tools |

## The job
Presenters send PowerPoint, Keynote and Google Slides files the night before, and again an hour before doors. I used to open each one on the show laptop and click through every slide looking for missing fonts, dead video and odd builds. Then I ran the native app live and hoped, or exported a PDF and lost every animation and movie.

A two day symposium is 20 to 40 decks. The check takes longer than the gap between the file arriving and the talk.

## Why it is hard
- An export is not what the audience sees. PDF export flattens builds, transitions and media. The only faithful record is the pixels the app drew, so I record the running slideshow window.
- macOS stops drawing a fully covered window. The show must run windowed on an awake, uncovered display.
- PowerPoint reports its position through one AppleScript property, and only after the entry transition ends. A slide with N builds keeps its number for N clicks. The walk must click, wait for the picture to settle, and judge whether a click was lost.
- "Appear" builds contain no motion. In one 367 page deck, 98 of 100 builds were hard cuts. As video they made playback stutter.
- Presenters time builds to speech and need to back up one build. A continuous clip cannot back up because keyframes sit about 4 seconds apart. Each build needs its own clip and a still of the state it leaves.
- Audio sync broke twice. Dropping an audio buffer when the writer is busy removes 21.3 ms each time, about two per five seconds on a loaded laptop. After that fix the picture still sat 350 to 590 ms behind the sound, different per machine, drifting up to half a second a minute.

## What the machine does now
It opens a deck in PowerPoint, Keynote or Google Slides, starts a windowed show parked on a second display at 1920x1080, and walks every click. It records each transition and build with the app's own audio and writes an `.arcdeck`, one PDF with a page per slide, a clip and a still per build, and a manifest (titles, media, transitions, notes, hidden slides, source hash).

A show is a folder. Decks named `1.06 Speaker.pptx` become items in run order. A changed source is detected by hash and captured as a new version. The old version is never overwritten. Every deck is verified before it is called ready. PDFs, images and movies become decks without a capture. A review queue lists slides that need a human. It runs headless with a JSON report, and hands the folder to ARC Presenter with one HTTP call.

## What still needs a person
- Reading the review queue. The tool says what it doubts. It does not judge if a slide looks right.
- Keeping hands off. A stray key during a capture advances the show and leaves no trace in any log.
- Keynote decks with video do not capture yet.
- Google Slides capture is not tested on the free build.
- Changed-slides-only recapture is built but has never run on real hardware.
- Two machines failed 4 and 8 of 36 synthetic test decks in the last run.

## Rebuilding it
Three layers. A driver per presentation app to open, start a windowed show, advance one click, report position and stop. An engine that knows nothing about apps, with a frame source that turns the stream into settled and motion events by fingerprint diff, a session that walks clicks, a recorder and a writer. A show folder store with a ledger of per-slide hashes.

Capture the window, never the export. Sign with a stable developer identity so permission grants survive rebuilds, and launch through the system launcher, because a process started from ssh does not inherit the screen recording grant. Queue audio, never drop it. Measure sync with a flash and click reference deck. A shown slide without a page is a failure.

Hardware decoded video may be missing from the capture, so every video slide needs a timeout. PowerPoint draws a poster flash after a movie that has to be repaired in the recording.

## Running the free build
The build is free and offered as is. It is signed and notarized. I do not ship ffmpeg. You install your own.

The suggested donation is $138. There is no minimum and nothing is owed. If it saves you a show, give what it was worth to you through the Sponsor button on this repository.

### What you need
- macOS 15 or later, Apple silicon or Intel.
- A second display at 1920x1080, or an HDMI dummy plug. The show plays there in a window.
- `ffmpeg` and `ffprobe` in the same folder. `brew install ffmpeg` does it. The app looks in `/opt/homebrew/bin`, `/usr/local/bin`, `/opt/local/bin` and `/usr/bin`. It will not call itself ready without them.
- Microsoft PowerPoint with your own license, for `.pptx` and `.ppt` decks.
- Keynote, for `.key` decks.
- Google Chrome, for Google Slides links. The app runs Chrome with its own profile and leaves your everyday profile alone. You sign that profile in once with the account the decks are shared to.
- PDFs, images and movies need none of the three apps.

### Permissions macOS asks for
- Screen and System Audio Recording. Required. The app records the show window and the deck's audio.
- Accessibility. Required. The app moves and sizes the show window and clicks inside it to start movies.
- Automation for System Events. Required. It places the window and posts clicks.
- Automation for Microsoft PowerPoint, if it is installed. The app opens the deck, starts the show, advances one click and reads the slide number.
- Automation for Keynote, if it is installed. Same job.
- Files and Folders for Desktop, Documents and Downloads, asked the first time you pick a deck there.

The READY? panel in the app shows each of these red or green and names the switch in System Settings. A permission refused by mistake is not asked again. Switch it on by hand, then quit and reopen the app.

### Optional
- ARC Grab fetches video links inside a deck, such as YouTube. Without it those slides go to the review list.
- An Ollama model on the same Mac repairs agenda rows the built in reader cannot parse. Without it the rows go to the review list.
- ARC Presenter opens the whole `.arcdeck`. It is a separate product. The PDF and the clips inside the folder open in any player.

Every deck gets a logo page at the start and the end. Put your own `bumper.png` at the top of the show folder and the app uses yours.

### Credit
ARC Capture is made by ARC Event Productions in San Jose, California. We don't sell failure™. The About box says so, and every PDF the app writes names ARC Capture and ARC Event Productions as the tool that made it. The author and title of the slides are left alone. They belong to the presenter. The license covers the software. The ARC name, the ARC mark and the tagline stay with ARC Event Productions.

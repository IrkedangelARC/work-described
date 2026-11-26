# Playing back other people's slides without surprises

| Tool | Status | Stack |
|---|---|---|
| ARC Presenter | working in the field | Swift, SwiftUI, AppKit, PDFKit, AVFoundation, ScreenCaptureKit, CoreAudio process taps, Blackmagic DeckLink SDK, local HTTP control API |

## The job
At a talk or symposium one operator sits at a tech table with a laptop feeding the room screen and a confidence monitor at the stage. Twenty presenters hand over decks. The operator opens each one, finds the slide, plays walk-in music, runs a countdown, and switches to the presenter who insists on native PowerPoint. The audience must never see a desktop, a file dialog or a loading bar.

Before this I used PowerPoint on an extended display, a timer app, a music player, and a video switcher to hide the joins.

## Why it is hard
- Every visible join is a failure. Opening the next deck, scrubbing to a slide and starting a video must happen on a preview, then be taken to program in one cut.
- Click to picture must be instant. Pausing every player of every open deck on each click cost 15 to 23 ms. Pausing only running players cost 1 ms.
- PDFKit's own view queues animations on rapid advance. Pages have to be pre-rendered at output pixel size off the main thread and swapped as layers.
- A build clip that played before sits on its last frame. Shown before it is rewound, the audience sees the finished build flash, vanish, then play.
- Switching to another app's fullscreen show is normally a hardware job. A borderless window at the shielding level already sits above everything, so its alpha is the switcher. But macOS stops drawing a covered window, so the reveal can show one stale frame. The fade through black is load bearing.
- A crash on program is a desktop in front of a full room.
- A late revision arrives while the old deck is live. You never yank a live deck.

## What the machine does now
It plays PDF, video and `.arcdeck` decks (per-build clips from ARC Capture) in tabs with a preview and live model, TAKE and BLACK. Program goes to a display and to SDI through a DeckLink at the same time. The confidence monitor shows current, next click, notes, a timer and messages to the presenter. Builds play forward as clips and cut backward to stills.

It parks a running PowerPoint show, or any other app's window, under the program output and fades to it. It forwards clicker keys to that app and mutes it on return. It taps another app's audio for two music channels with fades and auto duck. It watches a show folder, opens new items in run order and stages a new version at the matching slide by aligning per-slide hashes. State is saved 250 ms after any change and restored on launch, live deck first. A second small process watches the main one. If it dies, the watcher holds the last frame with a red border within about 18 ms, relaunches, and drops the cover when program is healthy, about 1.3 seconds. Every program change goes to a show log and a slide track. Everything is on a localhost HTTP API.

## What still needs a person
- Deciding when to TAKE.
- Displays vanish when a cable is bumped. Outputs return by display UUID in code, but unplug and hot plug are not all drilled on hardware.

## Rebuilding it
One app, engines behind views. A deck manager (preview, live), a slide engine per deck, a page render cache, a display manager that owns the program and confidence windows, a switch engine for external sources, music, timer and message engines, a session store, a control server bound to 127.0.0.1.

Decisions. Program is a borderless shielding-level window, never native fullscreen, so it can cover and reveal other apps. Preview and live are separate so nothing is prepared on air. Log every state change with its origin. Put crash cover in a separate process. Queue AppleScript calls serially and drop stale clicks, because PowerPoint can wedge for seconds.

Traps. A debug build re-prompts for Accessibility, so stage a release build for live checks. Forwarded key events must be tagged so the clicker tap ignores them.

## Running the free build
The build is free and offered as is. It is signed and notarized.

The suggested donation is $138. There is no minimum and nothing is owed. If it saves you a show, give what it was worth to you through the Sponsor button on this repository.

### What you need
- macOS 15 or later.
- An external display for the program output. A second one for the confidence monitor if you want it.
- Microsoft PowerPoint with your own license, only if a presenter insists on the native show.
- Blackmagic Desktop Video, only if program goes out through a DeckLink or UltraStudio. Without it the SDI output reports not available.
- PDF, movie and `.arcdeck` decks need no other app.

### Permissions macOS asks for
- Accessibility. The app listens for the clicker and passes its keys to PowerPoint when a PowerPoint show is live.
- Screen and System Audio Recording. The app captures another app's show window for the program output and takes music from the app playing it. The grant takes effect after a relaunch.
- Automation for Microsoft PowerPoint. The app starts the slideshow and advances it.

The THIS MAC panel on the load screen shows each one red or green. Playing a PDF, a movie or an `.arcdeck` needs none of them.

The app needs no account and reports nothing. The control API listens on this Mac only.

### Credit
ARC Presenter is made by ARC Event Productions in San Jose, California. We don't sell failure™. The About box says so. The license covers the software. The ARC name, the ARC mark and the tagline stay with ARC Event Productions.

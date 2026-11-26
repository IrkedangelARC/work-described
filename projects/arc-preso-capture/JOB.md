# Flattening a deck's builds into pages, the first attempt

| Tool | Status | Stack |
|---|---|---|
| ARC Preso Capture | retired | Swift, SwiftUI, ScreenCaptureKit, CGEvent, PDFKit |

## The job
My slide player at the time showed PDFs. A PDF export of a PowerPoint deck gives one page per slide, with every build already finished. A presenter who reveals five bullets one at a time gets all five at once, and the talk falls apart.

The manual fix was to open the deck, step through every click, take a screenshot at each state, and assemble the screenshots into a PDF. For a 40 slide deck with builds that is 150 screenshots. I did it a few times.

## Why it is hard
- Nothing tells you how many clicks a deck has. Slide count is not click count.
- Nothing tells you when a build has finished drawing. This first version waits a fixed delay, default 2 seconds, and hopes.
- Nothing tells you the deck has ended. This version stops when the screen is identical for several captures in a row. Two slides that look the same, or a section divider repeated, end the capture early.
- Sending a key to "whatever is in front" needs the Accessibility permission. Capturing the screen needs the Screen Recording permission. Both need an app restart after the grant, and both are lost when the signing identity changes.
- A still per click loses everything that moves. Transitions, animated builds, embedded video, sound. For a deck of static bullets that is fine. For anything else it is not.
- Capturing the whole display means the presentation has to be fullscreen on a display nobody touches for the whole run.

## What the machine does now
A floating control panel. Pick a display, set a lead-in, an advance delay, a maximum slide count and a stable-frame threshold. Put the deck into fullscreen presentation mode on that display and press Start. The app captures a frame with ScreenCaptureKit, posts a Right Arrow key event, waits, captures again. Each frame is downsampled to 64x36 and hashed with SHA-256. When the hash repeats enough times, or the maximum is reached, it stops and writes a PDF with one page per captured state plus the PNG sequence into a timestamped folder.

It is about 500 lines and one commit of real work. The repository has no release script and no test target.

## What still needs a person
Everything around it. Start the show by hand. Guess the delay. Watch that it did not stop early. Check the page count. Handle any slide with video some other way. The end-of-deck threshold trades early stops against a tail of duplicate pages, and there is no right value.

## Rebuilding it
The simple version is five small pieces. A display capturer (one screenshot call), a keystroke sender (post a virtual key down and up), a frame hasher (downsample then hash, so cursor blink and compression noise do not change the result), a PDF compiler (one image per page), and a controller loop with a lead-in so you can get your hands off the keyboard.

Downsample before hashing. A full resolution hash never repeats. Keep the PNGs beside the PDF so a bad page can be replaced by hand. Not sandboxed, because posting events to other apps is not allowed in the sandbox.

What it taught. Its successor, ARC Capture, answers each weakness.
- A fixed delay became settle detection. A build is done when N consecutive frames match.
- "Identical frames mean the end" became asking the presentation app for its position through scripting, and comparing against the slide count from the file.
- Blind arrow keys became a driver per app that advances by script without stealing focus.
- Whole display capture became capture of one window, parked on a second display.
- Stills only became a clip and a still per build, with sound.
- A loose PDF became a deck bundle with a manifest and a verifier.

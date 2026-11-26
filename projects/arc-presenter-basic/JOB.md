# Showing a PDF on the room screen with nothing that can break

| Tool | Status | Stack |
|---|---|---|
| ARC Presenter Basic | working in the field | Swift, SwiftUI, AppKit, PDFKit, IOKit |

## The job
Some shows need exactly one setup. A laptop at the tech table, one external display or projector, and a merged PDF of the day's slides. The operator pages forward and back, goes to black between speakers, and jumps to a slide number when a presenter says "can you go back to the chart".

I used to do this with a PDF reader in full screen mode on an extended display. It works until the reader shows its toolbar, the display sleeps, or someone asks to see a different file while the current one is on screen.

## Why it is hard
- Every feature in a full show player is a failure surface. Video, timers, messages, tabs and session restore each add a way to die. Where a dead screen ends the event, I cut features.
- The operator still needs one thing a plain viewer cannot do. Open and browse a different PDF without touching what the room sees. That takes two engines, one live and one browse, and an explicit "send to output".
- PDFKit's view queues animations when you advance fast. Rapid presses on Next produced a visible jump on the room screen. The fix was to stop using the PDF view for program and show pre-rendered images from a cache.
- A page cache needs an eviction rule that knows where the operator is. On a 516 page deck a naive cache evicted page 1 and the room saw a loading bar mid show. Eviction now drops the pages farthest from the current one, the cap follows installed RAM, and render size follows the PDF's native size up to 1920x1080.
- The external display disappears when HDMI is bumped. The output window has to find its screen again, with a debounce, and fall back to any external display.
- The Mac must not sleep between decks, so the sleep assertion is held for the life of the app, not only while output is open.

## What the machine does now
It opens a PDF, lists external displays by index, resolution and name, and opens a borderless output on the chosen one. The operator window shows the current slide, the next slide, a clock and a filmstrip. Next, previous, first, last, jump to number and black each have a button and a hotkey. Keys come from a local monitor, so no Accessibility grant is needed, at the price that the app must be frontmost. A second PDF opens into BROWSE, where paging does not touch the output, and "Send to Output" swaps it to live at page 1. It holds the display awake while running. It recovers the output when a display returns. There is no video, no timer, no notes, no preferences, no session restore and no network.

## What still needs a person
- Building the merged PDF beforehand. This tool only plays it.
- Deciding when to go to black and when to switch decks.
- Anything with motion. A presenter with video or builds needs the full player or the native app.
- 4K outputs. The render cap is 1920x1080.
- The stress list (rapid navigation, sleep and wake, HDMI unplug and replug) has no record of being run in full on hardware.

## Rebuilding it
About 1,300 lines. A `SlideEngine` holds a PDF document and a page index. A `DeckSession` holds one live engine and at most one browse engine. A `PageCache` renders pages to images in parallel on a background queue and evicts by distance from the current page. A `DisplayManager` owns one borderless window on one external screen and re-finds it after display changes. Two views, operator and program.

Decisions. Branch from the big player and delete. Do not add flags. Separate repository, no shared dependencies. Hardcoded shortcuts and no settings, so there is nothing to misconfigure at a show. Program shows cached images, never a live PDF view.

Traps. An API that only exists on the newest macOS will keep the app from launching on an older fleet laptop, so set the deployment target one version back and test there. The plan document still says "no code written". Three versions shipped after that line.

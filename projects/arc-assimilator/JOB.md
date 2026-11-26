# One app to catalog, convert and assemble a whole show's decks, and why I retired it

| Tool | Status | Stack |
|---|---|---|
| ARC Presentation Assimilator | retired | Swift, SwiftUI, PDFKit, AVFoundation, AppleScript to PowerPoint and Keynote, LibreOffice headless, local HTTP control API |

## The job
I get a folder of presenter files and have to turn it into one thing the operator can play. By hand I open every deck, export or screenshot it, pull out embedded videos, convert odd codecs, note which slide each video belongs to, and merge it all in run order.

This app was my first attempt to run the whole pipeline in one window. CATALOG a folder, CONVERT each deck, ASSEMBLE a show deck with video clips.

## Why it is hard
- Slide order in a PowerPoint file is the slide ID list plus relationships, never the file numbers. I trusted file names and put speaker notes on the wrong slide in 48 of 832 pairs.
- Native PDF export flattens builds, transitions and media. An exported deck looks right and plays wrong.
- A motion classifier must be measured against a real corpus before it gates behaviour. My first cut flagged 10 of 43 decks as looping when none did.
- PowerPoint keeps state between files. A deck I called broken opened five times out of five after I restarted the app.
- Permission prompts arrive one at a time. Three runs died on three different prompts.
- PowerPoint's repair dialog has no window title. A watchdog that matches window names misses it. Match by button title.
- A fullscreen slideshow capture seizes a display. Started from the wrong place, it took over both of my monitors.
- Two entry points, a button and an API, can start the same run twice.

## What the machine does now
Nothing in production. I retired it. When it ran, it scanned a folder, sorted files by an `N.NN Speaker - Title` convention, flagged naming problems and non 16:9 decks, and inspected each PowerPoint file for embedded video. It converted decks to PDF through PowerPoint, Keynote or LibreOffice, extracted and transcoded embedded video, extracted text and speaker notes, and assembled one deck bundle with a manifest. It had a click inspector, a deck editor, audio slides, a run-of-show importer, a media database and a control API on its own port. About 4,000 lines of engine.

## What still needs a person
At the time, auditing the output. I reported a deck good and then found identical stills, a frozen GIF and a capture of the desktop in it.

Now nothing, because the work moved. The capture tool took the parts that survived review.

## Rebuilding it
Do not. Rebuild what it taught.

I assessed every feature against one sentence. A presenter clicks through a converted deck and does not notice. The app was sprawling before that core was right.

Four things moved into the capture tool. Speaker notes extraction, video transcoding to H.264, PDF items as pages, and the hand-off call to the player. I retired native export as the default path, the old fullscreen capturer, the catalog rules and the second control API. Natural file name sort is enough and naming belongs to intake. I parked the media database, the run-of-show import and the deck editor. The folder is the editor. Rename or remove a file and rebuild.

The process lessons outlived the code.
- One run has one owner and one go. Every entry point refuses if a run is busy.
- Map every permission before the run, with a write probe.
- Audit outputs before the human does. Flag identical consecutive pages with no clip.
- Isolate before blaming the input. Restart the app and retry once.
- Install through a gate that prints how many tests ran and refuses on a failure or a running app.
- No side effects on the operator's desk. Write only where the operator chose. Open no windows unasked.
- Stage it as a ladder. Tests, then a probe, then one deck, then the full run.
- Lay out by rule, never by constant. Raising a height constant fixed nothing twice.

# Building test shows that have the shape of real ones and none of their content

| Tool | Status | Stack |
|---|---|---|
| ARC Test Shows | working on the bench | Python (python-pptx and raw OOXML editing), ffmpeg, shell |

## The job
To test a slide capture tool and a slide player you need decks that behave like the ones presenters actually send. That means 149 click builds on one slide, a WMV that autoplays, a morph transition, a hidden slide in the middle, a looping kiosk deck, a two slide lightning talk. The only place those exist is in decks from past events, and those belong to the people who made them.

For a while I tested against real decks. Then I saw how much client content sat in test folders, screenshots and result files, and stopped.

## Why it is hard
- Hand made test decks are too clean. Real decks are built by many hands in many versions of the software, and the bugs live in that mess.
- Structure breaks a capture, not content. The animation timing tree, the transition element, the relationship to a media file, the container and codec of that media, the aspect of a picture. The structure has to survive while every word and image is replaced.
- Media has to be replaced like for like. A WMV with a WMV, a 4:3 still with a 4:3 still, a silent video with a silent video. Change the container and you have tested something else.
- Content hides everywhere. Document properties, chart data, speaker notes, alt text, embedded thumbnails, comments, file names inside the package. Replacing visible text is not enough.
- A test should be able to say what correct looks like without a person watching. So every replacement media file shows its own name, its facts, a running clock and a progress bar, with a white flash and a 1 kHz beep every 5 seconds. Sync is checkable by eye and by measurement.

## What the machine does now
`make_media.py` generates 37 self-describing files. H.264 at several lengths, silent, MOV, ProRes, HEVC, WMV, AVI, VP9, portrait, 4:3, 720p, 4K, a loop, narration audio in four formats, three GIFs and twelve stills.

`anonymize_deck.py` takes a source deck and a list of slides to keep and writes a deck with the same layouts, transitions, animation trees and media relationships, with all text replaced by a description of what the slide does, media swapped for generated files of the same container, stills of the same aspect, replaced chart data, scrubbed properties, and notes at three lengths.

`build_show.py` reads a show definition, picks the most varied slides from each source (keeping all 60 slides tests the same thing 50 times), runs the anonymizer, adds a linked-video deck and a schedule deck, and writes a manifest. `scan_residue.py` lists every string in a built show that is not from my own vocabulary. That scan is the gate before a show is called clean.

Two shows exist. One is a two day show with about twenty decks and dozens of videos. The other is three days and about twice the size, a few hundred slides, with keynotes, a panel and lunch loops. An assessment script ran the second show through capture on two machines and tabulated ready, failed and review counts per deck.

## What still needs a person
- Reading the residue scan. It only lists.
- The built shows and the source pool are not in the repository and never will be. The show definitions still point at source files by their original names, so the definitions themselves are not clean.
- Some embedded video excerpts come from public videos. They are third party and not redistributable.
- The plan to have a local language model operate a long soak test and triage the results is written, not built.

## Rebuilding it
Four tools. Media generator, anonymizer, show builder, residue scanner.

Decisions. Edit the package XML in place and keep the structure byte for byte where possible. Do not rebuild a deck through a high level library, because it normalizes the mess you want. Generate media that describes itself. Make the clean check a tool with a word list, not a promise. Keep sources local and commit only generators and definitions.

Traps. Thumbnails and document properties carry the old content. A chart's cached values are separate from its embedded workbook. Media file names inside the package can carry a person's name.

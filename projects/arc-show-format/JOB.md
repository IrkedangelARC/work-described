# Writing down what "a show" is so two programs agree

| Tool | Status | Stack |
|---|---|---|
| ARCShowFormat | working in the field | Swift package (Codable, Foundation), no dependencies |

## The job
One program prepares decks. Another plays them. A third logs what was on screen. Later an editing tool wants to know which slide was up at 14:03:07. Before this package each program had its own idea of a deck, a show folder and a log line, and they agreed only because I wrote them the same week.

By hand, this is the folder I build on a show laptop. Decks numbered in run order, music cues, a note of which display is program. After the show it is somebody scrubbing a camera recording to find when each slide changed.

## Why it is hard
- The writer and the reader ship on different days. A laptop in the field can have a new capture tool and an old player. The format has to be lenient on read. Unknown keys are dropped and missing keys get defaults.
- A strict enum is a trap. One unknown case fails the decode of the whole file, so a new item kind written by a newer tool makes an older player refuse the entire show. Kinds need a tolerant decode with an unknown fallback, and tests for it.
- A slide is not a page. Hidden slides have a hash and no page. Builds are states inside a page. A logo page has no source slide. The manifest must carry the mapping from page to source slide, or a revised deck cannot be matched to the old one.
- "Ready" has to mean something. A deck whose PDF opens but whose clips are missing will fail on air. Readiness is one shared function, so the writer and the player run the same check.
- A log for editing needs two clocks. Wall time for humans and for matching cameras, monotonic time for intervals, because wall clocks step. It must also survive a crash, so it is one JSON line per event, appended, with a small header file beside it.

## What the machine does now
The package defines six things.
- `DeckManifest` is the `manifest.json` inside an `.arcdeck`, versions 2 and 3. Each page has role, title, media, transition, builds with a clip and a still each, source slide number, notes.
- `ShowSpec` is `show.json` at the root of a show folder. Items in run order with status, versions and a per-slide hash ledger, the output profile, cues, and the folder skeleton (`decks/ arcdecks/ cues/ reports/ logs/ state/`).
- `DeckVerifier` checks that the PDF opens, the manifest parses, every clip exists and plays, and looks for orphans.
- `ShowLogCore` is a rotated text log with an in-memory ring and an error channel.
- `Rundown` holds sessions, speakers and durations for the timer, with a rule that recognizes rehearsal data so it never attaches to a real show.
- `SlideTrack` and its writer make a session folder with `header.json` and `track.jsonl`, recording what program showed and every click, on both clocks.

The capture tool writes the first two. The player reads them and writes the track. A menu bar logger on macOS and Windows writes the same track. My editing pipeline reads it.

## What still needs a person
- Deciding when a change is breaking. There is no version negotiation, only lenient decoding.
- Shipping the consumers together. Nothing enforces it.
- The Windows logger has its own C# copy of the track types. Keeping the two in step is manual.

## Rebuilding it
One Swift package, one target, no dependencies, consumed by path from each app. Plain `Codable` structs with custom decoding where leniency matters. A verifier that returns a list of problems, not a boolean. A writer that appends one line per event.

A show is a folder a person can read and repair in Finder. Versions of a captured deck are new files, never overwrites. Identity of a slide is a content hash of its source, with the hash of its predecessor, because a clip holds the transition in from the previous slide.

Do not add a required field. Do not make an enum exhaustive. Write a test that decodes a file from the future.

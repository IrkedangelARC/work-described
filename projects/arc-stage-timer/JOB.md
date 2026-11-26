# Keeping a day of talks on schedule from the back of the room

| Tool | Status | Stack |
|---|---|---|
| ARC Stage Timer | working in the field | Swift, SwiftUI (macOS and iPad), Network framework, server sent events, HTML and JS web display, Node (Bitfocus Companion module) |

## The job
A conference day is a list of sessions with start times and lengths. The speaker needs to see how long they have left. The producer needs to know if the day is running late. Someone at the back holds up cards, or runs a countdown on a spare laptop and resets it by hand at every change, while also doing audio or video.

When a speaker runs over, that person has to get their attention without the audience noticing.

## Why it is hard
- The agenda arrives as a document and I need data. Time ranges, titles and speaker names have to be pulled out of prose and tables.
- The clock on stage must be readable from 10 metres by someone who is mid sentence. Black ground, one big number, one colour of meaning. Console chrome on that screen is noise.
- The operator's needs are the opposite. I do not need a big timer. I need the cue list and small controls, on half a laptop screen, beside everything else I am running.
- Schedules slip. A 20 minute overrun at 10 am has to be absorbed somewhere. I need to see ahead or behind at a glance and compress later cues deliberately.
- Displays move. A laptop with two outputs renumbers them on every replug. The screen with keyboard focus is not the primary screen. A window sent to "display 2" lands on the projector.

## What the machine does now
- Stores shows as ordered cues with title, subtitle, speakers, format, planned times, and warning and danger thresholds.
- Imports a run of show from JSON or parses a pasted agenda or document into cues. A full cue editor covers every field.
- Runs a countdown per cue with green, yellow, red and overtime states, auto advance, single step undo, and a schedule offset that reads on time, ahead, behind or way behind.
- Drives a confidence monitor output with five layouts, now and next labels, a progress bar with zone ticks, and messages shown as a band across the middle.
- Serves a web stage display that follows the app live over server sent events, so any tablet or browser on the network is a clock.
- Sends preset messages, typed alerts and an attention flash.
- Has two console modes. Program is a half screen window with the cue list. Operate is a small floating widget.
- Places windows by display UUID, name or index, remembers the UUID, and never takes the primary display unless told to. It can run headless with the HTTP API as the console.
- Ships a Companion module, and a script that makes the app drive itself and photograph every screen for review.

## What still needs a person
Reading the agenda import against the real agenda. Deciding where to recover lost time. Deciding when to flash a speaker.

Some things are still open. The standalone layout and the cue list sidebar still carry the old design. I did not recheck the iPad layouts after the console rebuild. The API port collides with another of my apps.

## Rebuilding it
A timer engine that owns state and cues. A stage display state object derived from it. Output windows that only read that state. An HTTP server that maps routes onto the same engine calls the buttons use, plus an event stream for the web page.

Use one code base for Mac and iPad, with hardware output code compiled only on the Mac. Open every output through one idempotent function, and sweep restored duplicates at placement. Name displays by UUID because it survives a reboot and a cable swap.

The focused screen is not the primary screen. The primary is the menu bar screen. A headless run must not persist window state, or the next normal launch has no window. Test the GUI by launching the app bundle and never the binary inside it.

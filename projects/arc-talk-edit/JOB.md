# Turning a recorded talk into a finished edit, from drives to delivery

| Tool | Status | Stack |
|---|---|---|
| ARC Edit (arc-talk-edit) | partial | Python (numpy, PyYAML, OpenCV, torch for the classroom chain), ffmpeg, DaVinci Resolve Studio scripting API, mlx-whisper |

## The job
After a talk I come home with drives from several recorders. A multi input ISO deck, single channel recorders with more cameras and the laptop feed, and a multitrack card from the audio console. None share a clock. I used to line them up by ear in DaVinci Resolve, check which files had sound, cut the dead mic waits, choose shots, grade, render, measure loudness and upload. Usually overnight, because the client wants it in a day or two.

Every job I rewrote the same forty scripts with new numbers pasted in. This tool moves the numbers into one job file.

## Why it is hard
- Nothing can be trusted by label. Recorder clocks are unset, and a file marked as program audio can be silence. Every channel has to be measured.
- Sync has to be frame exact across devices that drift. Audio cross correlation works, but two inputs on one recorder can differ by a frame of embedded audio delay, and a slide feed synced to a camera's view of the screen is wrong by the projector latency (159 ms in one room).
- 59.94 timelines count non drop timecode at 60, so displayed timecode runs about 3.6 seconds per hour ahead of elapsed time. Transcript times are elapsed.
- The Resolve API has no razor, appends by source frames, leaves one frame gaps with mixed frame rates, and returns False silently for a LUT path in the wrong form.
- A render that reports Complete can be wrong. No loudness chain, or no index in the file because the disk filled.
- Hand edits are the authority. A rebuild that runs over them destroys trust in the tool.

## What the machine does now
One `job.yaml` holds sources, roles, clock offsets, frame rate, program in and out and LUTs, each number with a note on where it was measured. A stage runner caches each stage by hashing its code, job keys and input files.

- `ingest` probes every file, names the recorder from metadata, and measures every audio channel as dead, live or program.
- `sync` cross correlates each source against one reference at anchors every ten minutes, reports drift, and proposes clocks.
- `transcribe` makes a word timed transcript, with pauses from silence detection.
- `scans` finds screen feed dropouts, camera whips, faces, and when an audience camera settled.
- `stack` builds a sync stack timeline, one track per source.
- Two program engines (slides talk, screen share talk) turn transcript and scans into a shot list, and reproduce two delivered programs exactly.
- `v1` builds a timeline where each camera piece is a Take Selector clip holding every synced angle, with joins, transforms and per camera Input LUTs.
- A classroom chain takes unattended room recordings and renders a presenter column that picks the best camera, frames like an operator, and cuts to the audience for questions.
- QC tools. Upstream clipping check against a clean iso, measured finish LUT, tracked face windows, timeline snapshot and diff.

It only creates new timelines. Media drives are read only.

## What still needs a person
Reviewing the first cut and switching takes. Grade sign off. Picking audio options by ear. Content cuts that change what a speaker said. Every client send. Open in code. The two program engines are not unified, and the review loop and delivery are still per job scripts.

## Rebuilding it
Start with the time maps. One module converts between recorder clocks, the reference clock, record frames and timecode, with tests pinned to frames read back from real timelines. Use stacked tracks, not multicam clips, so placement is integer frame arithmetic. Keep the old per job scripts byte identical beside the package, then replace them stage by stage against golden outputs from delivered jobs. Carry colour as a Media Pool Input LUT, because it follows the take. LUTs must live in the system LUT folder. Verify by exporting stills and measuring. Put a loudness assert and an ffprobe of the master in the render step.

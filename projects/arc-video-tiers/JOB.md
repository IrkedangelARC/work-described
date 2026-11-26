# Showing a client what each level of recording actually buys

| Tool | Status | Stack |
|---|---|---|
| ARC Video Tiers reel builder | partial | Python (Pillow, numpy), ffmpeg, DaVinci Resolve Studio scripting API, mlx-whisper |

## The job
A venue's event staff ask "can you record it" and mean six different things. Nothing recorded. The one file the room already makes. One camera and the slides side by side. Every room camera on its own track, unoperated. Every camera, the screen and every mic on its own track with operators. A live switched, streamed, edited show. I used to explain the difference in emails and on site, and the misunderstanding surfaced after the event, when the deliverable was not what they pictured.

I cut a short internal video from my own past recordings. Each tier gets a grid of what is recorded, then what the client receives. By hand in an editor that is two days per version, and I wanted a version per show.

## Why it is hard
- The footage is the argument. Each tier needs a real past show that fits it, with a window of twenty to thirty seconds that starts and ends on a sentence. Finding those across dozens of shows on several drives is most of the work.
- A multiview grid must show one instant. Every cell has to be synced, and the sources came from different recorders with different clocks.
- Resolve's scripted transitions cannot do a held, directional wipe, which is the whole point of a raw against graded demo.
- Cutting a speaker mid sentence makes a demo reel look careless. A pause threshold of 0.7 s split conversational panel speech in the wrong place and 1.2 s did not.
- A grade demo exposes bad grades. A split tone that does not fade to zero at true black turned blacks navy. A skin protect band reached dark hair and tinted it red. I dropped a cinematic look I built because it looked bad.
- An audio A/B is only honest if both halves are loudness matched and the "raw" really is raw.
- Resolve caches clips by path. Rebuilding a segment under the same name shows the stale one.

## What the machine does now
A version is one JSON spec of beats per tier or per section, each a clip, grid, cut sequence, side by side, grade wipe or audio A/B, with sources and times. A graphics script draws lower thirds, title and closing card build layers, and corner tags as PNGs from the brand file. A segment builder renders every beat with ffmpeg as frame exact ProRes at 1080p59.94, including grids, held wipes through LUTs and A/B audio. A sentence snapper transcribes around each speech beat and moves its start and end to sentence boundaries, shifting every layer by the same delta so sync holds. A checker prints a beat sheet with loudness. An assembler creates a new Resolve timeline, renders H.264, runs a two pass -14 LUFS chain and asserts it. A verifier compares frames at several points against the segments and checks audio sync by cross correlation.

The same builder later made stand alone show feature reels with equipment and staffing panels. Tools born here (upstream clipping check, measured finish LUT, tracked face windows) moved into my edit pipeline.

## What still needs a person
Choosing which shows may be shown and which moments flatter the work. Picking the look. Wording the cards. Approving every version before anyone outside sees it. I am still revising the tier ladder itself, and the top tier is short of footage because few of my recordings include a live switched program.

## Rebuilding it
Pre-render in ffmpeg, assemble in Resolve. Treat the editor as a conform and render stage and keep everything hard (wipes, grids, sync) in deterministic segments you can check frame by frame. Drive it from one spec file per version. Give each build its own segment directory. Snap to sentences before building, and re-render any pre-rendered layer whose window moved. Check free disk before long renders. Never kill a script in the middle of a Resolve call. It deadlocks the scripting bridge.

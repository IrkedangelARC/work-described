# Rescuing a broken recording, grabbing a video, numbering the decks

| Tool | Status | Stack |
|---|---|---|
| ARC media tools (ProRes Rescue, ARC Video Grabber, Presentation Renamer, PowerPoint Combiner, conversion presets) | working in the field | Python (tkinter, numpy, python-pptx, yt-dlp), ffmpeg, PyInstaller |

## The job
A show has chores that are too small for a product and too frequent to do by hand. A presenter emails a link the morning of and wants that video in their slides. Twenty decks arrive named "final_v3_REAL" and have to be renamed to the agenda order, 1.00, 1.01, 1.02. A session wants one combined deck. A camera file has to become something a client can stream. Once, a drive failed and left interview recordings that no player would open.

Each of these used to be ten minutes of clicking, repeated, under show day pressure. Each is now a small script, some with a window so a tech can run them.

## Why it is hard
- The rescue is the real one. A ProRes .mov with its header and index gone is just a stream of bytes. The frames are still there, each starting with a four byte size and the tag `icpf`, so they can be walked exactly. Everything between frames is audio, but the layout depends on the recorder. One writer puts a PCM chunk after every 30 frames, 24,024 samples at 48 kHz for 59.94, with 40 samples of look ahead duplicated from the next chunk. Another writes 16 planar slots per chunk, only four carrying sound, and chunks that do not line up with frame groups at all.
- Whether an audio chunk belongs to the frames before or after it cannot be read from the file. I measured it with mouth motion against the voice envelope over thousands of frames. One order put lips 0.12 s ahead of sound, which is speech. The other put them 0.38 s behind, which is impossible.
- Video download tools break when sites change, and without ffmpeg they silently fall back to low quality. Techs do not read terminals.
- Combining decks loses formatting unless each slide keeps its source layout. Embedded media and fonts are where it goes wrong.
- Deck names from presenters carry no order. The agenda does.

## What the machine does now
ProRes Rescue walks a damaged file, drops the partial first and last frames, writes a video only .mov with a fresh index, writes the audio to WAV, and muxes both with ffmpeg without re-encoding. It has two measured layouts, an option for audio order, and a short test build mode. The source is only read.

ARC Video Grabber is a windowed downloader over yt-dlp with quality choices, threaded progress, ffmpeg detection, and a packaged app build. Presentation Renamer takes a pasted agenda and a folder and renames decks to agenda numbers. PowerPoint Combiner merges numbered decks into one session deck. A preset library holds four web conversion presets (balanced, fast, quality, low bandwidth) shared with the client viewing tool.

## What still needs a person
Checking a rescued file by eye and ear before trusting it, and re-measuring the audio order for any new recorder. Confirming the presenter has rights to the video they asked for. Opening every combined deck and clicking through it, because a merge that looks fine can drop a video. The renamer's matching of file to agenda item needs a human glance. The preset library is half built. Only the presets module exists. The conversion wrappers in its readme do not.

## Rebuilding it
For the rescue, read the file once, scan for the frame tag, trust the size field, and collect the gaps as audio. Derive the chunk maths from the frame rate (1001 times 24 samples per 30 frames at 59.94). Build a short test first and prove sync with a measurement, not a guess. For the windowed tools, plain tkinter and one file each, with the launcher a double click file. Detect ffmpeg in the common install paths and say plainly when it is missing. Keep these separate. They do not want a framework.

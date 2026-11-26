# Playing twenty decks in a row without merging them into one file

| Tool | Status | Stack |
|---|---|---|
| CueStack | working on the bench | Python, LibreOffice headless, Poppler, pdf2image, pygame |

## The job
At a conference with several sessions and a couple dozen speakers, the slide operator gets a folder of decks. Some arrive the week before, some on a thumb drive four minutes before the talk. The old way was to open PowerPoint and paste every deck into one combined file per session, in agenda order, so the operator could press one button all day and never show a desktop to the audience.

I did that by hand for years. For one conference the combined files ran to gigabytes. Every late revision meant opening the monster, finding the old slides, deleting them and pasting the new ones while the previous speaker was still talking.

## Why it is hard
- Merging changes the decks. Pasting slides into another file pulls in a different master, different fonts and different aspect ratios. A speaker's layout shifts and they notice from the stage.
- Late swaps are the norm. The operator needs to replace one talk without touching the others.
- Formats are mixed. PowerPoint, PDF, Keynote, OpenDocument and old .ppt files show up in the same folder.
- Duplicates hide in the folder. The same talk arrives as both PDF and PPTX, or appears in two session subfolders. Old hand built combined decks sit beside the originals and must not be played.
- Between two decks the audience must never see an application, a file picker or a desktop.

## What the machine does now
- `ingest` scans a show folder. Top level files come first as hold slides, then each subfolder is a session in natural sort order, then files inside it in natural sort order. It writes a show file in JSON with one cue per deck. It skips files whose name marks them as hand combined decks.
- `render` converts each cue on its own. PDFs go straight to images through Poppler at 200 dpi, which is about 1920 by 1080 for a standard slide. Office and Keynote formats go through LibreOffice headless to PDF first, with a 120 second timeout per file. Each cue gets its own folder of PNG slides. Already rendered cues are skipped unless forced, so a replaced deck re-renders alone.
- `play` opens a fullscreen pygame window on the chosen display. Right, space or page down is next slide. Left or page up is previous. Up and down jump between cues. Home and end jump within a cue. B and W blank to black or white. F toggles fullscreen. Advancing past the last slide of a cue rolls into the next cue.
- The player caches the current cue's images and preloads the next one, with a small eviction limit.
- Source files are never modified.

On a real conference folder it rendered every cue and a few hundred slides with zero errors.

## What still needs a person
Agenda order when the folder names do not carry it. Picking between duplicate versions of a talk. Checking each rendered deck by eye, because LibreOffice does not render every PowerPoint the way PowerPoint does. Fonts substitute and some layouts move.

The large limit is by design. Slides become still images. Builds, animations, transitions, embedded video and audio are all lost. There is no presenter view, no notes, no confidence monitor and no operator preview window yet. I moved on to tools that capture decks from the real presentation apps, and this stays as the simple version of the idea.

## Rebuilding it
Three stages with a JSON show file between them. Ingest, render, play. Keep them separate so a late deck only re-runs render for one cue. Render every deck independently into its own folder keyed by cue id. Preload the next cue so the boundary between two speakers costs nothing.

Traps. The player needs a real display session and will not launch from a sandboxed subprocess. Render fidelity is the weak link, so if exact slides matter, export PDF or images from the native app instead.

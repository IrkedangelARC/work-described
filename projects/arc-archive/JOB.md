# Keeping years of show recordings without keeping every raw byte

| Tool | Status | Stack |
|---|---|---|
| ARC Archive (archive encode, verified moves, Drive uploader, client viewer) | working in the field | Python, bash, ffmpeg (VideoToolbox), Google Drive API, launchd, ssh |

## The job
Every recorded show leaves 200 GB to 2 TB of ProRes and DNxHD ISOs, camera cards and multitracks on a fast SSD. The next show needs that SSD. For years I dragged folders to a big slow drive in Finder, hoped the copy was good, and deleted the source when I ran low. Client review copies were the same. I uploaded a huge file and found the web player stuck at 360p the next day.

Three tools grew out of that. A converter and uploader for a cloud archive. A small convert and share tool for client viewing. An archive encoder with verified moves between local drives, the one I rely on now.

## Why it is hard
- Raw is too big to keep and too valuable to lose. I re-encode to the deliverable spec, so an edit from the archive shows no visible difference. My first converter used CRF 23 at 30 fps, which threw away the native 59.94. I replaced it.
- A finished copy is not verified. A file re-read right after writing comes from the page cache and skips the disk. Verify after enough other data has pushed it out.
- An encode can exit zero and be short, or silent on a track. Verification has to decode the whole file and compare duration and every audio stream.
- H.264 has no alpha. A matte or overlay encoded that way is destroyed. Those must copy as is.
- Recorders write odd tags. One marks primaries as reserved and current scalers reject it. A clean aperture atom crops 1920 to 1888 unless disabled.
- Camera MOVs keep their index at the end, so they cannot be piped to a second machine as is.
- Deleting is the only irreversible step. It must depend on a verified manifest line and my approval.
- Cloud players build previews reliably for modest H.264 and often not for 10 GB HEVC. ffmpeg without `-nostdin` in a loop eats the file list.
- Naive walkers skip symlinks silently.

## What the machine does now
The archive encoder walks a list of source and destination pairs and classifies each video. Raw codecs, anything wider than 1920, and H.264 above 40 Mbps get encoded. Everything else copies byte for byte. The encode is H.264 High, 1920 wide, native frame rate, 8 bit 4:2:0, 28 Mbps, Rec.709 tags, AAC 48 kHz at 160k per channel, every audio stream kept, faststart, named with an ARCHIVE prefix. Each result gets a full decode check, duration within 0.1 s, and stream and channel counts compared, then a manifest line. Existing destinations are verified and skipped, never overwritten. Several runs share one queue through claim files, and a second machine can encode over ssh with the source remuxed to NUT on a pipe. A separate script deletes a raw file only when its manifest entry is verified and sizes still match, and skips anything with alpha.

Move scripts copy via a temp name, hash the source while copying, re-read every destination later, and delete only verified files.

The older cloud path downloads from a shared folder, converts, uploads, compares MD5 with the Drive API, and writes a metadata mirror. The client viewer converts with four presets and shares a dated folder.

## What still needs a person
Deciding what is raw and what is a final. Approving every delete rule. Plugging in drives. Judging a drive that stalls or tests as counterfeit. Source lists are hard coded per run. The cloud converter is superseded but not removed.

## Rebuilding it
Classify, encode or copy, verify, log, and keep delete as a separate program that reads the log. Use hardware H.264 at a fixed bitrate equal to your deliverable. Write to a temp name and rename. Make reruns safe by verifying what exists. Use claim files and no queue server. Test one file into scratch before any long run.

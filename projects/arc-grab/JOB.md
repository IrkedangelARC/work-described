# Getting the video a client embedded on a web page

| Tool | Status | Stack |
|---|---|---|
| ARC Grab | working in the field | Swift, SwiftUI, yt-dlp, ffmpeg (VideoToolbox), whisper.cpp |

## The job
A presenter's deck says "play this video" and there is no file. The video is a player embedded on a web page. Vimeo, Wistia, Brightcove, JW Player, Kaltura, Panopto, a Zoom cloud recording, YouTube, or a bare HLS manifest. Playing it live from a browser at a show means buffering, ads, a login prompt or venue Wi-Fi in front of an audience. So before the show somebody gets a local copy and turns it into something the playback machine and the editor will take. That was me with a paid converter capped at 1080p, plus a terminal.

## Why it is hard
- Each host breaks differently. A Vimeo page link now demands a login even for a public video, while the player endpoint that every embed uses does not. Domain locked embeds need the referring page. Some hosts need a password or cookies from a logged in browser. Unknown hosts return a 403 unless the request imitates a browser.
- The download engine goes stale. When a site changes, an old extractor fails with a 403, and the fix is an engine update, not a retry.
- Show laptops have no Homebrew, no Python, no pip. Everything has to be in the app, signed and notarized.
- The single file build of the engine re-extracts itself on every run and gets rescanned by the OS. 8 to 13 seconds per start. The directory build starts in 0.2 seconds.
- Best quality streams are VP9 or AV1 with separate audio. An editor wants ProRes or DNxHR with 48 kHz PCM. A playback machine wants H.264.
- Whisper repeats a phrase thousands of times across silence unless context carry is off and a voice activity detector gates it.

## What the machine does now
Paste a page, a player URL, a playlist or a manifest. Each video becomes a queue row that names the site. It downloads the best streams and delivers MP4 H.264 (reusing the site's own H.264 when it exists, hardware encoding only when it does not), ProRes 422, ProRes HQ or DNxHR HQ, or audio as WAV 48 kHz 24 bit, M4A or MP3. It trims IN to OUT, fetches subtitles and chapters, runs up to three jobs in parallel, checks free space, and removes partial files on cancel. A failure is one line and one action, such as LOG IN THEN COOKIES, SET REFERER or TRY UPDATE ENGINE. The engine is seeded into Application Support, updated on a button, verified before an atomic swap, and never downgraded. An optional transcript pass writes an .srt and a paragraphed .txt. A ten minute talk takes about 15 seconds on a desktop Apple Silicon machine. A headless mode exposes every control on the command line with one result line per job, so my other apps call it.

## What still needs a person
Having the right to the video. Logging into the site in a browser when cookies are needed. Knowing the password or the page an embed lives on. DRM protected streams are refused and stay refused. Sites rate limit, so a big batch needs pacing. Anyone who redistributes a build must first confirm the license terms of the bundled ffmpeg configuration.

## Rebuilding it
A SwiftUI front end that never downloads anything itself. It builds argument lists for child processes and parses their progress. Keep the command builder, progress parser and error mapper as pure, tested functions. Bundle a static arm64 ffmpeg and ffprobe with hardware encoders, the engine as a directory, and the whisper command line tool. Sign every Mach-O inside out with hardened runtime, then notarize the whole app. Keep a managed copy of the engine outside the bundle so it can update without breaking the signature. Fetch speech models on first use with byte count gates, so an error page never passes as a model. The transcript pipeline is ffmpeg to 16 kHz mono WAV, whisper with zero text context plus VAD, then a pause aware paragrapher (0.8 s soft break, 2.0 s hard break, length caps).

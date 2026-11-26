//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation

/// Pure argument builders for yt-dlp and ffmpeg. No process launches here, so
/// every selector and flag can be unit-tested as a string.
enum CommandBuilder {
    static let progressTag = "ARCP"
    static let fileTag = "ARCFILE"

    /// youtube.com, youtu.be and their subdomains: the one site whose links need the app's own reading.
    static func isYouTubeHost(_ url: String) -> Bool {
        guard let host = URL(string: url)?.host?.lowercased() else { return false }
        return host == "youtu.be" || host.hasSuffix(".youtu.be") || host == "youtube.com" || host.hasSuffix(".youtube.com")
    }

    /// YouTube only: a bare playlist link expands; a watch link that also carries &list= is treated as the
    /// single video (what the person clicked, not the whole list). Every other site is left to yt-dlp,
    /// whose `_type` says whether a link is one video or a set (a Vimeo showcase, a Drive folder).
    static func isPlaylistURL(_ url: String) -> Bool {
        guard isYouTubeHost(url) else { return false }
        let u = url.lowercased()
        if u.contains("/playlist?") { return true }
        if u.contains("list=") && !u.contains("watch?v=") && !u.contains("youtu.be/") { return true }
        return false
    }

    /// The analysis pass. The URL is what EmbedRules makes of the pasted link, and the embed's own needs
    /// (referer, password, impersonation) apply here too, or the analysis fails where the download would not.
    static func analyzeArgs(url raw: String, options o: GrabOptions) -> [String] {
        let url = EmbedRules.normalize(raw)
        var a = ["-J", "--no-warnings", "--flat-playlist", "--ignore-config"]
        if isYouTubeHost(url) && !isPlaylistURL(url) { a.append("--no-playlist") }
        a += cookieArgs(o.cookies)
        a += EmbedRules.extraArgs(url: url, referer: o.referer, password: o.videoPassword)
        a.append(url)
        return a
    }

    static func cookieArgs(_ c: CookieSource) -> [String] {
        c == .none ? [] : ["--cookies-from-browser", c.rawValue]
    }

    /// yt-dlp format selector. Video: best streams under the height cap, with
    /// an H.264 + AAC preference for the MP4 target so that most downloads
    /// need no conform at all. Audio: best audio stream.
    static func formatSelector(_ o: GrabOptions) -> String {
        // A trimmed audio grab re-encodes the section at the cuts; the bundled ffmpeg encodes AAC but has only
        // the experimental native Vorbis/Opus encoders (exit 88 on a WebM source, 2026-09-26): take M4A.
        if o.mode == .audio { return o.hasSection ? "ba[ext=m4a]/ba/b" : "ba/b" }
        let h = o.quality.maxHeight.map { "[height<=\($0)]" } ?? ""
        switch o.videoFormat {
        case .mp4:
            return "bv*[vcodec^=avc1]\(h)+ba[acodec^=mp4a]/bv*\(h)+ba/b\(h)"
        case .original, .prores422, .prores422HQ, .dnxhrHQ:
            return "bv*\(h)+ba/b\(h)"
        }
    }

    /// How many streams the download is (drives the phases of the progress bar). Audio is one. Video is two
    /// when the site serves video-only streams to merge (YouTube DASH), one when every format carries its
    /// own audio (Vimeo progressive, a direct file): those used to sit at 50 % and jump.
    static func expectedStreams(_ o: GrabOptions, info: MediaInfo? = nil) -> Int {
        if o.mode == .audio { return 1 }
        return info?.singleStream == true ? 1 : 2
    }

    /// "*IN-OUT" for --download-sections, nil when no trim is set.
    static func sectionSpec(_ o: GrabOptions) -> String? {
        let i = o.sectionIn.trimmingCharacters(in: .whitespaces)
        let e = o.sectionOut.trimmingCharacters(in: .whitespaces)
        if i.isEmpty && e.isEmpty { return nil }
        return "*\(i.isEmpty ? "0" : i)-\(e.isEmpty ? "inf" : e)"
    }

    /// English only, named. NOT "en.*": that also matches every "English from <language>" machine translation
    /// YouTube lists (en-de, en-fr, …), one request each, and the burst ends in HTTP 429 and a FAILED grab
    /// (measured 2026-09-26).
    static let subLangs = "en,en-US,en-GB,en-orig"

    /// Exact cuts re-encode the section, which every target does anyway except ORIGINAL. ORIGINAL promises
    /// the source bitstream (and the bundle has no AV1/VP9/Opus encoders: a forced re-encode came back
    /// mpeg4 + ac3, 2026-09-26), so it cuts on keyframes and may run up to one GOP long.
    static func forcesKeyframes(_ o: GrabOptions) -> Bool {
        !(o.mode == .video && o.videoFormat == .original)
    }

    /// yt-dlp's in-progress names: .part/.ytdl, merge temps, and per-format streams ("Title [id].f137.mp4").
    static func isTempName(_ n: String) -> Bool {
        n.hasSuffix(".part") || n.hasSuffix(".ytdl") || n.hasSuffix(".temp.mkv") || n.hasSuffix(".temp.mp4")
            || n.range(of: #"\]\.f\d+\."#, options: .regularExpression) != nil
    }

    static func outputTemplate(destination: String) -> String {
        "\(destination)/%(title).150B [%(id)s].%(ext)s"
    }

    static func downloadArgs(url raw: String, options o: GrabOptions, ffmpegDir: String) -> [String] {
        let url = EmbedRules.normalize(raw)
        var a: [String] = [
            "--no-warnings", "--ignore-config", "--newline", "--progress", "--no-quiet",
            "--no-playlist", "--no-mtime", "--no-overwrites",
            "--retries", "10", "--fragment-retries", "10", "-N", "4",
            "--ffmpeg-location", ffmpegDir,
            "-f", formatSelector(o),
            "-o", outputTemplate(destination: o.destination),
            "--progress-template",
            "download:\(progressTag)|%(progress.status)s|%(progress.downloaded_bytes)s|%(progress.total_bytes)s|%(progress.total_bytes_estimate)s|%(progress.speed)s|%(progress.eta)s",
            "--print", "after_move:\(fileTag)|%(filepath)s",
        ]
        switch o.mode {
        case .video:
            a += ["--merge-output-format", o.videoFormat.mergeContainer]
            if o.chapters { a.append("--embed-chapters") }
        case .audio:
            switch o.audioFormat {
            case .wav48: break // conform step makes the 48 kHz / 24-bit WAV
            case .m4a: a += ["-x", "--audio-format", "m4a", "--audio-quality", "0"]
            case .mp3: a += ["-x", "--audio-format", "mp3", "--audio-quality", "0"]
            }
        }
        if o.subtitles {
            a += ["--write-subs", "--write-auto-subs", "--sub-langs", subLangs, "--convert-subs", "srt"]
        }
        if o.thumbnail { a += ["--write-thumbnail", "--convert-thumbnails", "jpg"] }
        if let s = sectionSpec(o) {
            a += ["--download-sections", s]
            if forcesKeyframes(o) { a.append("--force-keyframes-at-cuts") }
        }
        a += cookieArgs(o.cookies)
        a += EmbedRules.extraArgs(url: url, referer: o.referer, password: o.videoPassword)
        a.append(url)
        return a
    }

    /// whisper.cpp wants 16 kHz mono PCM; ffmpeg makes it from any delivered file.
    static func whisperWavArgs(input: String, output: String) -> [String] {
        ["-y", "-hide_banner", "-nostats", "-loglevel", "error", "-progress", "pipe:1", "-i", input,
         "-vn", "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", output]
    }

    /// whisper-cli pass. `-mc 0` keeps no text context between windows (the
    /// whisper loop-on-silence failure feeds on it) and Silero VAD skips the
    /// silence outright; both are the proven faster-whisper recipe carried
    /// over. Language auto-detected. Only the SRT is asked for; the .txt is
    /// paragraphed by Transcript from the SRT timings.
    static func whisperArgs(model: String, vadModel: String?, input: String, outputBase: String, threads: Int) -> [String] {
        var a = ["-m", model, "-f", input, "-l", "auto", "-t", "\(max(1, threads))", "-mc", "0",
                 "-pp", "-np", "-osrt", "-of", outputBase]
        if let v = vadModel { a += ["--vad", "-vm", v] }
        return a
    }

    static func probeArgs(input: String) -> [String] {
        ["-v", "error",
         "-show_entries", "stream=codec_type,codec_name,width,height,pix_fmt:format=duration",
         "-of", "json", input]
    }

    /// ffmpeg conform. Progress goes to stdout as key=value lines (-progress pipe:1).
    static func conformArgs(input: String, output: String, options o: GrabOptions) -> [String] {
        var a = ["-y", "-hide_banner", "-nostats", "-loglevel", "error", "-progress", "pipe:1", "-i", input]
        switch o.mode {
        case .audio:
            a += ["-vn", "-c:a", "pcm_s24le", "-ar", "48000"]
        case .video:
            a += ["-map", "0:v:0", "-map", "0:a:0?", "-map_metadata", "0", "-map_chapters", "0"]
            switch o.videoFormat {
            case .prores422:
                a += ["-c:v", "prores_videotoolbox", "-profile:v", "2", "-pix_fmt", "p210le"]
                a += ["-c:a", "pcm_s24le", "-ar", "48000"]
            case .prores422HQ:
                a += ["-c:v", "prores_videotoolbox", "-profile:v", "3", "-pix_fmt", "p210le"]
                a += ["-c:a", "pcm_s24le", "-ar", "48000"]
            case .dnxhrHQ:
                a += ["-c:v", "dnxhd", "-profile:v", "dnxhr_hq", "-pix_fmt", "yuv422p"]
                a += ["-c:a", "pcm_s24le", "-ar", "48000"]
            case .mp4:
                a += ["-c:v", "h264_videotoolbox", "-q:v", "70", "-pix_fmt", "yuv420p",
                      "-c:a", "aac", "-b:a", "256k", "-movflags", "+faststart"]
            case .original:
                a += ["-c", "copy"]
            }
        }
        a.append(output)
        return a
    }
}

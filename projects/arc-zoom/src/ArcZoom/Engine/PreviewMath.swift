//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation
import VideoToolbox
import Accelerate

// The PREVIEW module's arithmetic, pure and tested (PreviewTests): the I420 frames the raw share source
// sends, the audio packing, the frame and audio timing, the transport's state machine, and the ffmpeg
// locate / plan / progress parsing. Nothing here touches AVFoundation, the SDK or the file system except
// through what it is handed, so every line can be checked without a meeting (2026-09-24, the operator: "share
// video file has no way to play?").

// MARK: - I420 (what ZoomSDKShareSender.sendShareFrame takes)

/// Zoom's raw share source takes ONE contiguous I420 buffer: the Y plane (w x h), then U (w/2 x h/2), then V,
/// no padding, even width and height (ZoomSDKRawDataShareSourceController.h, ZoomSDKFrameDataFormat_I420_*).
enum I420 {
    static func byteCount(width: Int, height: Int) -> Int { width * height + 2 * (width / 2) * (height / 2) }

    /// The share size for a picture: the natural size fitted inside `limit` (aspect kept, never upscaled),
    /// rounded DOWN to even numbers (I420 halves both). A 1919 x 1079 source gives 1918 x 1078.
    static func shareSize(natural: CGSize, limit: CGSize = CGSize(width: 1920, height: 1080)) -> (width: Int, height: Int) {
        guard natural.width >= 2, natural.height >= 2 else { return (2, 2) }
        let k = min(1, limit.width / natural.width, limit.height / natural.height)
        let w = Int((natural.width * k).rounded(.down)) & ~1, h = Int((natural.height * k).rounded(.down)) & ~1
        return (max(2, w), max(2, h))
    }

    /// NV12 / '420v' (what AVPlayerItemVideoOutput hands back: Y plane + interleaved CbCr plane) to I420.
    /// The Y rows are copied without their stride padding; the CbCr pairs are split into U and V. Same range
    /// in and out: video-range NV12 is sent as I420_Limited, full-range as I420_Full.
    static func fromNV12(y: UnsafePointer<UInt8>, yStride: Int, uv: UnsafePointer<UInt8>, uvStride: Int,
                         width: Int, height: Int, into out: UnsafeMutablePointer<UInt8>) {
        let w = width & ~1, h = height & ~1, cw = w / 2, ch = h / 2
        for row in 0..<h { (out + row * w).update(from: y + row * yStride, count: w) }
        let uOut = out + w * h, vOut = uOut + cw * ch
        // vImage splits the interleaved pairs at full speed in a Debug build too (a Swift loop at -Onone was
        // ~5 ms a 1080p frame, and the live test runs the Debug build). Two channels, 2-byte stride.
        var dU = vImage_Buffer(data: uOut, height: vImagePixelCount(ch), width: vImagePixelCount(cw), rowBytes: cw)
        var dV = vImage_Buffer(data: vOut, height: vImagePixelCount(ch), width: vImagePixelCount(cw), rowBytes: cw)
        var chans: [UnsafeRawPointer?] = [UnsafeRawPointer(uv), UnsafeRawPointer(uv + 1)]
        let ok: Bool = withUnsafePointer(to: &dU) { pu in
            withUnsafePointer(to: &dV) { pv in
                var dsts: [UnsafePointer<vImage_Buffer>?] = [pu, pv]
                return chans.withUnsafeMutableBufferPointer { cp in
                    dsts.withUnsafeMutableBufferPointer { dp in
                        vImageConvert_ChunkyToPlanar8(cp.baseAddress!, dp.baseAddress!, 2, 2, vImagePixelCount(cw), vImagePixelCount(ch), uvStride, vImage_Flags(kvImageNoFlags)) == kvImageNoError
                    }
                }
            }
        }
        if !ok {
            for r in 0..<ch {
                let line = uv + r * uvStride
                for c in 0..<cw { uOut[r * cw + c] = line[2 * c]; vOut[r * cw + c] = line[2 * c + 1] }
            }
        }
    }

    /// BGRA (little-endian 32-bit, the capture default) to I420, BT.709, VIDEO range (Y 16...235, C 16...240),
    /// chroma the average of each 2 x 2 block. The reference conversion: solid white is (235, 128, 128),
    /// black (16, 128, 128), pure red (63, 102, 240) per BT.709.
    static func fromBGRA(_ src: UnsafePointer<UInt8>, stride: Int, width: Int, height: Int, into out: UnsafeMutablePointer<UInt8>) {
        let w = width & ~1, h = height & ~1, cw = w / 2
        let uOut = out + w * h, vOut = uOut + cw * (h / 2)
        @inline(__always) func rgb(_ x: Int, _ y: Int) -> (Double, Double, Double) {
            let p = src + y * stride + x * 4
            return (Double(p[2]) / 255, Double(p[1]) / 255, Double(p[0]) / 255)
        }
        for y in 0..<h {
            for x in 0..<w {
                let (r, g, b) = rgb(x, y)
                out[y * w + x] = UInt8(clamping: Int((16 + 219 * (0.2126 * r + 0.7152 * g + 0.0722 * b)).rounded()))
            }
        }
        for cy in 0..<(h / 2) {
            for cx in 0..<cw {
                var r = 0.0, g = 0.0, b = 0.0
                for dy in 0...1 { for dx in 0...1 { let c = rgb(2 * cx + dx, 2 * cy + dy); r += c.0; g += c.1; b += c.2 } }
                r /= 4; g /= 4; b /= 4
                let yl = 0.2126 * r + 0.7152 * g + 0.0722 * b
                let cb = (b - yl) / 1.8556, cr = (r - yl) / 1.5748
                uOut[cy * cw + cx] = UInt8(clamping: Int((128 + 224 * cb).rounded()))
                vOut[cy * cw + cx] = UInt8(clamping: Int((128 + 224 * cr).rounded()))
            }
        }
    }
}

// MARK: - Audio (what ZoomSDKShareAudioSender.sendShareAudio takes)

/// The share audio sender takes 16-bit signed PCM, interleaved, mono or stereo, at 44100 / 48000 / 50000 /
/// 50400 Hz, in byte lengths that are even (the header's note). The player's tap hands Float32, usually
/// non-interleaved, at the file's own rate and channel count.
enum ShareAudio {
    static let supportedRates: Set<Int> = [44100, 48000, 50000, 50400]
    /// The rate to send: the file's own when Zoom takes it, else 48 kHz (resampled on the send queue).
    static func sendRate(for source: Double) -> Int {
        let r = Int(source.rounded())
        return supportedRates.contains(r) ? r : 48000
    }
    /// Mono stays mono; two or more channels go as stereo (the first two: L and R in every layout AVFoundation hands).
    static func sendChannels(for source: Int) -> Int { source >= 2 ? 2 : 1 }

    /// Float planes (one array per channel, equal lengths) to interleaved Int16, clipped, into `channels` (1 or 2).
    /// A mono source sent as stereo is duplicated; more channels than sent keep the first ones.
    static func interleave(_ planes: [[Float]], channels: Int) -> [Int16] {
        guard let n = planes.first?.count, n > 0 else { return [] }
        var out = [Int16](repeating: 0, count: n * channels)
        for i in 0..<n {
            for c in 0..<channels {
                let plane = planes[min(c, planes.count - 1)]
                let v = max(-1, min(1, plane[i]))
                out[i * channels + c] = Int16((v * 32767).rounded())
            }
        }
        return out
    }

    /// Frames per 10 ms chunk at a rate (441 at 44.1 kHz, 480 at 48 kHz): the size every chunk is sent at.
    static func chunkFrames(rate: Int) -> Int { rate / 100 }

    /// Peak of a set of planes in dBFS mapped onto the meter's 0...1 (−60 dB = 0, 0 dB = 1).
    static func meterLevel(peak: Float) -> Float {
        guard peak > 0 else { return 0 }
        let db = 20 * log10(peak)
        return max(0, min(1, (db + 60) / 60))
    }
}

/// Cuts a stream of interleaved Int16 samples into exact 10 ms chunks, carrying the remainder to the next
/// call, so every `sendShareAudio` is the same size and nothing is dropped or doubled.
struct AudioChunker {
    let channels: Int
    let chunkFrames: Int
    private(set) var pending: [Int16] = []
    init(channels: Int, rate: Int) { self.channels = channels; self.chunkFrames = ShareAudio.chunkFrames(rate: rate) }

    mutating func push(_ samples: [Int16]) -> [[Int16]] {
        pending.append(contentsOf: samples)
        let per = chunkFrames * channels
        guard per > 0 else { return [] }
        var out: [[Int16]] = []
        var i = 0
        while pending.count - i >= per { out.append(Array(pending[i..<(i + per)])); i += per }
        pending.removeFirst(i)
        return out
    }
    /// A seek or a loop: what was pending belongs to the old position.
    mutating func reset() { pending.removeAll(keepingCapacity: true) }
}

// MARK: - Timing

/// Measures how far the audio tap runs AHEAD of the player's clock: every buffer it hands over says which item
/// time it ENDS at. Measured ~0.4 s on AVPlayer (PreviewTests), which is why the file path does not send audio
/// as the tap hands it but releases it on the player's clock (AudioReleaseQueue). Reported in GET /preview as
/// `audioLeadMs` (capped at `maxLead`), and `videoTime` is kept for a source whose lead is small.
struct AVSyncClock {
    /// Smoothed audio lead over the player's clock, seconds, 0 until the tap has spoken.
    private(set) var lead: Double = 0
    private(set) var samples = 0
    static let maxLead = 1.0

    /// One tap buffer: the item time its audio ENDS at, and the player's item time when it was handed over.
    mutating func observe(audioEnd: Double, playerNow: Double) {
        let raw = max(0, min(Self.maxLead, audioEnd - playerNow))
        lead = samples == 0 ? raw : lead * 0.9 + raw * 0.1
        samples += 1
    }
    /// A seek, a loop or a pause: the next buffers start from a new place, the old lead means nothing.
    mutating func reset() { lead = 0; samples = 0 }
    /// The item time whose frame goes out now.
    func videoTime(playerNow: Double) -> Double { playerNow + lead }
}

/// Decides, at each tick of the video poll, whether to send a frame: a NEW frame at up to `maxFps`; when
/// nothing new has come (paused, or a slow file) the last frame again every `keepAlive` seconds, so the
/// far end never shows a frozen-then-dropped share.
/// When the pump sends. A new frame is capped at `maxFps` by the VIDEO's own frame times, not the wall clock:
/// the pump ticks every ~16 ms, so a wall-clock cap skipped a 29.97 fps frame whenever it turned up a few ms
/// "early" and the next tick had a newer one: 26.6-27.1 fps sent, 1 frame in 9 dropped at random, "choppy on
/// the iPad" (live, 2026-09-24). Item time spacing is exact, so a 30 fps file sends every frame and a 60 fps
/// one still goes out at 30. Paused, the last frame is re-sent every `keepAlive` of wall-clock time.
struct FramePacer {
    var maxFps: Double = 30
    var keepAlive: Double = 0.2
    enum Decision: Equatable { case send, resend, skip }
    /// `itemTime`: the new frame's time in the video; `lastItemTime`: the last SENT frame's.
    func decide(now: Double, lastSent: Double?, hasNew: Bool, itemTime: Double = .nan, lastItemTime: Double? = nil) -> Decision {
        guard let lastSent else { return hasNew ? .send : .skip }
        if hasNew {
            // Half a frame of slack at the cap: 29.97 fps (33.4 ms) passes, 60 fps (16.7 ms) is halved.
            if let lastItemTime, itemTime.isFinite {
                let gap = itemTime - lastItemTime
                return gap < 0 || gap >= (1 / maxFps) * 0.5 + 0.001 ? .send : .skip   // < 0: seek or loop back
            }
            return now - lastSent >= (1 / maxFps) - 0.002 ? .send : .skip
        }
        return now - lastSent >= keepAlive ? .resend : .skip
    }
}

enum PreviewTime {
    /// 0:07, 1:02:03; negative and NaN read as 0:00.
    static func clock(_ seconds: Double) -> String {
        let s = seconds.isFinite ? max(0, Int(seconds.rounded(.down))) : 0
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
    /// "−0:23": what is left, never below zero.
    static func remaining(position: Double, duration: Double) -> String {
        "\u{2212}" + clock(max(0, (duration.isFinite ? duration : 0) - (position.isFinite ? position : 0)))
    }
    /// A seek target, clamped inside the file (a scrub past the end lands on its last frame, not after it).
    static func clampSeek(_ t: Double, duration: Double) -> Double {
        guard duration.isFinite, duration > 0 else { return 0 }
        return max(0, min(t.isFinite ? t : 0, max(0, duration - 0.05)))
    }
}

// MARK: - The transport

/// The file player's state machine. The AVPlayer does what this says; the UI, the API and the share read
/// it. Loop is a flag, not a state: at the end a looping file goes back to 0 and keeps playing.
struct PreviewTransport: Equatable {
    enum Phase: Equatable {
        case empty
        case loading
        case converting(Double)   // 0...1, ffmpeg's progress
        case paused
        case playing
        case ended
        case failed(String)
    }
    enum Event: Equatable {
        case load, converting(Double), loaded(duration: Double), failed(String)
        case play, pause, toggle, restart, seek(Double), reachedEnd, unload
    }
    /// What the player must do after the state moved.
    enum Effect: Equatable { case none, play, pause, seek(Double), seekAndPlay(Double) }

    private(set) var phase: Phase = .empty
    private(set) var duration: Double = 0
    var loop = false

    var isLoaded: Bool { phase == .paused || phase == .playing || phase == .ended }
    var isPlaying: Bool { phase == .playing }

    @discardableResult
    mutating func handle(_ e: Event) -> Effect {
        switch e {
        case .unload: phase = .empty; duration = 0; return .pause
        case .load: phase = .loading; duration = 0; return .pause
        case .converting(let p): phase = .converting(max(0, min(1, p))); return .none
        case .failed(let why): phase = .failed(why); return .pause
        case .loaded(let d): duration = d.isFinite ? max(0, d) : 0; phase = .paused; return .seek(0)
        case .play:
            switch phase {
            case .paused: phase = .playing; return .play
            case .ended: phase = .playing; return .seekAndPlay(0)
            default: return .none
            }
        case .pause:
            guard phase == .playing else { return .none }
            phase = .paused; return .pause
        case .toggle:
            return handle(phase == .playing ? .pause : .play)
        case .restart:
            guard isLoaded else { return .none }
            let wasPlaying = phase == .playing
            phase = wasPlaying ? .playing : .paused
            return wasPlaying ? .seekAndPlay(0) : .seek(0)
        case .seek(let t):
            guard isLoaded else { return .none }
            if phase == .ended { phase = .paused }
            return .seek(PreviewTime.clampSeek(t, duration: duration))
        case .reachedEnd:
            guard phase == .playing else { return .none }
            if loop { return .seekAndPlay(0) }
            phase = .ended; return .pause
        }
    }

    var word: String {
        switch phase {
        case .empty: return "NO FILE"
        case .loading: return "LOADING"
        case .converting(let p): return "CONVERTING \(Int((p * 100).rounded()))%"
        case .paused: return "PAUSED"
        case .playing: return "PLAYING"
        case .ended: return "ENDED"
        case .failed: return "FAILED"
        }
    }
}

// MARK: - Formats and ffmpeg

enum PreviewFormats {
    /// What AVFoundation plays directly (and the preview therefore plays with no conversion).
    static let native: Set<String> = ["mov", "mp4", "m4v", "qt"]
    /// What Zoom's own startVideoFileShare accepts (the fallback path: no transport, the SDK plays it).
    static let sdkFileShare: Set<String> = ["mov", "mp4", "avi"]
    static func needsConversion(_ url: URL) -> Bool { !native.contains(url.pathExtension.lowercased()) }
    static let sayWhatWorks = "mov, mp4 and m4v play directly; mkv, webm, avi and others need ffmpeg (ARC Grab or ARC Capture carries one)"
}

enum FFmpeg {
    /// Where an ffmpeg can be: inside an ARC app bundle (Grab: Contents/MacOS/ffmpeg, Capture:
    /// Contents/Resources/bin/ffmpeg), then Homebrew. The app folders are listed by the caller; this orders
    /// the candidates so ARC's own copies win (they are the ones on the fleet Macs).
    static let bundleSubpaths = ["Contents/MacOS/ffmpeg", "Contents/Resources/bin/ffmpeg", "Contents/Resources/ffmpeg", "Contents/Helpers/ffmpeg", "Contents/Frameworks/ffmpeg"]
    static let systemPaths = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]

    static func candidates(apps: [String]) -> [String] {
        let arcFirst = apps.sorted { a, b in
            let aa = (a as NSString).lastPathComponent.hasPrefix("ARC "), bb = (b as NSString).lastPathComponent.hasPrefix("ARC ")
            return aa != bb ? aa : a < b
        }
        return arcFirst.flatMap { app in bundleSubpaths.map { (app as NSString).appendingPathComponent($0) } } + systemPaths
    }

    /// The first candidate the check accepts (exists and is executable, in the app).
    static func locate(apps: [String], isExecutable: (String) -> Bool) -> String? {
        candidates(apps: apps).first(where: isExecutable)
    }

    struct Probe: Equatable {
        var duration: Double?
        var video: String?
        var audio: String?
    }

    /// Reads `ffmpeg -hide_banner -i <file>`'s stderr: "Duration: 00:01:02.34" and the first
    /// "Stream #0:0...: Video: h264 (...)" / "Audio: opus" codec names.
    static func parseProbe(_ text: String) -> Probe {
        var p = Probe()
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if p.duration == nil, let r = line.range(of: "Duration: ") {
                let stamp = line[r.upperBound...].prefix(while: { $0 != "," })
                p.duration = parseStamp(String(stamp))
            }
            if line.hasPrefix("Stream #") {
                for kind in ["Video", "Audio"] {
                    guard let r = line.range(of: "\(kind): ") else { continue }
                    let codec = line[r.upperBound...].prefix(while: { $0 != " " && $0 != "," && $0 != "(" }).lowercased()
                    if kind == "Video", p.video == nil { p.video = codec }
                    if kind == "Audio", p.audio == nil { p.audio = codec }
                }
            }
        }
        return p
    }

    /// "00:01:02.34" -> 62.34; nil for "N/A" or garbage.
    static func parseStamp(_ s: String) -> Double? {
        let parts = s.split(separator: ":")
        guard parts.count == 3, let h = Double(parts[0]), let m = Double(parts[1]), let sec = Double(parts[2]) else { return nil }
        return h * 3600 + m * 60 + sec
    }

    enum Plan: Equatable {
        /// Container change only: seconds, no quality loss.
        case remux
        /// The picture copies, the sound becomes AAC (Opus / Vorbis / AC-3 in an mkv or webm).
        case audioOnly
        /// Both re-encoded (VP9, AV1, MPEG-2 ... into H.264).
        case full
    }
    /// Codecs AVFoundation plays straight out of an mp4, so the container change is all that is needed.
    /// AV1 only where this Mac DECODES it in hardware (M3 and later): a 4K AV1 file on an M1 would decode in
    /// software for the whole show. Opus in mp4 plays natively (checked 2026-09-24: an AV1 + Opus mkv
    /// remuxed in under a second and played, where a full re-encode of the same 4K file crawled at 5 %).
    static let copyableVideo: Set<String> = {
        var s: Set<String> = ["h264", "hevc", "prores", "mjpeg"]
        if VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1) { s.insert("av1") }
        return s
    }()
    static let copyableAudio: Set<String> = ["aac", "mp3", "alac", "opus", "pcm_s16le", "pcm_s24le", "pcm_f32le"]

    static func plan(for probe: Probe) -> Plan {
        let videoOK = probe.video.map { copyableVideo.contains($0) } ?? true
        let audioOK = probe.audio.map { copyableAudio.contains($0) } ?? true
        if videoOK && audioOK { return .remux }
        return videoOK ? .audioOnly : .full
    }

    /// The H.264 encoder to use for a full conversion: VideoToolbox when the build has it, libx264 next,
    /// the built-in mpeg4 last. `encoders` is `ffmpeg -hide_banner -encoders` output.
    static func videoEncoder(_ encoders: String) -> [String] {
        if encoders.contains("h264_videotoolbox") { return ["-c:v", "h264_videotoolbox", "-b:v", "12M", "-allow_sw", "1"] }
        if encoders.contains("libx264") { return ["-c:v", "libx264", "-preset", "veryfast", "-crf", "18"] }
        return ["-c:v", "mpeg4", "-q:v", "2"]
    }

    /// The whole command line, input to a temporary mp4, progress on stdout (`-progress pipe:1`), the first
    /// video and the first audio stream only (an mkv can carry commentary tracks and subtitles).
    static func arguments(input: String, output: String, plan: Plan, encoders: String = "", hevc: Bool = false) -> [String] {
        // A full re-encode decodes in hardware where it can and never makes more than the share sends
        // (1080p): a 4K source re-encoded at 4K was the slow part.
        var a = ["-hide_banner", "-nostdin", "-y"] + (plan == .full ? ["-hwaccel", "videotoolbox"] : []) + ["-i", input, "-map", "0:v:0", "-map", "0:a:0?", "-sn", "-dn"]
        switch plan {
        case .remux: a += ["-c", "copy"]
        case .audioOnly: a += ["-c:v", "copy", "-c:a", "aac", "-b:a", "192k"]
        case .full: a += ["-vf", "scale=w='min(1920,iw)':h='min(1080,ih)':force_original_aspect_ratio=decrease:force_divisible_by=2"]
            + videoEncoder(encoders) + ["-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k"]
        }
        // hvc1: QuickTime plays HEVC in mp4 only under that tag (ffmpeg's copy keeps hev1 otherwise).
        if plan != .full, hevc { a += ["-tag:v", "hvc1"] }
        a += ["-movflags", "+faststart", "-progress", "pipe:1", "-nostats", output]
        return a
    }

    /// One `-progress` block's `out_time_us=` (or `out_time_ms=`, which ffmpeg ALSO writes in microseconds)
    /// against the duration: 0...1, nil when the line is something else.
    static func progress(line: String, duration: Double?) -> Double? {
        guard let duration, duration > 0 else { return nil }
        for key in ["out_time_us=", "out_time_ms="] where line.hasPrefix(key) {
            guard let us = Double(line.dropFirst(key.count)) else { return nil }
            return max(0, min(1, us / 1_000_000 / duration))
        }
        return nil
    }

    /// The temporary mp4 for a source: one per source path and modification date, so the same mkv loaded
    /// twice converts once and an edited file converts again.
    static func outputName(for source: String, modified: Date) -> String {
        let base = ((source as NSString).lastPathComponent as NSString).deletingPathExtension
        let safe = base.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" }
        var h: UInt64 = 1469598103934665603
        for b in "\(source)|\(Int(modified.timeIntervalSince1970))".utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return "\(String(safe).prefix(60))-\(String(h, radix: 16).prefix(10)).mp4"
    }
}

// MARK: - Camera + audio input (the ATEM Mini's USB out: a UVC camera and a USB audio device)

extension ShareAudio {
    /// Interleaved Float32 (what a capture output hands when it will not give Int16) to interleaved Int16,
    /// `inChannels` wide in, `outChannels` wide out (1 or 2): mono duplicated to stereo, extra channels dropped.
    static func int16(interleavedFloat src: [Float], inChannels: Int, outChannels: Int) -> [Int16] {
        guard inChannels > 0 else { return [] }
        let frames = src.count / inChannels
        var out = [Int16](repeating: 0, count: frames * outChannels)
        for i in 0..<frames {
            for c in 0..<outChannels {
                let v = max(-1, min(1, src[i * inChannels + min(c, inChannels - 1)]))
                out[i * outChannels + c] = Int16((v * 32767).rounded())
            }
        }
        return out
    }

    /// Interleaved Int16 re-laid to `outChannels` (the device gave 1, or 4, and the call gets 2).
    static func remap(int16 src: [Int16], inChannels: Int, outChannels: Int) -> [Int16] {
        guard inChannels > 0, inChannels != outChannels else { return src }
        let frames = src.count / inChannels
        var out = [Int16](repeating: 0, count: frames * outChannels)
        for i in 0..<frames { for c in 0..<outChannels { out[i * outChannels + c] = src[i * inChannels + min(c, inChannels - 1)] } }
        return out
    }

    /// Peak of interleaved Int16, 0...1.
    static func peak(int16 src: [Int16]) -> Float {
        var m: Int32 = 0
        for s in src { m = max(m, abs(Int32(s))) }
        return Float(m) / 32767
    }
}

/// Lines a live camera's frames and a live input's audio up on ONE host clock. Both capture outputs stamp
/// their buffers on the session's clock (converted to host time), and each arrives some time after it was
/// captured: video later (the camera and its decode), audio sooner. Zoom's raw share carries no timestamps
/// (the far end plays what arrives), so each item is RELEASED at `capture time + target`, where target is
/// the slower path's latency: the faster stream waits for the slower one, and they leave together.
struct CaptureAligner {
    enum Stream { case video, audio }
    /// Smoothed arrival latency per stream, seconds: fast attack (a late buffer is believed at once), slow
    /// release (one quick buffer does not drop the hold and make the other stream jump).
    private(set) var videoLatency: Double?
    private(set) var audioLatency: Double?
    /// A floor so a jittery arrival does not miss its release; a ceiling so a stalled stream cannot hold the
    /// other back by seconds.
    static let margin = 0.010
    static let maxTarget = 0.300

    mutating func observe(_ s: Stream, captured: Double, arrived: Double) {
        let l = max(0, arrived - captured)
        func smooth(_ old: Double?) -> Double { guard let old else { return l }; return l > old ? l : old * 0.98 + l * 0.02 }
        switch s {
        case .video: videoLatency = smooth(videoLatency)
        case .audio: audioLatency = smooth(audioLatency)
        }
    }
    /// The common hold: the slower path's latency plus the margin, capped. With one stream only (no audio
    /// chosen) that stream goes out as it comes (target = its own latency).
    var target: Double { min(Self.maxTarget, max(videoLatency ?? 0, audioLatency ?? 0) + Self.margin) }
    /// When an item captured at `captured` leaves.
    func release(captured: Double) -> Double { captured + target }
    /// How long the audio waits behind the video at the moment (for GET /preview).
    var audioHold: Double { max(0, (videoLatency ?? 0) - (audioLatency ?? 0)) }
}

/// The FILE path's audio release (measured 2026-09-24 in PreviewTests: AVPlayer pulls its tap ~0.4 s AHEAD of
/// what it shows, 241 chunks of 10 ms handed over in 2.0 s of play). Sending chunks as the tap hands them would
/// put the call's sound 0.4 s before its picture, so each chunk waits here with the ITEM TIME it starts at and is
/// released when the player's clock reaches it; the picture goes out at the player's clock. Pause holds the queue,
/// a seek or a loop flushes it.
struct AudioReleaseQueue {
    struct Chunk { let time: Double; let samples: [Int16]; let rate: Int; let channels: Int }
    private(set) var chunks: [Chunk] = []
    /// A cap so a stalled consumer never grows memory: 5 s of 10 ms chunks.
    static let cap = 500

    mutating func push(_ c: Chunk) {
        chunks.append(c)
        if chunks.count > Self.cap { chunks.removeFirst(chunks.count - Self.cap) }
    }
    /// Everything that starts at or before `now` (the player's item time), in order. Chunks more than
    /// `stale` behind are dropped, not sent: after a hiccup the call catches up instead of running late.
    mutating func due(upTo now: Double, stale: Double = 0.5) -> [Chunk] {
        guard let i = chunks.firstIndex(where: { $0.time > now }) ?? (chunks.isEmpty ? nil : chunks.count) else { return [] }
        let out = chunks[..<i].filter { $0.time >= now - stale }
        chunks.removeFirst(i)
        return Array(out)
    }
    mutating func flush() { chunks.removeAll() }
}

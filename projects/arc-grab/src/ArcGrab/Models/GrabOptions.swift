//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation

enum GrabMode: String, CaseIterable, Codable, Identifiable {
    case video, audio
    var id: String { rawValue }
    var label: String { rawValue.uppercased() }
}

enum Quality: String, CaseIterable, Codable, Identifiable {
    case best, p2160, p1440, p1080, p720
    var id: String { rawValue }
    var label: String {
        switch self {
        case .best: return "BEST"
        case .p2160: return "2160"
        case .p1440: return "1440"
        case .p1080: return "1080"
        case .p720:  return "720"
        }
    }
    var maxHeight: Int? {
        switch self {
        case .best: return nil
        case .p2160: return 2160
        case .p1440: return 1440
        case .p1080: return 1080
        case .p720:  return 720
        }
    }
}

/// Video delivery targets. `mp4` is the compatible file (H.264 + AAC, plays
/// anywhere). `original` keeps whatever YouTube served (VP9/AV1/Opus) in an
/// MKV with no re-encode. The edit codecs transcode to a .mov that drops on a
/// Resolve timeline without optimised media.
enum VideoFormat: String, CaseIterable, Codable, Identifiable {
    case mp4, original, prores422, prores422HQ, dnxhrHQ
    var id: String { rawValue }
    var label: String {
        switch self {
        case .mp4:         return "MP4 H.264"
        case .original:    return "ORIGINAL"
        case .prores422:   return "PRORES 422"
        case .prores422HQ: return "PRORES HQ"
        case .dnxhrHQ:     return "DNxHR HQ"
        }
    }
    /// Container yt-dlp merges into before any conform step.
    var mergeContainer: String { self == .mp4 ? "mp4" : "mkv" }
    /// Extension of the delivered file.
    var finalExtension: String {
        switch self {
        case .mp4: return "mp4"
        case .original: return "mkv"
        case .prores422, .prores422HQ, .dnxhrHQ: return "mov"
        }
    }
    var alwaysConforms: Bool {
        switch self {
        case .prores422, .prores422HQ, .dnxhrHQ: return true
        case .mp4, .original: return false
        }
    }
}

enum AudioFormat: String, CaseIterable, Codable, Identifiable {
    case wav48, m4a, mp3
    var id: String { rawValue }
    var label: String {
        switch self {
        case .wav48: return "WAV 48K"
        case .m4a:   return "M4A"
        case .mp3:   return "MP3"
        }
    }
    var finalExtension: String {
        switch self {
        case .wav48: return "wav"
        case .m4a: return "m4a"
        case .mp3: return "mp3"
        }
    }
}

enum CookieSource: String, CaseIterable, Codable, Identifiable {
    case none, chrome, safari, firefox, brave
    var id: String { rawValue }
    var label: String { rawValue.uppercased() }
}

struct GrabOptions: Codable, Equatable {
    var mode: GrabMode = .video
    var quality: Quality = .best
    var videoFormat: VideoFormat = .mp4
    var audioFormat: AudioFormat = .wav48
    var subtitles = false
    var thumbnail = false
    var chapters = true
    var keepSource = false
    /// whisper.cpp pass after delivery: <name>.srt + <name>.txt next to the file.
    var transcript = false
    /// Optional section trim, "m:ss", "h:mm:ss" or plain seconds. Blank = whole video.
    var sectionIn = ""
    var sectionOut = ""
    var cookies: CookieSource = .none
    /// The page an embedded player lives on (`--referer`): a domain-locked Vimeo embed plays only from there.
    var referer = ""
    /// Vimeo review links and Zoom recordings (`--video-password`).
    var videoPassword = ""
    var destination: String = GrabOptions.defaultDestination

    /// Tolerant decode: a field added in a later release (e.g. `transcript`)
    /// must not throw away the saved preferences of an older one.
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = GrabOptions()
        mode = try c.decodeIfPresent(GrabMode.self, forKey: .mode) ?? d.mode
        quality = try c.decodeIfPresent(Quality.self, forKey: .quality) ?? d.quality
        videoFormat = try c.decodeIfPresent(VideoFormat.self, forKey: .videoFormat) ?? d.videoFormat
        audioFormat = try c.decodeIfPresent(AudioFormat.self, forKey: .audioFormat) ?? d.audioFormat
        subtitles = try c.decodeIfPresent(Bool.self, forKey: .subtitles) ?? d.subtitles
        thumbnail = try c.decodeIfPresent(Bool.self, forKey: .thumbnail) ?? d.thumbnail
        chapters = try c.decodeIfPresent(Bool.self, forKey: .chapters) ?? d.chapters
        keepSource = try c.decodeIfPresent(Bool.self, forKey: .keepSource) ?? d.keepSource
        transcript = try c.decodeIfPresent(Bool.self, forKey: .transcript) ?? d.transcript
        sectionIn = try c.decodeIfPresent(String.self, forKey: .sectionIn) ?? d.sectionIn
        sectionOut = try c.decodeIfPresent(String.self, forKey: .sectionOut) ?? d.sectionOut
        cookies = try c.decodeIfPresent(CookieSource.self, forKey: .cookies) ?? d.cookies
        referer = try c.decodeIfPresent(String.self, forKey: .referer) ?? d.referer
        videoPassword = try c.decodeIfPresent(String.self, forKey: .videoPassword) ?? d.videoPassword
        destination = try c.decodeIfPresent(String.self, forKey: .destination) ?? d.destination
    }

    static var defaultDestination: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads/ARC Grab").path
    }

    /// Short target descriptor for the queue row, e.g. "PRORES 422 · 2160".
    var targetLabel: String {
        switch mode {
        case .video: return "\(videoFormat.label) · \(quality.label)" + (transcript ? " + TXT" : "")
        case .audio: return audioFormat.label + (transcript ? " + TXT" : "")
        }
    }

    var finalExtension: String {
        mode == .video ? videoFormat.finalExtension : audioFormat.finalExtension
    }

    var hasSection: Bool {
        !sectionIn.trimmingCharacters(in: .whitespaces).isEmpty
            || !sectionOut.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

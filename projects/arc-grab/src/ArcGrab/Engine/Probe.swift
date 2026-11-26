//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation

struct ProbeResult: Equatable {
    var videoCodec: String?
    var audioCodec: String?
    var width: Int?
    var height: Int?
    var duration: Double?

    static func parse(_ data: Data) -> ProbeResult {
        var r = ProbeResult()
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return r }
        for s in obj["streams"] as? [[String: Any]] ?? [] {
            let type = s["codec_type"] as? String
            if type == "video", r.videoCodec == nil {
                r.videoCodec = s["codec_name"] as? String
                r.width = s["width"] as? Int
                r.height = s["height"] as? Int
            } else if type == "audio", r.audioCodec == nil {
                r.audioCodec = s["codec_name"] as? String
            }
        }
        if let f = obj["format"] as? [String: Any], let d = f["duration"] as? String {
            r.duration = Double(d)
        }
        return r
    }

    /// Does the downloaded file already satisfy the target, or must ffmpeg run?
    static func needsConform(_ r: ProbeResult, options o: GrabOptions) -> Bool {
        switch o.mode {
        case .audio:
            return o.audioFormat == .wav48
        case .video:
            switch o.videoFormat {
            case .original: return false
            case .prores422, .prores422HQ, .dnxhrHQ: return true
            case .mp4:
                let vOK = r.videoCodec == "h264"
                let aOK = r.audioCodec == nil || r.audioCodec == "aac"
                return !(vOK && aOK)
            }
        }
    }

    static func probe(_ path: String, toolchain: Toolchain) -> ProbeResult {
        guard let ffprobe = toolchain.ffprobe,
              let out = try? ProcessRunner.capture(ffprobe, CommandBuilder.probeArgs(input: path),
                                                   env: toolchain.environment()) else { return ProbeResult() }
        return parse(Data(out.utf8))
    }
}

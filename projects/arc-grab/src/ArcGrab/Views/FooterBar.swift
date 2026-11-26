//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI

struct FooterBar: View {
    @Bindable var queue: GrabQueue
    @Bindable var settings: Settings

    var body: some View {
        HStack(spacing: ARCRow.gap) {
            Text(engineText)
                .font(ARCRow.font)
                .foregroundStyle(!queue.engineChecked ? ARCTheme.text1 : (queue.toolchain.isComplete ? ARCTheme.text2 : ARCTheme.arcRed))
                .lineLimit(1)
            ARCButton(title: queue.updateAvailable == nil ? "UPDATE ENGINE" : "UPDATE ENGINE ●", accent: queue.updateAvailable != nil, width: 150, disabled: queue.engineBusy || !queue.engineChecked || queue.toolchain.ytdlp == nil) {
                queue.updateEngine()
            }
            ARCButton(title: "REPAIR", width: 80, disabled: queue.engineBusy || !(Toolchain.bundledYtdlpDir.map(Toolchain.isYtdlpDir) ?? false)) {
                queue.repairEngine()
            }
            Text(queue.engineMessage)
                .font(ARCRow.font)
                .foregroundStyle(ARCTheme.text1)
                .lineLimit(1)
            Spacer(minLength: 0)
            Text("PARALLEL")
                .font(ARCRow.font).tracking(0.8).foregroundStyle(ARCTheme.text1)
            ARCSegment(items: [1, 2, 3], selection: $settings.concurrency) { "\($0)" }
                .frame(width: 120)
                .onChange(of: settings.concurrency) { _, n in
                    queue.concurrency = n
                    queue.pump()
                }
        }
        .frame(height: ARCRow.height)
    }

    private var engineText: String {
        let t = queue.toolchain
        if !queue.engineChecked {
            return "ENGINE CHECKING…  YT-DLP \(t.ytdlpVersion) \(t.ytdlpSource.rawValue) · FFMPEG \(t.ffmpegVersion) \(t.ffmpegSource.rawValue)"
        }
        if !t.isComplete {
            var missing: [String] = []
            if t.ytdlp == nil { missing.append("yt-dlp") }
            if t.ffmpeg == nil { missing.append("ffmpeg") }
            if t.ffprobe == nil { missing.append("ffprobe") }
            return "ENGINE MISSING: \(missing.joined(separator: ", ")) · REPAIR or reinstall ARC Grab"
        }
        // Whisper only speaks up when something is off: the footer is one
        // line and the normal case (bundled, models present) needs no words.
        var line = "YT-DLP \(t.ytdlpVersion) \(t.ytdlpSource.rawValue) · FFMPEG \(t.ffmpegVersion) \(t.ffmpegSource.rawValue)"
        if t.whisper == nil { line += " · WHISPER MISSING" }
        else if !ModelFetcher.allPresent() { line += " · WHISPER MODELS 575 MB ON 1ST USE" }
        return line
    }
}

extension Int: @retroactive Identifiable {
    public var id: Int { self }
}

//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation

struct DownloadProgress: Equatable {
    var status: String        // downloading | finished
    var downloaded: Double
    var total: Double?        // total_bytes, else total_bytes_estimate
    var speed: Double?
    var eta: Int?
    var fraction: Double? { total.flatMap { $0 > 0 ? min(1, downloaded / $0) : nil } }
}

enum ProgressParser {
    /// ARCP|status|downloaded|total|estimate|speed|eta
    static func parseDownload(_ line: String) -> DownloadProgress? {
        guard line.hasPrefix(CommandBuilder.progressTag + "|") else { return nil }
        let f = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard f.count >= 7 else { return nil }
        func num(_ s: String) -> Double? { s == "NA" || s.isEmpty ? nil : Double(s) }
        return DownloadProgress(status: f[1],
                                downloaded: num(f[2]) ?? 0,
                                total: num(f[3]) ?? num(f[4]),
                                speed: num(f[5]),
                                eta: num(f[6]).map { Int($0) })
    }

    /// ARCFILE|/path/to/file
    static func parseFinalPath(_ line: String) -> String? {
        guard line.hasPrefix(CommandBuilder.fileTag + "|") else { return nil }
        return String(line.dropFirst(CommandBuilder.fileTag.count + 1))
    }

    /// yt-dlp error lines: "ERROR: [youtube] xyz: Video unavailable"
    static func parseError(_ line: String) -> String? {
        guard line.hasPrefix("ERROR:") else { return nil }
        return line.dropFirst(6).trimmingCharacters(in: .whitespaces)
    }

    /// ffmpeg -progress "out_time_us=1234567" -> seconds
    static func parseFFmpegSeconds(_ line: String) -> Double? {
        if line.hasPrefix("out_time_us=") {
            return Double(line.dropFirst("out_time_us=".count)).map { $0 / 1_000_000 }
        }
        return nil
    }

    /// whisper-cli -pp: "whisper_print_progress_callback: progress =  42%" -> 0.42
    static func parseWhisperProgress(_ line: String) -> Double? {
        guard line.hasPrefix("whisper_print_progress_callback: progress ="),
              let eq = line.lastIndex(of: "="),
              let pct = Int(line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "%", with: "")) else { return nil }
        return min(1, max(0, Double(pct) / 100))
    }

    static func formatBytesPerSec(_ v: Double) -> String {
        if v >= 1_000_000 { return String(format: "%.1f MB/s", v / 1_000_000) }
        if v >= 1_000 { return String(format: "%.0f KB/s", v / 1_000) }
        return String(format: "%.0f B/s", v)
    }

    static func formatClock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

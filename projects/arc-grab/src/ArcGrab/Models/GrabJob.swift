//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation

enum JobStatus: Equatable {
    case analyzing
    case ready
    case downloading
    case conforming
    case transcribing
    case done
    case failed(String)
    case cancelled

    var isActive: Bool { self == .downloading || self == .conforming || self == .transcribing }
    var isFinished: Bool {
        switch self {
        case .done, .failed, .cancelled: return true
        default: return false
        }
    }
    var label: String {
        switch self {
        case .analyzing: return "ANALYZING"
        case .ready: return "QUEUED"
        case .downloading: return "DOWNLOADING"
        case .conforming: return "CONFORMING"
        case .transcribing: return "TRANSCRIBING"
        case .done: return "DONE"
        case .failed: return "FAILED"
        case .cancelled: return "CANCELLED"
        }
    }
}

@Observable @MainActor
final class GrabJob: Identifiable {
    let id = UUID()
    let sourceURL: String
    let options: GrabOptions

    var info: MediaInfo?
    var status: JobStatus = .analyzing
    /// 0...1 for the current phase; nil = indeterminate (section downloads via ffmpeg report no bytes).
    var fraction: Double? = 0
    var speedBytesPerSec: Double?
    var etaSeconds: Int?
    var phase: String = ""
    /// What the last failure wanted (ErrorMapper): the row turns it into a button where it can.
    var failureHint: GrabFailure.Hint?
    var outputPath: String?
    /// The .txt written by the transcript pass (the .srt sits next to it).
    var transcriptPath: String?
    /// When the download began: a cancelled job removes files it created after this (GrabQueue.cleanupPartials).
    var startedAt: Date?
    var log: [String] = []

    init(sourceURL: String, options: GrabOptions, info: MediaInfo? = nil) {
        self.sourceURL = sourceURL
        self.options = options
        self.info = info
        if info != nil { status = .ready }
    }

    var title: String { info?.title ?? sourceURL }

    func appendLog(_ line: String) {
        log.append(line)
        if log.count > 400 { log.removeFirst(log.count - 400) }
    }

    func resetForRetry() {
        status = .ready
        fraction = 0
        speedBytesPerSec = nil
        etaSeconds = nil
        phase = ""
        failureHint = nil
        outputPath = nil
        transcriptPath = nil
        startedAt = nil
        log.removeAll()
    }
}

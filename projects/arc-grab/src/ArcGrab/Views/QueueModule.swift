//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI

struct QueueModule: View {
    @Bindable var queue: GrabQueue

    var body: some View {
        VStack(spacing: ARCRow.gap) {
            HStack(spacing: ARCRow.gap) {
                Text(summary)
                    .font(ARCRow.font).tracking(0.8)
                    .foregroundStyle(ARCTheme.text1)
                Spacer(minLength: 0)
                ARCButton(title: "CLEAR DONE", width: 110, disabled: !queue.jobs.contains { $0.status.isFinished }) {
                    queue.clearFinished()
                }
                ARCButton(title: "CANCEL ALL", width: 110, disabled: !queue.jobs.contains { !$0.status.isFinished }) {
                    queue.cancelAll()
                }
            }
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(queue.jobs) { job in
                        JobRow(job: job, queue: queue)
                    }
                }
                .background(ARCTheme.line)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ARCTheme.panel)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(ARCTheme.line, lineWidth: 1))
            .overlay {
                if queue.jobs.isEmpty {
                    Text("DROP A LINK OR PASTE ONE ABOVE")
                        .font(ARCRow.font).tracking(1)
                        .foregroundStyle(ARCTheme.text2)
                }
            }
        }
        .arcModule(title: "QUEUE", tint: ARCTheme.secGreen)
    }

    private var summary: String {
        let total = queue.jobs.count
        let active = queue.activeCount
        let waiting = queue.jobs.filter { $0.status == .ready || $0.status == .analyzing }.count
        let failed = queue.jobs.filter { if case .failed = $0.status { return true } else { return false } }.count
        var parts = ["\(queue.doneCount)/\(total) DONE"]
        if active > 0 { parts.append("\(active) ACTIVE") }
        if waiting > 0 { parts.append("\(waiting) WAITING") }
        if failed > 0 { parts.append("\(failed) FAILED") }
        return parts.joined(separator: " · ")
    }
}

struct JobRow: View {
    @Bindable var job: GrabJob
    let queue: GrabQueue
    @State private var showLog = false

    static let thumbW: CGFloat = 96
    static let thumbH: CGFloat = 54
    static let barH: CGFloat = 4

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                thumbnail
                VStack(alignment: .leading, spacing: 4) {
                    Text(job.title)
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(ARCTheme.text0)
                        .lineLimit(1)
                    Text(meta)
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundStyle(ARCTheme.text1)
                        .lineLimit(1)
                    progressBar
                    Text(statusLine)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(statusColor)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                actions
            }
            if showLog {
                ScrollView {
                    Text(job.log.suffix(60).joined(separator: "\n"))
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundStyle(ARCTheme.text1)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 140)
                .padding(6)
                .background(ARCTheme.ink)
            }
        }
        .padding(8)
        .background(ARCTheme.moduleBg)
    }

    private var thumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3).fill(ARCTheme.panel)
            if let t = job.info?.thumbnail, let u = URL(string: t) {
                AsyncImage(url: u) { img in
                    img.resizable().aspectRatio(contentMode: .fill)
                } placeholder: { Color.clear }
            }
        }
        .frame(width: JobRow.thumbW, height: JobRow.thumbH)
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    private var progressBar: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Rectangle().fill(ARCTheme.line)
                if let f = job.fraction {
                    Rectangle().fill(barColor).frame(width: g.size.width * f)
                } else if job.status.isActive {
                    Rectangle().fill(barColor).frame(width: g.size.width * 0.25)
                        .offset(x: g.size.width * 0.375)
                }
            }
        }
        .frame(height: JobRow.barH)
    }

    private var barColor: Color {
        switch job.status {
        case .done: return ARCTheme.live
        case .failed: return ARCTheme.arcRed
        case .cancelled: return ARCTheme.text2
        case .conforming, .transcribing: return ARCTheme.warn
        default: return ARCTheme.live
        }
    }

    private var statusColor: Color {
        switch job.status {
        case .failed: return ARCTheme.arcRed
        case .done: return ARCTheme.live
        case .cancelled, .ready, .analyzing: return ARCTheme.text2
        default: return ARCTheme.text0
        }
    }

    private var meta: String {
        var parts: [String] = []
        if let info = job.info { parts.append(info.siteLabel) }
        if let u = job.info?.uploader, !u.isEmpty { parts.append(u) }
        if let d = job.info?.duration { parts.append(ProgressParser.formatClock(d)) }
        if let h = job.info?.maxHeight { parts.append("SRC \(h)p") }
        parts.append(job.options.targetLabel)
        return parts.joined(separator: " · ")
    }

    private var statusLine: String {
        switch job.status {
        case .analyzing: return "ANALYZING…"
        case .ready: return "QUEUED"
        case .downloading, .conforming, .transcribing:
            var s = "\(job.status.label) \(job.phase)"
            if let f = job.fraction { s += String(format: " %3.0f%%", f * 100) }
            if let sp = job.speedBytesPerSec { s += " · \(ProgressParser.formatBytesPerSec(sp))" }
            if let e = job.etaSeconds { s += " · ETA \(ProgressParser.formatClock(Double(e)))" }
            return s
        case .done:
            let name = (job.outputPath as NSString?)?.lastPathComponent ?? ""
            return job.transcriptPath == nil ? "DONE → \(name)" : "DONE → \(name) + .txt + .srt"
        case .failed(let m): return "FAILED: \(m)"
        case .cancelled: return job.phase.isEmpty ? "CANCELLED" : job.phase
        }
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 6) {
            switch job.status {
            case .done:
                if job.transcriptPath != nil {
                    ARCButton(title: "TXT", width: 48) { queue.openTranscript(job) }
                }
                ARCButton(title: "REVEAL", width: 84) { queue.reveal(job) }
                ARCButton(title: "✕", width: 34) { queue.remove(job) }
            case .failed, .cancelled:
                // The hint that is a button IS the button: an engine update, then the retry.
                if job.failureHint == .updateEngine {
                    ARCButton(title: "UPDATE ENGINE", accent: true, width: 120) { queue.updateEngine() }
                }
                ARCButton(title: "RETRY", width: 84) { queue.retry(job) }
                ARCButton(title: "✕", width: 34) { queue.remove(job) }
            case .downloading, .conforming, .transcribing, .analyzing:
                ARCButton(title: "CANCEL", accent: true, width: 84) { queue.cancel(job) }
                ARCButton(title: "LOG", width: 34) { showLog.toggle() }
            case .ready:
                ARCButton(title: "SKIP", width: 84) { queue.cancel(job) }
                ARCButton(title: "✕", width: 34) { queue.remove(job) }
            }
        }
    }
}

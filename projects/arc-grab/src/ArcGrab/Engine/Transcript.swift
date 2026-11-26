//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation

/// SRT in, paragraphed text out. Whisper's own .txt is one line per segment,
/// which reads like a teleprompter dump. The ARC paragrapher (from the
/// transcription workflow, 2026-05) breaks on pauses between segments
/// once a paragraph is long enough, and hard-caps a monologue that never
/// pauses. Output is one paragraph per line, no hard wraps, so it pastes
/// clean into a doc or an email.
enum Transcript {
    struct Segment: Equatable {
        var start: Double
        var end: Double
        var text: String
    }

    static let pauseThreshold = 0.8   // s, soft break once minLen is reached
    static let longPause = 2.0        // s, forced break
    static let minLen = 200           // chars, no break before this
    static let softCap = 500          // chars, take any qualifying pause
    static let hardCap = 800          // chars, break at the next segment regardless
    static let runawayCap = 1500      // chars, break mid-flow if nothing else did

    /// "00:01:02,345" or "00:01:02.345" -> seconds
    static func parseClock(_ s: String) -> Double? {
        let parts = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard parts.count == 3, let h = Double(parts[0]), let m = Double(parts[1]), let sec = Double(parts[2]) else { return nil }
        return h * 3600 + m * 60 + sec
    }

    static func parseSRT(_ text: String) -> [Segment] {
        var out: [Segment] = []
        var cur: Segment?
        var body: [String] = []
        func flush() {
            if var c = cur {
                c.text = body.joined(separator: " ").trimmingCharacters(in: .whitespaces)
                if !c.text.isEmpty { out.append(c) }
            }
            cur = nil; body = []
        }
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); continue }
            if let r = line.range(of: " --> ") {
                if let s = parseClock(String(line[..<r.lowerBound])), let e = parseClock(String(line[r.upperBound...])) {
                    flush()
                    cur = Segment(start: s, end: e, text: "")
                }
                continue
            }
            if cur == nil, Int(line) != nil { continue }   // cue index
            if cur != nil { body.append(line) }
        }
        flush()
        return out
    }

    static func paragraphs(_ segs: [Segment]) -> [String] {
        var out: [String] = []
        var cur = ""
        var lastEnd: Double?
        for s in segs {
            let t = s.text.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
            if !cur.isEmpty {
                let pause = lastEnd.map { s.start - $0 } ?? 0
                let n = cur.count
                let brk = (pause >= longPause && n >= minLen)
                    || (pause >= pauseThreshold && n >= softCap)
                    || n >= hardCap
                if brk { out.append(cur); cur = "" }
            }
            cur = cur.isEmpty ? t : cur + " " + t
            if cur.count >= runawayCap { out.append(cur); cur = "" }
            lastEnd = s.end
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    /// Reads base.srt, writes base.txt (paragraphs separated by a blank line). Returns the .txt path.
    @discardableResult
    static func writeText(srt: URL, txt: URL) throws -> URL {
        let segs = parseSRT(try String(contentsOf: srt, encoding: .utf8))
        let paras = paragraphs(segs)
        try (paras.joined(separator: "\n\n") + "\n").write(to: txt, atomically: true, encoding: .utf8)
        return txt
    }
}

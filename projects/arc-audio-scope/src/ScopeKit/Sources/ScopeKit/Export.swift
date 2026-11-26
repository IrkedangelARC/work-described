//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation

/// CSV text for everything a show can hand to a spreadsheet.
public enum Export {
    public static func csv(_ rows: [[String]]) -> String {
        rows.map { row in
            row.map { cell in
                cell.contains(where: { ",\"\n\r".contains($0) }) ? "\"" + cell.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : cell
            }.joined(separator: ",")
        }.joined(separator: "\r\n") + "\r\n"
    }

    private static func n(_ v: Double, _ digits: Int = 2) -> String { v.isFinite ? String(format: "%.\(digits)f", v) : "" }
    private static let stamp: ISO8601DateFormatter = ISO8601DateFormatter()

    /// One row per band, one column per trace. `floor` and below is left blank.
    public static func spectrum(layout: BandLayout, unit: String, columns: [(name: String, levels: [Float])], floor: Float = -160) -> String {
        var rows = [["Hz"] + columns.map { "\($0.name) (\(unit))" }]
        for b in 0..<layout.count {
            rows.append([n(layout.centers[b])] + columns.map { $0.levels.count == layout.count && $0.levels[b] > floor ? n(Double($0.levels[b])) : "" })
        }
        return csv(rows)
    }

    /// `offsetDB` is the calibration (0 when the levels are dBFS).
    public static func ringLog(_ log: [RingLogEntry], offsetDB: Double, unit: String) -> String {
        var rows = [["time", "Hz", "GEQ band", "level (\(unit))", "neighbours ms per 20 dB", "tail ms", "decay ms per 20 dB", "excess ms", "held", "times at this frequency", "found by", "doing", "dB per second", "detector also flagged it"]]
        for e in log {
            rows.append([stamp.string(from: e.date), n(e.frequency, 1), e.geqBand, n(e.levelDB + offsetDB, 1), n(e.neighbourMs, 0), n(e.tailMs, 0),
                         e.decayMs.map { n($0, 0) } ?? "", n(e.excessMs, 0), e.sustained ? "yes" : "no",
                         "\(log.filter { abs($0.band - e.band) <= 1 }.count)", e.marked ? "marked by hand" : "detector",
                         e.verdict?.rawValue ?? "", e.slopeDBPerSecond.map { n($0, 1) } ?? "",
                         e.detectorFlagged.map { $0 ? "yes" : "no" } ?? ""])
        }
        return csv(rows)
    }

    public static func events(_ events: [ScopeEvent]) -> String {
        csv([["time", "kind", "input", "detail"]] + events.map { [stamp.string(from: $0.date), $0.kind.rawValue, "\($0.channel + 1)", $0.detail] })
    }

    /// `zeroDB` is what the plot's 0 dB line stands for.
    public static func transfer(_ r: TransferResult, zeroDB: Double, threshold: Float, traces: [TransferTrace] = []) -> String {
        var header = ["Hz", "magnitude dB", "phase deg", "unwrapped phase deg", "coherence", "trusted"]
        for t in traces { header += ["\(t.name) magnitude dB", "\(t.name) phase deg", "\(t.name) coherence"] }
        var rows = [header]
        let unwrapped = r.unwrappedPhase(threshold: threshold)
        for b in 0..<r.frequencies.count {
            var row = [n(r.frequencies[b])]
            if r.valid[b] {
                row += [n(Double(r.magnitudeDB[b]) - zeroDB), n(Double(r.phaseDegrees[b]), 1), n(Double(unwrapped[b]), 1), n(Double(r.coherence[b]), 3),
                        r.coherence[b] >= threshold ? "yes" : "no"]
            } else {
                row += ["", "", "", "", "no"]
            }
            for t in traces {
                let ok = b < t.trusted.count && t.trusted[b]
                row += ok ? [n(Double(t.magnitudeDB[b]) - zeroDB), n(Double(t.phaseDegrees[b]), 1), n(Double(t.coherence[b]), 3)] : ["", "", ""]
            }
            rows.append(row)
        }
        return csv(rows)
    }
}

//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation

/// Every editable field of a Cue as a plain value, so the full CUE EDITOR works on a copy and the
/// running show only changes on SAVE (2026-09-25: "expand the cues in a full editor that
/// allows for customisation of all aspects of the cue"). The same value is the undo snapshot.
struct CueDraft: Equatable {
    var title: String
    var subtitle: String
    var speakers: String
    var format: CueFormat
    var customFormatLabel: String
    var startTime: Date?
    var durationSeconds: Int
    var warningThreshold: Int
    var dangerThreshold: Int
    var overtimeAllowed: Bool
    var notes: String

    init(_ cue: Cue) {
        title = cue.title
        subtitle = cue.subtitle ?? ""
        speakers = cue.speakers ?? ""
        format = cue.format
        customFormatLabel = cue.customFormatLabel ?? ""
        startTime = cue.startTime
        durationSeconds = cue.durationSeconds
        warningThreshold = cue.warningThreshold
        dangerThreshold = cue.dangerThreshold
        overtimeAllowed = cue.overtimeAllowed
        notes = cue.notes ?? ""
    }

    /// The draft as it will be stored: text trimmed, empty text as nil, duration at least 1 s,
    /// thresholds inside the duration and danger below warning (the colours only make sense in that order).
    var normalized: CueDraft {
        var d = self
        d.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        d.subtitle = subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        d.speakers = speakers.trimmingCharacters(in: .whitespacesAndNewlines)
        d.customFormatLabel = format == .custom ? customFormatLabel.trimmingCharacters(in: .whitespaces) : ""
        d.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        d.durationSeconds = max(1, durationSeconds)
        d.warningThreshold = min(max(0, warningThreshold), d.durationSeconds)
        d.dangerThreshold = min(max(0, dangerThreshold), max(0, d.warningThreshold - 1))
        return d
    }

    /// What SAVE is allowed to store.
    var isValid: Bool { !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && durationSeconds > 0 }

    func apply(to cue: Cue) {
        let d = normalized
        cue.title = d.title
        cue.subtitle = d.subtitle.isEmpty ? nil : d.subtitle
        cue.speakers = d.speakers.isEmpty ? nil : d.speakers
        cue.format = d.format
        cue.customFormatLabel = d.customFormatLabel.isEmpty ? nil : d.customFormatLabel
        cue.startTime = d.startTime
        cue.durationSeconds = d.durationSeconds
        cue.warningThreshold = d.warningThreshold
        cue.dangerThreshold = d.dangerThreshold
        cue.overtimeAllowed = d.overtimeAllowed
        cue.notes = d.notes.isEmpty ? nil : d.notes
    }
}

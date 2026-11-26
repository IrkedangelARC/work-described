//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation
import SwiftData

@Model
final class Cue {
    var id: UUID
    var sortOrder: Int
    var title: String
    var subtitle: String?
    var format: CueFormat
    var speakers: String?
    var startTime: Date?
    var durationSeconds: Int
    var warningThreshold: Int
    var dangerThreshold: Int
    var overtimeAllowed: Bool
    var notes: String?
    /// The text for a `.custom` format (optional, so existing stores migrate without a step).
    var customFormatLabel: String?

    var show: Show?

    /// What the format is called: the custom text for `.custom`, the format's own name otherwise.
    var formatLabel: String {
        if format == .custom, let t = customFormatLabel?.trimmingCharacters(in: .whitespaces), !t.isEmpty { return t }
        return format.label
    }

    init(
        title: String,
        sortOrder: Int = 0,
        subtitle: String? = nil,
        format: CueFormat = .other,
        speakers: String? = nil,
        startTime: Date? = nil,
        durationSeconds: Int = 1800,
        warningThreshold: Int = 120,
        dangerThreshold: Int = 30,
        overtimeAllowed: Bool = true,
        notes: String? = nil
    ) {
        self.id = UUID()
        self.sortOrder = sortOrder
        self.title = title
        self.subtitle = subtitle
        self.format = format
        self.speakers = speakers
        self.startTime = startTime
        self.durationSeconds = durationSeconds
        self.warningThreshold = warningThreshold
        self.dangerThreshold = dangerThreshold
        self.overtimeAllowed = overtimeAllowed
        self.notes = notes
    }

    var formattedDuration: String {
        let minutes = durationSeconds / 60
        let seconds = durationSeconds % 60
        if minutes >= 60 {
            let hours = minutes / 60
            let mins = minutes % 60
            return String(format: "%d:%02d:%02d", hours, mins, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}

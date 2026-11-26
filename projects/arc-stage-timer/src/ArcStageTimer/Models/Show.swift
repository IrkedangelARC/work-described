//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation
import SwiftData

@Model
final class Show {
    var id: UUID
    var name: String
    var arcNumber: String?
    var date: Date
    var venue: String?
    var notes: String?
    @Relationship(deleteRule: .cascade, inverse: \Cue.show)
    var cues: [Cue]
    var confidenceConfigData: Data?
    var createdAt: Date
    var updatedAt: Date

    init(
        name: String,
        arcNumber: String? = nil,
        date: Date = .now,
        venue: String? = nil,
        notes: String? = nil,
        cues: [Cue] = []
    ) {
        self.id = UUID()
        self.name = name
        self.arcNumber = arcNumber
        self.date = date
        self.venue = venue
        self.notes = notes
        self.cues = cues
        self.createdAt = .now
        self.updatedAt = .now
    }

    var confidenceConfig: ConfidenceMonitorConfig {
        get {
            guard let data = confidenceConfigData,
                  let config = try? JSONDecoder().decode(ConfidenceMonitorConfig.self, from: data)
            else { return .default }
            return config
        }
        set {
            confidenceConfigData = try? JSONEncoder().encode(newValue)
            updatedAt = .now
        }
    }

    var sortedCues: [Cue] {
        cues.sorted { $0.sortOrder < $1.sortOrder }
    }

    var totalDuration: Int {
        cues.reduce(0) { $0 + $1.durationSeconds }
    }

    var formattedTotalDuration: String {
        let hours = totalDuration / 3600
        let minutes = (totalDuration % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }

    /// Creates a deep copy with new UUIDs for both the show and all cues.
    func deepCopy() -> Show {
        let copy = Show(
            name: name + " (Copy)",
            arcNumber: arcNumber,
            date: date,
            venue: venue,
            notes: notes
        )
        copy.confidenceConfigData = confidenceConfigData
        for cue in sortedCues {
            let cueCopy = Cue(
                title: cue.title,
                sortOrder: cue.sortOrder,
                subtitle: cue.subtitle,
                format: cue.format,
                speakers: cue.speakers,
                startTime: cue.startTime,
                durationSeconds: cue.durationSeconds,
                warningThreshold: cue.warningThreshold,
                dangerThreshold: cue.dangerThreshold,
                overtimeAllowed: cue.overtimeAllowed,
                notes: cue.notes
            )
            cueCopy.show = copy
            copy.cues.append(cueCopy)
        }
        return copy
    }
}

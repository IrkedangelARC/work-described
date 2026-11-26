//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation
import SwiftData

enum SampleData {
    static func createIfNeeded(context: ModelContext) {
        let descriptor = FetchDescriptor<Show>()
        let count = (try? context.fetchCount(descriptor)) ?? 0
        guard count == 0 else { return }

        let show = createTestShow()
        context.insert(show)
        for cue in show.cues {
            context.insert(cue)
        }
        try? context.save()
    }

    static func createTestShow() -> Show {
        let show = Show(
            name: "Test Show",
            arcNumber: "JOB-0000",
            date: .now,
            venue: "Demo Venue"
        )

        let cues: [Cue] = [
            {
                let c = Cue(title: "Opening Remarks", sortOrder: 0,
                            subtitle: "Welcome & Introductions",
                            format: .remarks, speakers: "Speaker One",
                            durationSeconds: 300)
                c.notes = "5-minute welcome"
                c.show = show
                return c
            }(),
            {
                let c = Cue(title: "Main Presentation", sortOrder: 1,
                            subtitle: "Demo Topic",
                            format: .keynote, speakers: "Speaker Two",
                            durationSeconds: 600)
                c.notes = "10-minute presentation with slides"
                c.show = show
                return c
            }(),
            {
                let c = Cue(title: "Closing & Q&A", sortOrder: 2,
                            subtitle: "Wrap Up",
                            format: .panel, speakers: "All Speakers",
                            durationSeconds: 300)
                c.notes = "5-minute Q&A session"
                c.show = show
                return c
            }(),
        ]

        show.cues = cues
        return show
    }
}

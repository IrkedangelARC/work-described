//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI

struct ClockView: View {
    /// The header's second step when it runs out of width (2026-09-23): 20 pt instead of 29.
    var compact = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(context.date.formatted(.dateTime.hour().minute().second()))
                .font(compact ? .system(size: 20, weight: .medium, design: .monospaced) : ARCTheme.clock)
                .foregroundStyle(ARCTheme.textSecondary)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()     // never wrapped: squeezed, it stood one character per line and made the footer 300 pt tall (2026-09-17)
        }
    }
}

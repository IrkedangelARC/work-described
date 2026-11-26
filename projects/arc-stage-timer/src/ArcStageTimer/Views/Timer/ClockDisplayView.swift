//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI

/// Wall clock display using TimelineView for smooth second updates.
/// `stage: true` uses large fonts for external HDMI display.
struct ClockDisplayView: View {
    var stage: Bool = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0)) { context in
            let now = context.date
            VStack(spacing: stage ? 24 : 12) {
                Spacer()
                Text(now, format: .dateTime.hour().minute().second())
                    .font(.system(
                        size: stage ? 280 : 120,
                        weight: .light,
                        design: .monospaced
                    ))
                    .minimumScaleFactor(0.3)
                    .foregroundStyle(ARCTheme.textPrimary)
                    .contentTransition(.numericText())
                Text(now, format: .dateTime.weekday(.wide).month(.wide).day())
                    .font(.system(
                        size: stage ? 64 : 32,
                        weight: .medium
                    ))
                    .foregroundStyle(ARCTheme.textSecondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
        }
    }
}

//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI

/// Large, panel-style clock for the operator window's right column.
/// Sized to share visual weight with the NEXT slide preview above it.
struct ClockView: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(spacing: 4) {
                HStack {
                    Text("TIME")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.55))
                    Spacer()
                }
                ZStack {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.black)
                    Text(context.date.formatted(.dateTime.hour().minute().second()))
                        .font(.system(size: 56, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.92))
                        .monospacedDigit()
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                        .padding(.horizontal, 16)
                }
                .frame(maxWidth: .infinity)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
            }
            .help("Current time")
        }
    }
}

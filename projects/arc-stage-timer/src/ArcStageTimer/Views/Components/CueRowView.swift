//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI

struct CueRowView: View {
    let cue: Cue
    let isActive: Bool
    let isCurrent: Bool
    var projectedStart: Date?

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()

    init(cue: Cue, isActive: Bool = false, isCurrent: Bool = false, projectedStart: Date? = nil) {
        self.cue = cue
        self.isActive = isActive
        self.isCurrent = isCurrent
        self.projectedStart = projectedStart
    }

    var body: some View {
        HStack(spacing: 8) {
            // Active indicator
            // The cue under the operator's hands: OPERATE orange (red is reserved for LIVE and danger).
            Rectangle()
                .fill(isCurrent ? ARCTheme.secOrange : .clear)
                .frame(width: 4, height: 28)

            // Format icon
            Image(systemName: cue.format.icon)
                .font(.system(size: 11))
                .foregroundStyle(isCurrent ? ARCTheme.secOrange : ARCTheme.textTertiary)
                .frame(width: 16)
                .help(cue.formatLabel)

            VStack(alignment: .leading, spacing: 2) {
                Text(cue.title)
                    .font(ARCTheme.mono(13, isCurrent ? .heavy : .bold))
                    .foregroundStyle(isCurrent ? ARCTheme.textPrimary : ARCTheme.textSecondary)
                    .lineLimit(1)
                    .help(cue.title)

                if let speakers = cue.speakers, !speakers.isEmpty {
                    Text(speakers)
                        .font(ARCTheme.mono(11, .regular))
                        .foregroundStyle(ARCTheme.textTertiary)
                        .lineLimit(1)
                }
            }

            Spacer()

            // Time display: dual (scheduled → projected) or just duration
            if let scheduled = cue.startTime {
                timeDisplay(scheduled: scheduled)
            } else {
                Text(cue.formattedDuration)
                    .font(ARCTheme.mono(12, .bold))
                    .foregroundStyle(ARCTheme.textTertiary)
            }
        }
        .padding(.horizontal, ARCTheme.paddingSmall)
        .padding(.vertical, 6)
        .background(
            isCurrent ? ARCTheme.subGroup : .clear,
            in: RoundedRectangle(cornerRadius: 4)
        )
    }

    @ViewBuilder
    private func timeDisplay(scheduled: Date) -> some View {
        let scheduledStr = Self.timeFormatter.string(from: scheduled)

        if let projected = projectedStart, abs(projected.timeIntervalSince(scheduled)) > 30 {
            // Show scheduled → projected when offset is significant
            let projectedStr = Self.timeFormatter.string(from: projected)
            HStack(spacing: 3) {
                Text(scheduledStr)
                    .font(ARCTheme.mono(11, .regular))
                    .foregroundStyle(ARCTheme.textTertiary)
                    .strikethrough(true, color: ARCTheme.textTertiary.opacity(0.5))
                Text(projectedStr)
                    .font(ARCTheme.mono(12, .bold))
                    .foregroundStyle(projected > scheduled ? ARCTheme.warn : ARCTheme.live)
            }
        } else {
            // On time — just show scheduled
            Text(scheduledStr)
                .font(ARCTheme.mono(12, .bold))
                .foregroundStyle(ARCTheme.textTertiary)
        }
    }
}

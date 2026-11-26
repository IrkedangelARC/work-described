//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI

struct SourceRowView: View {
    let source: Source
    let isActive: Bool
    @Environment(SwitcherEngine.self) private var engine

    var body: some View {
        HStack(spacing: 10) {
            // Status dot
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            // App icon
            if let icon = source.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 24, height: 24)
            } else {
                Image(systemName: "app")
                    .font(.system(size: 18))
                    .foregroundStyle(ARCTheme.textTertiary)
                    .frame(width: 24, height: 24)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(source.friendlyName)
                    .font(.system(size: 13, weight: isActive ? .bold : .medium))
                    .foregroundStyle(ARCTheme.textPrimary)
                    .lineLimit(1)

                Text(ProfileRegistry.profile(for: source.bundleIdentifier).displayName)
                    .font(.system(size: 10))
                    .foregroundStyle(ARCTheme.textTertiary)
            }

            Spacer()

            if isActive {
                Text("LIVE")
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(ARCTheme.liveRed, in: RoundedRectangle(cornerRadius: 3))
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if source.isAvailable {
                engine.switchTo(sourceId: source.id)
            }
        }
    }

    private var statusColor: Color {
        if isActive { return ARCTheme.liveRed }
        if source.isAvailable { return ARCTheme.readyGreen }
        return ARCTheme.offlineGray
    }
}

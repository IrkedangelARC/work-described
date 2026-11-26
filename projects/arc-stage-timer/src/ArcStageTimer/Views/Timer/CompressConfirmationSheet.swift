//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI

/// Shows a preview of proposed compression changes before applying.
struct CompressConfirmationSheet: View {
    let proposals: [TimerEngine.CompressionProposal]
    let targetEnd: Date
    let originalEnd: Date
    let deficit: Int
    let onApply: () -> Void

    @Environment(\.dismiss) private var dismiss

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()

    private var totalRecovered: Int {
        proposals.reduce(0) { $0 + $1.savedSeconds }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ARCTheme.background.ignoresSafeArea()

                VStack(spacing: 0) {
                    // Header stats
                    VStack(spacing: 8) {
                        Text("COMPRESS TO FIT")
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .foregroundStyle(ARCTheme.timerYellow)
                            .tracking(2)

                        Text("Recovering \(formatDuration(totalRecovered))")
                            .font(.system(size: 20, weight: .heavy, design: .monospaced))
                            .foregroundStyle(ARCTheme.textPrimary)

                        HStack(spacing: 16) {
                            VStack(spacing: 2) {
                                Text("ORIGINAL END")
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundStyle(ARCTheme.textTertiary)
                                Text(Self.timeFormatter.string(from: originalEnd))
                                    .font(.system(size: 16, weight: .medium, design: .monospaced))
                                    .foregroundStyle(ARCTheme.textSecondary)
                            }

                            Image(systemName: "arrow.right")
                                .foregroundStyle(ARCTheme.timerYellow)

                            VStack(spacing: 2) {
                                Text("TARGET END")
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundStyle(ARCTheme.textTertiary)
                                Text(Self.timeFormatter.string(from: targetEnd))
                                    .font(.system(size: 16, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(ARCTheme.timerGreen)
                            }
                        }
                    }
                    .padding(.vertical, ARCTheme.paddingMedium)
                    .frame(maxWidth: .infinity)
                    .background(ARCTheme.surface)

                    Divider().background(ARCTheme.divider)

                    // Proposal list
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(proposals) { proposal in
                                proposalRow(proposal)
                            }
                        }
                        .padding(.vertical, ARCTheme.paddingSmall)
                    }

                    Divider().background(ARCTheme.divider)

                    // Action buttons
                    HStack(spacing: 16) {
                        Button {
                            dismiss()
                        } label: {
                            Text("CANCEL")
                                .font(.system(size: 14, weight: .bold, design: .monospaced))
                                .foregroundStyle(ARCTheme.textSecondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(ARCTheme.surface, in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)

                        Button {
                            onApply()
                            dismiss()
                        } label: {
                            Text("APPLY")
                                .font(.system(size: 14, weight: .bold, design: .monospaced))
                                .foregroundStyle(ARCTheme.background)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(ARCTheme.timerYellow, in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(ARCTheme.paddingMedium)
                }
            }
            .navigationTitle("Compress Schedule")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
    }

    private func proposalRow(_ proposal: TimerEngine.CompressionProposal) -> some View {
        HStack(spacing: 10) {
            Image(systemName: proposal.format.icon)
                .font(.system(size: 14))
                .foregroundStyle(proposal.format.isCompressible ? ARCTheme.timerYellow : ARCTheme.accent)
                .frame(width: 20)

            Text(proposal.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(ARCTheme.textPrimary)
                .lineLimit(1)

            Spacer()

            // Duration change: original → proposed (-X%)
            HStack(spacing: 4) {
                Text(formatDuration(proposal.originalDuration))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(ARCTheme.textTertiary)
                    .strikethrough(true, color: ARCTheme.textTertiary.opacity(0.5))

                Text(formatDuration(proposal.proposedDuration))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(ARCTheme.timerYellow)

                Text(String(format: "-%d%%", Int(proposal.reductionPercent)))
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(ARCTheme.timerYellow.opacity(0.7))
            }
        }
        .padding(.horizontal, ARCTheme.paddingSmall)
        .padding(.vertical, 6)
    }

    private func formatDuration(_ totalSeconds: Int) -> String {
        let m = totalSeconds / 60
        let s = totalSeconds % 60
        return String(format: "%d:%02d", m, s)
    }
}

import SwiftUI

/// Frequency axis labels for the RTA display
struct FrequencyLabelsView: View {
    let labels: [String]
    let highlightedIndex: Int?
    let alertIndices: Set<Int>

    /// Show every Nth label to avoid crowding
    private var labelStep: Int {
        // Show labels at: 31.5, 63, 125, 250, 500, 1k, 2k, 4k, 8k, 16k (10 labels)
        1 // Show all, but use smaller font
    }

    /// Key frequency indices to always show (powers of 2 roughly)
    private let keyIndices: Set<Int> = [2, 5, 8, 11, 14, 17, 20, 23, 26, 29]

    var body: some View {
        HStack(spacing: Theme.barSpacing) {
            ForEach(Array(labels.enumerated()), id: \.offset) { index, label in
                Text(keyIndices.contains(index) ? label : "")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(labelColor(for: index))
                    .frame(maxWidth: .infinity)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
        }
        .padding(.vertical, 4)
    }

    private func labelColor(for index: Int) -> Color {
        if alertIndices.contains(index) {
            return Color.barAlert
        }
        if index == highlightedIndex {
            return Color.textAccent
        }
        return Color.textSecondary
    }
}

/// Header showing current dominant frequency and feedback alerts
struct DominantFrequencyView: View {
    let band: FrequencyBand
    let hasFeedbackAlert: Bool
    var feedbackBands: [FrequencyBand] = []

    var body: some View {
        HStack(spacing: 12) {
            // Dominant frequency
            VStack(alignment: .leading, spacing: 2) {
                Text("PEAK")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(Color.textSecondary)

                Text(band.label)
                    .font(.system(size: 24, weight: .bold, design: .monospaced))
                    .foregroundColor(hasFeedbackAlert ? Color.barAlert : Color.textAccent)
            }

            Spacer()

            // Feedback frequency display - CENTER
            if hasFeedbackAlert, let primaryFeedback = feedbackBands.first {
                VStack(spacing: 2) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.barAlert)
                            .frame(width: 10, height: 10)
                            .modifier(PulseModifier())
                        Text("FEEDBACK")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(Color.barAlert)
                    }
                    Text(primaryFeedback.label)
                        .font(.system(size: 32, weight: .heavy, design: .monospaced))
                        .foregroundColor(Color.barAlert)
                    if feedbackBands.count > 1 {
                        Text("+" + feedbackBands.dropFirst().map { $0.label }.joined(separator: ", "))
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(Color.barAlert.opacity(0.8))
                    }
                }
            }

            Spacer()

            // Level
            VStack(alignment: .trailing, spacing: 2) {
                Text("LEVEL")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(Color.textSecondary)

                Text(String(format: "%.1f dB", band.magnitude))
                    .font(.system(size: 24, weight: .bold, design: .monospaced))
                    .foregroundColor(Color.textPrimary)
            }
        }
        .padding(.horizontal, Theme.padding)
        .padding(.vertical, Theme.paddingSmall)
        .background(Color.surfaceColor)
    }
}

#Preview {
    VStack(spacing: 8) {
        DominantFrequencyView(
            band: FrequencyBand(id: 17, centerFrequency: 1000, label: "1k"),
            hasFeedbackAlert: true
        )

        FrequencyLabelsView(
            labels: FrequencyConstants.frequencyLabels,
            highlightedIndex: 17,
            alertIndices: [12, 13]
        )
        .frame(height: 20)
    }
    .background(Color.appBackground)
}

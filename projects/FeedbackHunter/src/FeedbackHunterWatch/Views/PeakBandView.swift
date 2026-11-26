import SwiftUI

/// Shows the dominant frequency band on Apple Watch
struct PeakBandView: View {
    let frequencyLabel: String
    let magnitude: Float
    let hasFeedbackAlert: Bool

    var body: some View {
        VStack(spacing: 4) {
            // Label
            Text("PEAK")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.gray)

            // Frequency
            Text(frequencyLabel)
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundColor(hasFeedbackAlert ? .red : .white)

            // Feedback warning
            if hasFeedbackAlert {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                    Text("FEEDBACK")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.red)
                }
                .padding(.top, 2)
            }
        }
    }
}

#Preview {
    VStack(spacing: 20) {
        PeakBandView(
            frequencyLabel: "2.5k",
            magnitude: -8,
            hasFeedbackAlert: false
        )

        PeakBandView(
            frequencyLabel: "4k",
            magnitude: -3,
            hasFeedbackAlert: true
        )
    }
    .padding()
    .background(Color.black)
}

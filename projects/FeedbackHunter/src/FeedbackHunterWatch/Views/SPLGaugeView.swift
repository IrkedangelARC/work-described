import SwiftUI

/// Circular SPL gauge for Apple Watch
/// Shows current level with color-coded arcs
struct SPLGaugeView: View {
    let level: Float
    let hasFeedbackAlert: Bool

    /// dB range for display
    private let dbMin: Float = -60.0
    private let dbMax: Float = 0.0

    /// Level thresholds
    private let safeThreshold: Float = -20.0
    private let cautionThreshold: Float = -6.0

    /// Normalized level (0-1)
    private var normalizedLevel: Double {
        let clamped = max(dbMin, min(dbMax, level))
        return Double((clamped - dbMin) / (dbMax - dbMin))
    }

    var body: some View {
        ZStack {
            // Background arc
            Circle()
                .stroke(Color.gray.opacity(0.2), lineWidth: 12)

            // Level arc
            Circle()
                .trim(from: 0, to: normalizedLevel)
                .stroke(
                    levelColor,
                    style: StrokeStyle(lineWidth: 12, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.1), value: normalizedLevel)

            // Center content
            VStack(spacing: 2) {
                // Level value
                Text(String(format: "%.0f", level))
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundColor(hasFeedbackAlert ? .red : .white)

                Text("dB")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.gray)
            }

            // Alert indicator
            if hasFeedbackAlert {
                Circle()
                    .stroke(Color.red, lineWidth: 3)
                    .opacity(hasFeedbackAlert ? 1 : 0)
                    .animation(
                        Animation.easeInOut(duration: 0.3)
                            .repeatForever(autoreverses: true),
                        value: hasFeedbackAlert
                    )
            }
        }
        .padding(8)
    }

    private var levelColor: Color {
        if level > cautionThreshold {
            return .red
        } else if level > safeThreshold {
            return .yellow
        }
        return .green
    }
}

#Preview {
    SPLGaugeView(level: -12, hasFeedbackAlert: false)
        .frame(width: 150, height: 150)
        .background(Color.black)
}

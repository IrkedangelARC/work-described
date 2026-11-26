import SwiftUI

/// Single frequency bar with peak indicator and alert highlighting
struct FrequencyBarView: View {
    let band: FrequencyBand
    let maxHeight: CGFloat

    /// dB range for display
    private let dbMin: Float = Theme.dbMin
    private let dbMax: Float = Theme.dbMax

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                // Background
                Rectangle()
                    .fill(Color.gridColor)

                // Main bar
                Rectangle()
                    .fill(barColor)
                    .frame(height: barHeight(for: band.magnitude, in: geometry.size.height))

                // Peak indicator
                Rectangle()
                    .fill(Color.barPeak)
                    .frame(height: 2)
                    .offset(y: -peakOffset(in: geometry.size.height))

                // Alert pulse overlay
                if band.isFeedbackAlert {
                    Rectangle()
                        .fill(Color.barAlert.opacity(0.3))
                        .modifier(PulseModifier())
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 2))
    }

    private var barColor: Color {
        switch band.alertState {
        case .feedback:
            return Color.barAlert
        case .sustained:
            return Color.barCaution
        case .caution:
            return Color.barCaution.opacity(0.7)
        case .normal:
            return Color.barNormal
        }
    }

    private func barHeight(for magnitude: Float, in containerHeight: CGFloat) -> CGFloat {
        let normalized = normalize(magnitude)
        return CGFloat(normalized) * containerHeight
    }

    private func peakOffset(in containerHeight: CGFloat) -> CGFloat {
        let normalized = normalize(band.peakMagnitude)
        return CGFloat(normalized) * containerHeight
    }

    private func normalize(_ db: Float) -> Float {
        let clamped = max(dbMin, min(dbMax, db))
        return (clamped - dbMin) / (dbMax - dbMin)
    }
}

/// Pulsing animation for alert state
struct PulseModifier: ViewModifier {
    @State private var isPulsing = false

    func body(content: Content) -> some View {
        content
            .opacity(isPulsing ? 0.5 : 1.0)
            .animation(
                Animation.easeInOut(duration: 0.3)
                    .repeatForever(autoreverses: true),
                value: isPulsing
            )
            .onAppear { isPulsing = true }
    }
}

#Preview {
    HStack(spacing: 2) {
        ForEach(0..<5) { i in
            FrequencyBarView(
                band: FrequencyBand(
                    id: i,
                    centerFrequency: 1000,
                    label: "1k"
                ),
                maxHeight: 200
            )
        }
    }
    .frame(height: 200)
    .padding()
    .background(Color.appBackground)
}

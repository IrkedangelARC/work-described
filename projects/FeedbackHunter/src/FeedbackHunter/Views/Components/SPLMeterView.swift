import SwiftUI

/// Vertical SPL meter with color zones
struct SPLMeterView: View {
    let level: Float
    let peakLevel: Float

    private let dbMin: Float = -60.0
    private let dbMax: Float = 0.0

    private let safeThreshold: Float = -20.0
    private let cautionThreshold: Float = -6.0

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                // Background with grid
                VStack(spacing: 0) {
                    ForEach(0..<6) { i in
                        Rectangle()
                            .fill(Color.gridColor)
                            .frame(height: geometry.size.height / 6)
                            .overlay(
                                Rectangle()
                                    .fill(Color.surfaceColor)
                                    .frame(height: 1),
                                alignment: .top
                            )
                    }
                }

                // Level bar with gradient
                Rectangle()
                    .fill(levelGradient)
                    .frame(height: barHeight(for: level, in: geometry.size.height))

                // Peak indicator line
                Rectangle()
                    .fill(peakColor)
                    .frame(height: 2)
                    .offset(y: -barHeight(for: peakLevel, in: geometry.size.height))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.gridColor, lineWidth: 1)
        )
    }

    private var levelGradient: LinearGradient {
        LinearGradient(
            gradient: Gradient(stops: [
                .init(color: Color.splSafe, location: 0),
                .init(color: Color.splSafe, location: 0.6),
                .init(color: Color.splModerate, location: 0.8),
                .init(color: Color.splHigh, location: 1.0)
            ]),
            startPoint: .bottom,
            endPoint: .top
        )
    }

    private var peakColor: Color {
        if peakLevel > cautionThreshold {
            return Color.barAlert
        } else if peakLevel > safeThreshold {
            return Color.barCaution
        }
        return Color.barPeak
    }

    private func barHeight(for db: Float, in containerHeight: CGFloat) -> CGFloat {
        let normalized = normalize(db)
        return CGFloat(normalized) * containerHeight
    }

    private func normalize(_ db: Float) -> Float {
        let clamped = max(dbMin, min(dbMax, db))
        return (clamped - dbMin) / (dbMax - dbMin)
    }
}

/// Horizontal dB scale labels
struct DBScaleView: View {
    let labels: [String] = ["0", "-10", "-20", "-30", "-40", "-50", "-60"]

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            ForEach(labels, id: \.self) { label in
                Text(label)
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundColor(Color.textSecondary)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
        }
    }
}

#Preview {
    HStack(spacing: 4) {
        DBScaleView()
            .frame(width: 30)

        SPLMeterView(level: -15, peakLevel: -8)
            .frame(width: 30)
    }
    .frame(height: 200)
    .padding()
    .background(Color.appBackground)
}

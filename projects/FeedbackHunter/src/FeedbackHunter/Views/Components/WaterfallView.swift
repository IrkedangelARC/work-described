import SwiftUI

/// Waterfall/Spectrogram display showing frequency over time
struct WaterfallView: View {
    let history: [[Float]]  // Array of magnitude arrays (newest first)
    let bandCount: Int

    /// Number of rows to display (higher = more resolution)
    private var rowCount: Int {
        min(history.count, 400)
    }

    var body: some View {
        Canvas { context, size in
            guard !history.isEmpty, bandCount > 0 else { return }

            let cellWidth = size.width / CGFloat(bandCount)
            let cellHeight = size.height / CGFloat(max(rowCount, 1))

            // Draw from newest (top) to oldest (bottom)
            for (rowIndex, magnitudes) in history.prefix(rowCount).enumerated() {
                let y = CGFloat(rowIndex) * cellHeight

                for (bandIndex, magnitude) in magnitudes.enumerated() {
                    let x = CGFloat(bandIndex) * cellWidth
                    let color = colorForMagnitude(magnitude)

                    let rect = CGRect(x: x, y: y, width: cellWidth + 1, height: cellHeight + 1)
                    context.fill(Path(rect), with: .color(color))
                }
            }
        }
        .background(Color.black)
    }

    /// Map magnitude (dB) to color
    /// -60 dB = black, -40 dB = blue, -20 dB = green, -10 dB = yellow, 0 dB = red
    private func colorForMagnitude(_ magnitude: Float) -> Color {
        let normalized = (magnitude + 60) / 60  // -60 to 0 -> 0 to 1
        let clamped = max(0, min(1, normalized))

        if clamped < 0.25 {
            // Black to Blue
            let t = clamped / 0.25
            return Color(red: 0, green: 0, blue: Double(t))
        } else if clamped < 0.5 {
            // Blue to Green
            let t = (clamped - 0.25) / 0.25
            return Color(red: 0, green: Double(t), blue: Double(1 - t))
        } else if clamped < 0.75 {
            // Green to Yellow
            let t = (clamped - 0.5) / 0.25
            return Color(red: Double(t), green: 1, blue: 0)
        } else {
            // Yellow to Red
            let t = (clamped - 0.75) / 0.25
            return Color(red: 1, green: Double(1 - t), blue: 0)
        }
    }
}

#Preview {
    // Sample data for preview
    let sampleHistory: [[Float]] = (0..<100).map { row in
        (0..<31).map { band in
            Float.random(in: -60...(-10))
        }
    }

    return WaterfallView(history: sampleHistory, bandCount: 31)
        .frame(height: 300)
}

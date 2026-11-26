import SwiftUI

/// Main Watch app view combining SPL gauge and peak band
struct ContentView: View {
    @StateObject private var connectivity = WatchConnectivityManager.shared

    var body: some View {
        VStack(spacing: 8) {
            if let data = connectivity.latestData {
                // SPL Gauge
                SPLGaugeView(
                    level: data.overallLevel,
                    hasFeedbackAlert: data.hasFeedbackAlert
                )
                .frame(maxHeight: .infinity)

                // Peak frequency
                PeakBandView(
                    frequencyLabel: data.dominantFrequencyLabel,
                    magnitude: data.overallLevel,
                    hasFeedbackAlert: data.hasFeedbackAlert
                )
            } else {
                // Waiting for connection
                VStack(spacing: 12) {
                    ProgressView()
                        .progressViewStyle(.circular)

                    Text("Waiting for\niPad...")
                        .font(.footnote)
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .background(Color.black)
    }
}

#Preview {
    ContentView()
}

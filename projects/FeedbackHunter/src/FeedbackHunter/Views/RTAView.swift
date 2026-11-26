import SwiftUI

/// Main Real-Time Analyzer view
struct RTAView: View {
    @StateObject private var viewModel = RTAViewModel()
    @State private var showSettings = false
    @State private var sensitivity: Float = 1.0

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                // Header with dominant frequency and alerts (uses latched feedback)
                DominantFrequencyView(
                    band: viewModel.bands.isEmpty ?
                        FrequencyBand(id: 0, centerFrequency: 0, label: "--") :
                        viewModel.bands[viewModel.dominantBandIndex],
                    hasFeedbackAlert: viewModel.hasLatchedFeedback,
                    feedbackBands: viewModel.latchedFeedbackBands
                )
                .onTapGesture {
                    // Tap to clear latched feedback
                    viewModel.clearFeedbackLatch()
                }

                // Main spectrum display
                HStack(spacing: 8) {
                    // dB scale
                    DBScaleView()
                        .frame(width: 30)

                    // Frequency bars or Waterfall
                    if viewModel.showWaterfall {
                        WaterfallView(
                            history: viewModel.magnitudeHistory,
                            bandCount: viewModel.bands.count
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        spectrumView
                    }

                    // SPL meter
                    SPLMeterView(
                        level: viewModel.overallLevel,
                        peakLevel: viewModel.bands.map { $0.peakMagnitude }.max() ?? -60
                    )
                    .frame(width: 30)
                }
                .padding(.horizontal, Theme.padding)
                .padding(.vertical, Theme.paddingSmall)

                // Frequency labels
                FrequencyLabelsView(
                    labels: viewModel.bands.map { $0.label },
                    highlightedIndex: viewModel.dominantBandIndex,
                    alertIndices: Set(viewModel.bands.enumerated().filter { $0.element.isFeedbackAlert }.map { $0.offset })
                )
                .padding(.horizontal, Theme.padding + 38) // Align with spectrum

                Spacer()

                // Controls
                controlBar
            }
            .background(Color.appBackground)
        }
        .preferredColorScheme(.dark)
        .onAppear {
            sensitivity = viewModel.sensitivity
            Task {
                let hasPermission = await viewModel.requestPermission()
                if hasPermission {
                    viewModel.start()
                }
            }
        }
        .onDisappear {
            viewModel.stop()
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(viewModel: viewModel)
        }
    }

    // MARK: - Subviews

    private var spectrumView: some View {
        HStack(spacing: Theme.barSpacing) {
            ForEach(viewModel.bands) { band in
                FrequencyBarView(
                    band: band,
                    maxHeight: 300
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(gridBackground)
    }

    private var gridBackground: some View {
        VStack(spacing: 0) {
            ForEach(0..<6) { _ in
                Rectangle()
                    .fill(Color.clear)
                    .frame(maxHeight: .infinity)
                    .overlay(
                        Rectangle()
                            .fill(Color.gridColor.opacity(0.5))
                            .frame(height: Theme.gridLineWidth),
                        alignment: .top
                    )
            }
        }
    }

    private var controlBar: some View {
        VStack(spacing: 8) {
            // Sensitivity slider
            HStack(spacing: 12) {
                Image(systemName: "speaker.wave.1")
                    .foregroundColor(Color.textSecondary)
                Slider(value: $sensitivity, in: 0.5...10.0, step: 0.5)
                    .onChange(of: sensitivity) { newValue in
                        viewModel.sensitivity = newValue
                    }
                Image(systemName: "speaker.wave.3")
                    .foregroundColor(Color.textSecondary)
                Text(String(format: "%.1fx", sensitivity))
                    .font(.caption)
                    .foregroundColor(Color.textSecondary)
                    .frame(width: 40)
            }
            .padding(.horizontal, Theme.padding)

            HStack(spacing: 20) {
                // Settings button
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.title2)
                        .foregroundColor(Color.textPrimary)
                }

                // Waterfall toggle button
                Button {
                    viewModel.showWaterfall.toggle()
                } label: {
                    Image(systemName: viewModel.showWaterfall ? "chart.bar.fill" : "water.waves")
                        .font(.title2)
                        .foregroundColor(Color.textPrimary)
                }

                Spacer()

                // Reset button
                Button {
                    viewModel.reset()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.title2)
                        .foregroundColor(Color.textPrimary)
                }

                // Start/Stop button
                Button {
                    viewModel.toggle()
                } label: {
                    Image(systemName: viewModel.isRunning ? "stop.circle.fill" : "play.circle.fill")
                        .font(.system(size: 44))
                        .foregroundColor(viewModel.isRunning ? Color.barAlert : Color.splSafe)
                }
            }
            .padding(.horizontal, Theme.padding)
        }
        .padding(.vertical, Theme.paddingSmall)
        .background(Color.surfaceColor)
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @ObservedObject var viewModel: RTAViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var localSensitivity: Float = 1.0

    var body: some View {
        NavigationStack {
            Form {
                Section("Input") {
                    HStack {
                        Text("Sensitivity")
                        Spacer()
                        Text(String(format: "%.1fx", localSensitivity))
                            .foregroundColor(.secondary)
                            .frame(width: 50)
                    }
                    Slider(value: $localSensitivity, in: 0.5...10.0, step: 0.5)
                        .onChange(of: localSensitivity) { newValue in
                            viewModel.sensitivity = newValue
                        }
                }

                Section("Display") {
                    Toggle("Peak Hold", isOn: $viewModel.peakHoldEnabled)
                    Toggle("Feedback Detection", isOn: $viewModel.feedbackDetectionEnabled)
                }

                Section("About") {
                    LabeledContent("Version", value: "1.0.0")
                    LabeledContent("Sample Rate", value: "\(Int(viewModel.isRunning ? 48000 : 0)) Hz")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                localSensitivity = viewModel.sensitivity
            }
        }
        .preferredColorScheme(.dark)
    }
}

#Preview {
    RTAView()
}

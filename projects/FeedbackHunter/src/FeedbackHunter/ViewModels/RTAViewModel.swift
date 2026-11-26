import Foundation
import Combine
import SwiftUI

/// Main view model coordinating audio capture, FFT, and feedback detection
@MainActor
final class RTAViewModel: ObservableObject {

    // MARK: - Published State

    /// Current frequency band data (31 bands)
    @Published private(set) var bands: [FrequencyBand] = []

    /// Overall SPL level (uncalibrated)
    @Published private(set) var overallLevel: Float = -60.0

    /// Dominant frequency band
    @Published private(set) var dominantBandIndex: Int = 0

    /// Whether audio capture is active
    @Published private(set) var isRunning = false

    /// Current error state
    @Published private(set) var error: AudioError?

    /// Whether any band has feedback alert
    @Published private(set) var hasFeedbackAlert = false

    /// Latched feedback bands (stay displayed until cleared)
    @Published private(set) var latchedFeedbackBands: [FrequencyBand] = []

    /// Whether we have latched feedback to display
    var hasLatchedFeedback: Bool { !latchedFeedbackBands.isEmpty }

    // MARK: - Settings

    @Published var peakHoldEnabled = true
    @Published var feedbackDetectionEnabled = true
    @Published var showWaterfall = false

    /// Input sensitivity/gain (1.0 = unity, range 0.5 to 10.0)
    @Published var sensitivity: Float = 1.0

    // MARK: - Waterfall History

    /// History of magnitude arrays for waterfall display (newest first)
    @Published private(set) var magnitudeHistory: [[Float]] = []

    /// Maximum history frames to keep (about 10 seconds at 60fps)
    private let maxHistoryFrames = 600

    // MARK: - Audio Pipeline

    private let audioCaptureManager: AudioCaptureManager
    private let fftProcessor: FFTProcessor
    private let octaveBandAnalyzer: OctaveBandAnalyzer
    private let feedbackDetector: FeedbackDetector

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Update Timing

    private var lastUpdateTime = Date()
    private let updateInterval: TimeInterval = 1.0 / 60.0 // 60 fps

    // MARK: - Initialization

    init(fftSize: Int = 4096, sampleRate: Double = 48000) {
        // Initialize audio pipeline
        self.audioCaptureManager = AudioCaptureManager(fftSize: fftSize)
        self.fftProcessor = FFTProcessor(fftSize: fftSize, sampleRate: sampleRate)
        self.octaveBandAnalyzer = OctaveBandAnalyzer(fftProcessor: fftProcessor)
        self.feedbackDetector = FeedbackDetector()

        // Initialize bands
        initializeBands()

        // Setup audio callback
        setupAudioCallback()

        // Observe audio manager state
        setupObservers()
    }

    private func initializeBands() {
        bands = (0..<FrequencyConstants.bandCount).map { index in
            FrequencyBand(
                id: index,
                centerFrequency: FrequencyConstants.centerFrequencies[index],
                label: FrequencyConstants.frequencyLabels[index]
            )
        }
    }

    private func setupAudioCallback() {
        audioCaptureManager.onSamples = { [weak self] samples in
            Task { @MainActor in
                self?.processAudioSamples(samples)
            }
        }
    }

    private func setupObservers() {
        audioCaptureManager.$isRunning
            .receive(on: DispatchQueue.main)
            .assign(to: &$isRunning)

        audioCaptureManager.$error
            .receive(on: DispatchQueue.main)
            .assign(to: &$error)
    }

    // MARK: - Audio Processing

    private func processAudioSamples(_ samples: [Float]) {
        // Throttle updates
        let now = Date()
        guard now.timeIntervalSince(lastUpdateTime) >= updateInterval else { return }
        lastUpdateTime = now

        // Apply sensitivity/gain to samples
        let adjustedSamples = samples.map { $0 * sensitivity }

        // Get FFT magnitudes
        let fftMagnitudes = fftProcessor.process(adjustedSamples)

        // Convert to 1/3 octave bands
        let bandMagnitudes = octaveBandAnalyzer.analyze(fftMagnitudes: fftMagnitudes)

        // Update band data
        for (index, magnitude) in bandMagnitudes.enumerated() {
            bands[index].update(magnitude: magnitude)
        }

        // Store history for waterfall display
        magnitudeHistory.insert(bandMagnitudes, at: 0)
        if magnitudeHistory.count > maxHistoryFrames {
            magnitudeHistory.removeLast()
        }

        // Run feedback detection if enabled
        if feedbackDetectionEnabled {
            bands = feedbackDetector.analyze(bands)
            hasFeedbackAlert = bands.contains { $0.isFeedbackAlert }

            // Latch newly detected feedback bands
            if hasFeedbackAlert {
                let newFeedbackBands = bands.filter { $0.isFeedbackAlert }
                for band in newFeedbackBands {
                    if !latchedFeedbackBands.contains(where: { $0.id == band.id }) {
                        latchedFeedbackBands.append(band)
                    }
                }
            }
        }

        // Calculate overall level
        overallLevel = octaveBandAnalyzer.overallLevel(from: bandMagnitudes)

        // Find dominant band
        let dominant = octaveBandAnalyzer.dominantBand(from: bandMagnitudes)
        dominantBandIndex = dominant.index
    }

    // MARK: - Controls

    /// Start audio capture and analysis
    func start() {
        audioCaptureManager.start()
    }

    /// Stop audio capture
    func stop() {
        audioCaptureManager.stop()
    }

    /// Toggle running state
    func toggle() {
        if isRunning {
            stop()
        } else {
            start()
        }
    }

    /// Reset all bands and peaks
    func reset() {
        for i in bands.indices {
            bands[i].reset()
        }
        hasFeedbackAlert = false
        latchedFeedbackBands.removeAll()
        overallLevel = -60.0
    }

    /// Clear only the latched feedback display
    func clearFeedbackLatch() {
        latchedFeedbackBands.removeAll()
    }

    // MARK: - Permissions

    /// Request microphone permission
    func requestPermission() async -> Bool {
        await AudioCaptureManager.checkPermission()
    }
}

// MARK: - Watch Connectivity Data

extension RTAViewModel {
    /// Data package for sending to Watch
    var watchData: WatchData {
        WatchData(
            overallLevel: overallLevel,
            dominantBandIndex: dominantBandIndex,
            dominantFrequency: bands[dominantBandIndex].centerFrequency,
            dominantFrequencyLabel: bands[dominantBandIndex].label,
            hasFeedbackAlert: hasFeedbackAlert
        )
    }
}

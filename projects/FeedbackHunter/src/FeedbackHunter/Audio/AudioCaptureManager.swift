import Foundation
import AVFoundation
import Combine

/// Manages audio capture from microphone using AVAudioEngine
/// Provides a stream of audio samples for FFT analysis
final class AudioCaptureManager: ObservableObject {

    // MARK: - Published State

    @Published private(set) var isRunning = false
    @Published private(set) var audioLevel: Float = 0
    @Published private(set) var error: AudioError?

    // MARK: - Audio Engine

    private let audioEngine = AVAudioEngine()
    private var inputNode: AVAudioInputNode { audioEngine.inputNode }

    // MARK: - Configuration

    /// Target sample rate (will use device rate if different)
    let targetSampleRate: Double = 48000

    /// FFT size determines buffer size
    let fftSize: Int

    /// Actual sample rate being used
    private(set) var actualSampleRate: Double = 48000

    // MARK: - Callbacks

    /// Called with new audio samples (fftSize samples at a time)
    var onSamples: (([Float]) -> Void)?

    // MARK: - Sample Buffer

    private var sampleBuffer: [Float] = []
    private let bufferQueue = DispatchQueue(label: "com.feedbackhunter.audio.buffer")

    // MARK: - Initialization

    init(fftSize: Int = 4096) {
        self.fftSize = fftSize
        self.sampleBuffer.reserveCapacity(fftSize * 2)
    }

    // MARK: - Audio Session

    /// Configure audio session for recording
    func configureAudioSession() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true)
        actualSampleRate = session.sampleRate
        #else
        actualSampleRate = targetSampleRate
        #endif
    }

    // MARK: - Start/Stop

    /// Start audio capture
    func start() {
        guard !isRunning else { return }

        do {
            try configureAudioSession()
            try setupAudioTap()
            try audioEngine.start()
            isRunning = true
            error = nil
        } catch let err as AudioError {
            error = err
        } catch {
            self.error = .captureError(error.localizedDescription)
        }
    }

    /// Stop audio capture
    func stop() {
        guard isRunning else { return }

        audioEngine.stop()
        inputNode.removeTap(onBus: 0)
        isRunning = false

        bufferQueue.async { [weak self] in
            self?.sampleBuffer.removeAll()
        }
    }

    // MARK: - Audio Tap Setup

    private func setupAudioTap() throws {
        let format = inputNode.outputFormat(forBus: 0)

        guard format.sampleRate > 0 else {
            throw AudioError.noMicrophone
        }

        actualSampleRate = format.sampleRate

        // Install tap on input node
        inputNode.installTap(onBus: 0, bufferSize: AVAudioFrameCount(fftSize), format: format) { [weak self] buffer, _ in
            self?.processAudioBuffer(buffer)
        }
    }

    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }

        let frameCount = Int(buffer.frameLength)
        let samples = Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))

        // Calculate audio level (RMS)
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(frameCount))
        let level = 20 * log10f(max(rms, 1e-10))

        DispatchQueue.main.async { [weak self] in
            self?.audioLevel = level
        }

        // Add to buffer and emit when we have enough samples
        bufferQueue.async { [weak self] in
            guard let self = self else { return }

            self.sampleBuffer.append(contentsOf: samples)

            while self.sampleBuffer.count >= self.fftSize {
                let fftSamples = Array(self.sampleBuffer.prefix(self.fftSize))
                self.sampleBuffer.removeFirst(self.fftSize / 2) // 50% overlap

                self.onSamples?(fftSamples)
            }
        }
    }

    // MARK: - Permissions

    /// Check microphone permission status
    static func checkPermission() async -> Bool {
        #if os(iOS)
        if #available(iOS 17.0, *) {
            return await AVAudioApplication.requestRecordPermission()
        } else {
            return await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        }
        #else
        return true
        #endif
    }
}

// MARK: - Errors

enum AudioError: LocalizedError {
    case noMicrophone
    case permissionDenied
    case captureError(String)

    var errorDescription: String? {
        switch self {
        case .noMicrophone:
            return "No microphone available"
        case .permissionDenied:
            return "Microphone permission denied"
        case .captureError(let message):
            return "Audio capture error: \(message)"
        }
    }
}

// Need to import Accelerate for vDSP
import Accelerate

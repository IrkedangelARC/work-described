import AVFoundation
import CoreAudio
import Foundation

/// Per-channel measurement of an input device, used by Test Microphone.
struct ChannelLevel {
    let channel: Int        // zero-based
    let peakDB: Float
    let rmsDB: Float
}

/// Listens to every channel of a device for a fixed spell and reports each one's level.
/// This is how you find out which jack the mic is actually in, and whether the gain is up.
final class LevelProbe {

    private let engine = AVAudioEngine()
    private var peaks: [Float] = []
    private var sumOfSquares: [Double] = []
    private var frameCount: Double = 0
    private var finished = false

    /// - Parameter completion: called on the main queue, once.
    func run(deviceID: AudioDeviceID?,
             seconds: TimeInterval,
             onProgress: ((Float) -> Void)? = nil,
             completion: @escaping (Result<[ChannelLevel], Error>) -> Void) {

        let input = engine.inputNode

        if let deviceID, let unit = input.audioUnit {
            var device = deviceID
            let status = AudioUnitSetProperty(unit,
                                              kAudioOutputUnitProperty_CurrentDevice,
                                              kAudioUnitScope_Global,
                                              0,
                                              &device,
                                              UInt32(MemoryLayout<AudioDeviceID>.size))
            guard status == noErr else {
                completion(.failure(RecorderError.deviceUnavailable))
                return
            }
        }

        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            completion(.failure(RecorderError.noInputFormat))
            return
        }

        let channels = Int(format.channelCount)
        peaks = Array(repeating: 0, count: channels)
        sumOfSquares = Array(repeating: 0, count: channels)
        frameCount = 0

        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            self?.accumulate(buffer, onProgress: onProgress)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            completion(.failure(error))
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, !self.finished else { return }
            self.finished = true
            self.engine.inputNode.removeTap(onBus: 0)
            self.engine.stop()

            let frames = max(self.frameCount, 1)
            let levels = (0..<channels).map { channel in
                ChannelLevel(channel: channel,
                             peakDB: Self.decibels(self.peaks[channel]),
                             rmsDB: Self.decibels(Float(sqrt(self.sumOfSquares[channel] / frames))))
            }
            completion(.success(levels))
        }
    }

    private func accumulate(_ buffer: AVAudioPCMBuffer, onProgress: ((Float) -> Void)?) {
        guard let data = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }

        let channels = peaks.count
        let interleaved = buffer.format.isInterleaved
        let stride = Int(buffer.format.channelCount)
        var loudest: Float = 0

        for channel in 0..<channels {
            var peak: Float = 0
            var squares: Double = 0
            let source = interleaved ? data[0] : data[channel]

            for frame in 0..<frames {
                let sample = interleaved ? source[frame * stride + channel] : source[frame]
                peak = max(peak, abs(sample))
                squares += Double(sample) * Double(sample)
            }

            peaks[channel] = max(peaks[channel], peak)
            sumOfSquares[channel] += squares
            loudest = max(loudest, peak)
        }

        frameCount += Double(frames)
        if let onProgress {
            DispatchQueue.main.async { onProgress(Self.decibels(loudest)) }
        }
    }

    static func decibels(_ amplitude: Float) -> Float {
        amplitude <= 0.0000001 ? -120 : 20 * log10f(amplitude)
    }
}

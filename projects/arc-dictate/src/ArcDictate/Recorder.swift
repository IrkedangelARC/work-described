import AVFoundation
import CoreAudio
import Foundation

enum RecorderError: LocalizedError {
    case deviceUnavailable
    case noInputFormat
    case converterFailed

    var errorDescription: String? {
        switch self {
        case .deviceUnavailable: return "Could not open that input device."
        case .noInputFormat: return "The input device reported no usable format."
        case .converterFailed: return "Could not set up the 16 kHz sample rate conversion."
        }
    }
}

/// Pulls one channel out of a capture buffer. Split out from the recorder so the interleaved
/// and non-interleaved paths can be tested against synthetic buffers.
enum ChannelExtractor {

    /// - Returns: the number of frames written to `destination`.
    @discardableResult
    static func extract(from buffer: AVAudioPCMBuffer,
                        channel: Int,
                        into destination: UnsafeMutablePointer<Float>,
                        capacity: Int) -> Int {
        guard let source = buffer.floatChannelData else { return 0 }
        let channelCount = Int(buffer.format.channelCount)
        guard channelCount > 0, channel >= 0, channel < channelCount else { return 0 }

        let frames = min(Int(buffer.frameLength), capacity)
        guard frames > 0 else { return 0 }

        if buffer.format.isInterleaved {
            let interleaved = source[0]
            for frame in 0..<frames {
                destination[frame] = interleaved[frame * channelCount + channel]
            }
        } else {
            destination.update(from: source[channel], count: frames)
        }
        return frames
    }

    /// Peak magnitude of `count` samples, in dBFS.
    static func peakDecibels(_ samples: UnsafePointer<Float>, count: Int) -> Float {
        var peak: Float = 0
        for index in 0..<count { peak = max(peak, abs(samples[index])) }
        return peak <= 0.0000001 ? -120 : 20 * log10f(peak)
    }
}

/// Captures ONE channel of an input device and writes 16 kHz mono WAV, which is what
/// whisper wants. Taking a single channel rather than letting Core Audio downmix is the
/// whole point: a 4-in interface with a mic on channel 1 loses ~12 dB in a 4 -> 1 downmix,
/// which is enough to push a quiet talker under the VAD threshold.
///
/// The audio tap does no allocation, no locking and no file I/O. It extracts, converts, and
/// hands samples to a ring buffer; a writer queue drains the ring to disk.
final class Recorder {

    private static let maxTapFrames = 16_384
    private static let ringSeconds = 60

    private let engine = AVAudioEngine()
    private let ring = AudioRingBuffer(capacity: 16_000 * ringSeconds)
    private let writerQueue = DispatchQueue(label: "com.example.arc.ArcDictate.writer", qos: .utility)

    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var writerTimer: DispatchSourceTimer?

    // Preallocated so the tap never allocates.
    private var monoBuffer: AVAudioPCMBuffer?
    private var convertedBuffer: AVAudioPCMBuffer?
    private var drainBuffer: AVAudioPCMBuffer?

    private var sourceChannel = 0

    private(set) var isRecording = false
    private(set) var startedAt: Date?

    /// Peak level of the captured channel since the last reset, in dBFS.
    private(set) var peakDB: Float = -120

    /// Called on the main queue with the peak of each captured block, in dBFS, so the
    /// interface can show a live meter.
    var onLevel: ((Float) -> Void)?

    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: 16_000,
                                             channels: 1,
                                             interleaved: false)!

    func start(deviceID: AudioDeviceID?, channel: Int, to url: URL) throws {
        guard !isRecording else { return }

        let input = engine.inputNode

        if let deviceID, let unit = input.audioUnit {
            var device = deviceID
            let status = AudioUnitSetProperty(unit,
                                              kAudioOutputUnitProperty_CurrentDevice,
                                              kAudioUnitScope_Global,
                                              0,
                                              &device,
                                              UInt32(MemoryLayout<AudioDeviceID>.size))
            guard status == noErr else { throw RecorderError.deviceUnavailable }
        }

        let hardware = input.inputFormat(forBus: 0)
        guard hardware.sampleRate > 0, hardware.channelCount > 0 else { throw RecorderError.noInputFormat }

        sourceChannel = min(max(channel, 0), Int(hardware.channelCount) - 1)

        guard let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                       sampleRate: hardware.sampleRate,
                                       channels: 1,
                                       interleaved: false),
              let converter = AVAudioConverter(from: mono, to: outputFormat),
              let monoBuffer = AVAudioPCMBuffer(pcmFormat: mono,
                                                frameCapacity: AVAudioFrameCount(Self.maxTapFrames)),
              let convertedBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat,
                                                     frameCapacity: AVAudioFrameCount(Self.convertedCapacity(from: hardware.sampleRate))),
              let drainBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 16_000)
        else { throw RecorderError.converterFailed }

        self.converter = converter
        self.monoBuffer = monoBuffer
        self.convertedBuffer = convertedBuffer
        self.drainBuffer = drainBuffer

        file = try AVAudioFile(forWriting: url,
                               settings: [AVFormatIDKey: kAudioFormatLinearPCM,
                                          AVSampleRateKey: 16_000,
                                          AVNumberOfChannelsKey: 1,
                                          AVLinearPCMBitDepthKey: 16,
                                          AVLinearPCMIsFloatKey: false,
                                          AVLinearPCMIsBigEndianKey: false,
                                          AVLinearPCMIsNonInterleaved: false],
                               commonFormat: .pcmFormatFloat32,
                               interleaved: false)

        peakDB = -120
        ring.reset()

        input.installTap(onBus: 0, bufferSize: 4096, format: hardware) { [weak self] buffer, _ in
            self?.capture(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            file = nil
            throw error
        }

        startWriter()
        isRecording = true
        startedAt = Date()
    }

    /// Stops the engine, drains what is left, and returns the recorded duration in seconds.
    @discardableResult
    func stop() -> TimeInterval {
        guard isRecording else { return 0 }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        writerTimer?.cancel()
        writerTimer = nil

        // Final drain and close, synchronously, so the WAV is complete when this returns.
        writerQueue.sync { self.drain() }

        let duration = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        file = nil          // closing the AVAudioFile finalises the WAV header
        converter = nil
        monoBuffer = nil
        convertedBuffer = nil
        drainBuffer = nil
        isRecording = false
        startedAt = nil
        onLevel = nil
        return duration
    }

    /// Samples the ring had to drop because the writer fell behind. Should always be zero.
    var droppedSamples: Int { ring.droppedSamples }

    // MARK: - Real-time path

    private func capture(_ buffer: AVAudioPCMBuffer) {
        guard let converter, let monoBuffer, let convertedBuffer,
              let monoData = monoBuffer.floatChannelData?[0] else { return }

        let frames = ChannelExtractor.extract(from: buffer,
                                              channel: sourceChannel,
                                              into: monoData,
                                              capacity: Self.maxTapFrames)
        guard frames > 0 else { return }
        monoBuffer.frameLength = AVAudioFrameCount(frames)

        let blockDB = ChannelExtractor.peakDecibels(monoData, count: frames)
        peakDB = max(peakDB, blockDB)
        if let onLevel {
            DispatchQueue.main.async { onLevel(blockDB) }
        }

        var supplied = false
        var error: NSError?
        convertedBuffer.frameLength = 0
        converter.convert(to: convertedBuffer, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return monoBuffer
        }

        guard error == nil,
              convertedBuffer.frameLength > 0,
              let convertedData = convertedBuffer.floatChannelData?[0] else { return }

        ring.write(convertedData, count: Int(convertedBuffer.frameLength))
    }

    // MARK: - Writer

    private func startWriter() {
        let timer = DispatchSource.makeTimerSource(queue: writerQueue)
        timer.schedule(deadline: .now() + 0.1, repeating: 0.1)
        timer.setEventHandler { [weak self] in self?.drain() }
        timer.resume()
        writerTimer = timer
    }

    /// Runs on `writerQueue` only.
    private func drain() {
        guard let file, let drainBuffer, let destination = drainBuffer.floatChannelData?[0] else { return }
        while true {
            let count = ring.read(into: destination, maxCount: Int(drainBuffer.frameCapacity))
            guard count > 0 else { return }
            drainBuffer.frameLength = AVAudioFrameCount(count)
            try? file.write(from: drainBuffer)
        }
    }

    private static func convertedCapacity(from sampleRate: Double) -> Int {
        Int((Double(maxTapFrames) * 16_000 / sampleRate).rounded(.up)) + 64
    }
}

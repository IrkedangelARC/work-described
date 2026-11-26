//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import AVFoundation
import CoreAudio
import ARCShowFormat

/// A WAV file whose header is kept true while it is written: the RIFF and data sizes are rewritten every
/// few seconds, so a crash or a kill leaves a file every tool reads up to the last flush. (AVAudioFile only
/// writes the sizes when it closes; a crash left a 0-byte data chunk.)
final class WavWriter {
    let url: URL
    let sampleRate: Int
    let channels: Int
    private let handle: FileHandle
    private(set) var dataBytes: Int = 0
    private var lastHeaderAt = Date()
    let headerInterval: TimeInterval

    init(url: URL, sampleRate: Int, channels: Int, headerInterval: TimeInterval = 5) throws {
        self.url = url; self.sampleRate = sampleRate; self.channels = channels; self.headerInterval = headerInterval
        try? FileManager.default.removeItem(at: url)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: Self.header(dataBytes: 0, sampleRate: sampleRate, channels: channels))
    }

    static func header(dataBytes: Int, sampleRate: Int, channels: Int) -> Data {
        var d = Data()
        func u32(_ v: Int) { var x = UInt32(truncatingIfNeeded: v).littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: Int) { var x = UInt16(truncatingIfNeeded: v).littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataBytes); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(channels); u32(sampleRate)
        u32(sampleRate * channels * 2); u16(channels * 2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(dataBytes)
        return d
    }

    /// Interleaved 16-bit samples.
    func append(_ data: Data) throws {
        try handle.write(contentsOf: data)
        dataBytes += data.count
        if Date().timeIntervalSince(lastHeaderAt) >= headerInterval { try updateHeader() }
    }

    func updateHeader() throws {
        let end = try handle.offset()
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Self.header(dataBytes: dataBytes, sampleRate: sampleRate, channels: channels))
        try handle.seek(toOffset: end)
        try handle.synchronize()
        lastHeaderAt = Date()
    }

    func close() {
        try? updateHeader()
        try? handle.close()
    }
}

/// The scratch track (plan section 4): room sound from any input, AAC mono 16 kHz 24 kb/s for the whole
/// session, so the importer can find the offset to each camera by cross-correlation (sync is its only job;
/// measured: the offset found is the same as from the full-rate WAV). About 11 MB per hour, never a
/// deliverable. Survives a crash (AacTrackWriter's fragments) and an input that goes away (the engine's
/// configuration-change notification restarts the tap on what is left, appending to the same file).
final class ScratchAudio {
    struct Device: Identifiable, Hashable {
        let id: AudioDeviceID
        let uid: String
        let name: String
    }

    private var engine = AVAudioEngine()
    private var wav: AacTrackWriter?
    private var converter: AVAudioConverter?
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
    private(set) var startMono: Double?
    private(set) var framesWritten: Int64 = 0
    /// Last buffer's level, dBFS (-160 when silent), for the meter.
    private(set) var levelDB: Float = -160
    private let lock = NSLock()
    private(set) var isRunning = false
    private(set) var lastError: String?
    private var device: Device?
    private var observer: NSObjectProtocol?
    /// Called on a restart after the input changed (the operator's log).
    var onRestart: ((String) -> Void)?

    /// Input devices, as Audio MIDI Setup names them.
    static func inputDevices() -> [Device] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            var n: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &n) == noErr, n > 0 else { return nil }
            return Device(id: id, uid: string(id, kAudioDevicePropertyDeviceUID) ?? "\(id)", name: string(id, kAudioObjectPropertyName) ?? "Input \(id)")
        }
    }

    /// The device System Settings calls the default input.
    static func defaultInputUID() -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return string(id, kAudioDevicePropertyDeviceUID)
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0) }
        return status == noErr ? value as String? : nil
    }

    /// Start recording `device` (nil = the system default input) into `url`.
    func start(device: Device?, to url: URL) throws {
        stop()
        self.device = device
        wav = try AacTrackWriter(url: url, sampleRate: targetFormat.sampleRate, bitRate: 24_000)
        framesWritten = 0
        startMono = nil
        try startEngine()
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil) { [weak self] _ in
            self?.restart()
        }
        isRunning = true
    }

    private func startEngine() throws {
        engine = AVAudioEngine()
        let input = engine.inputNode
        if let device, let unit = input.audioUnit, Self.inputDevices().contains(where: { $0.id == device.id }) {
            var id = device.id
            let st = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size))
            if st != noErr { lastError = "could not select \(device.name) (\(st)); using the default input" }
        }
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else { throw NSError(domain: "ArcSlideLog", code: 2, userInfo: [NSLocalizedDescriptionKey: "the input has no format (no microphone consent, or no input device)"]) }
        guard let conv = AVAudioConverter(from: inFormat, to: targetFormat) else { throw NSError(domain: "ArcSlideLog", code: 3, userInfo: [NSLocalizedDescriptionKey: "no converter to 16 kHz mono"]) }
        lock.lock(); converter = conv; lock.unlock()
        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buffer, _ in self?.handle(buffer) }
        try engine.start()
    }

    /// The input changed (unplugged, replugged, a default switch): the engine is dead; build a new one on
    /// whatever input is there now and keep appending to the same file.
    private func restart() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        do {
            try startEngine()
            onRestart?("scratch input changed; recording continues on \(engine.inputNode.outputFormat(forBus: 0).sampleRate > 0 ? "the current input" : "nothing")")
        } catch {
            lastError = "scratch input lost: \(error.localizedDescription)"
            onRestart?(lastError!)
            // Try again in 3 s: a USB interface takes a moment to come back.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.restart() }
        }
    }

    private func handle(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        if startMono == nil { startMono = SlideTrack.monotonicSeconds() - Double(buffer.frameLength) / buffer.format.sampleRate }
        if let ch = buffer.floatChannelData?[0], buffer.frameLength > 0 {
            var sum: Float = 0
            for i in 0..<Int(buffer.frameLength) { sum += ch[i] * ch[i] }
            let rms = (sum / Float(buffer.frameLength)).squareRoot()
            levelDB = rms > 0 ? max(-160, 20 * log10(rms)) : -160
        }
        guard let converter, let wav else { return }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true; status.pointee = .haveData; return buffer
        }
        guard error == nil, out.frameLength > 0, let p = out.int16ChannelData?[0] else { return }
        do {
            try wav.append(p, count: Int(out.frameLength))
            framesWritten += Int64(out.frameLength)
        } catch { lastError = error.localizedDescription }
    }

    var seconds: Double { Double(framesWritten) / targetFormat.sampleRate }

    func stop() {
        guard isRunning else { return }
        if let observer { NotificationCenter.default.removeObserver(observer) }; observer = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.lock(); wav?.close(); wav = nil; converter = nil; lock.unlock()
        isRunning = false
    }
}

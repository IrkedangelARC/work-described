//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import AVFoundation
import Foundation
import ScopeKit
import Synchronization

enum AudioEngineError: LocalizedError {
    case noInput
    case pinFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .noInput: return "The interface reports no input channels."
        case .pinFailed(let s): return "Could not select the interface (error \(s))."
        }
    }
}

/// Which outputs the generator plays on, set from the main thread and read by the output callback.
final class OutputRoute: @unchecked Sendable {
    let mode = Atomic<Int>(0)
}

/// Input from one interface into lock-free rings, one per channel (input 1 = mic, input 2 = reference).
///
/// The render callback only copies into the rings. It never locks, allocates or touches the model;
/// `MeterProcessor` drains the rings on its own queue.
///
/// macOS: one engine = one device. The interface is pinned as the engine's input AND output, the
/// combination docs/STEP0.md measured on the AMS-24. Pinning: karaoke `PitchTracker.swift:205`.
final class AudioEngine {
    static let maxChannels = 2
    let rings: [SPSCRing] = (0..<AudioEngine.maxChannels).map { _ in SPSCRing(minimumCapacity: 1 << 16) }

    /// What the generator played, sample for sample: the transfer function's reference when no
    /// console feed is patched in. Written by the output callback (zeros while the generator is off).
    let generatorRing = SPSCRing(minimumCapacity: 1 << 16)
    /// The test signal source. Nil when the interface has no outputs.
    private(set) var generator: SignalGenerator?
    /// Which outputs the generator plays on: 0 = 1 and 2, 1 = output 1, 2 = output 2.
    let route = OutputRoute()

    private(set) var sampleRate = 48_000.0
    private(set) var channelCount = 0
    private(set) var deviceName = ""
    private var engine: AVAudioEngine?

    var isRunning: Bool { engine?.isRunning ?? false }

    func start(device: AudioInputDevice?) throws {
        stop()
        let engine = AVAudioEngine()

        #if os(macOS)
        if let device {
            DeviceCatalog.setSampleRate(device, 48_000)
            try pin(engine.inputNode.audioUnit, to: device.deviceID)
            if device.outputChannels > 0 { try pin(engine.outputNode.audioUnit, to: device.deviceID) }
        }
        #else
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker])
        try session.setPreferredSampleRate(48_000)
        try session.setPreferredIOBufferDuration(0.01)
        if let device, let port = session.availableInputs?.first(where: { $0.portName == device.name }) {
            try session.setPreferredInput(port)
        }
        try session.setActive(true)
        #endif

        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else { throw AudioEngineError.noInput }

        let rings = self.rings
        let sink = AVAudioSinkNode { _, frameCount, bufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
            for c in 0..<min(buffers.count, rings.count) {
                if let data = buffers[c].mData {
                    rings[c].write(data.assumingMemoryBound(to: Float.self), count: Int(frameCount))
                }
            }
            return noErr
        }
        engine.attach(sink)
        engine.connect(engine.inputNode, to: sink, format: format)

        generator = nil
        #if os(macOS)
        let canPlay = (device?.outputChannels ?? 0) > 0
        #else
        let canPlay = true
        #endif
        if canPlay, let stereo = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 2) {
            let gen = SignalGenerator(sampleRate: format.sampleRate)
            let played = generatorRing
            let source = AVAudioSourceNode(format: stereo) { [route] silence, _, frameCount, bufferList -> OSStatus in
                let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
                let n = Int(frameCount)
                guard let first = buffers.first?.mData?.assumingMemoryBound(to: Float.self) else { return noErr }
                gen.render(into: first, count: n)
                played.write(first, count: n)
                let mode = route.mode.load(ordering: .relaxed)
                if buffers.count > 1, let second = buffers[1].mData?.assumingMemoryBound(to: Float.self) {
                    if mode == 1 { second.update(repeating: 0, count: n) } else { second.update(from: first, count: n) }
                    if mode == 2 { first.update(repeating: 0, count: n) }
                }
                if !gen.audible { silence.pointee = true }
                return noErr
            }
            engine.attach(source)
            engine.connect(source, to: engine.mainMixerNode, format: stereo)
            engine.mainMixerNode.outputVolume = 1
            generator = gen
        }

        for r in rings { r.drain() }
        generatorRing.drain()
        engine.prepare()
        try engine.start()

        self.engine = engine
        sampleRate = format.sampleRate
        channelCount = min(Int(format.channelCount), Self.maxChannels)
        deviceName = device?.name ?? ""
    }

    func stop() {
        engine?.stop()
        engine = nil
        generator = nil
        channelCount = 0
    }

    #if os(macOS)
    private func pin(_ unit: AudioUnit?, to device: AudioObjectID) throws {
        guard let unit else { throw AudioEngineError.pinFailed(-1) }
        var d = device
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                          &d, UInt32(MemoryLayout<AudioObjectID>.size))
        guard status == noErr else { throw AudioEngineError.pinFailed(status) }
    }
    #endif
}

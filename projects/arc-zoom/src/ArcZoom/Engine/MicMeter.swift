//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import AVFoundation
import CoreAudio

/// A level meter on the microphone the SDK sends. The Zoom SDK has no in-meeting mic meter (its level
/// callbacks only run during its own mic test), so this taps the device itself; macOS lets two clients
/// read one microphone. It follows the SDK's selection by device name (audit P1: it metered the system
/// default while the operator had picked another mic), and says which device it is on.
@MainActor
@Observable
final class MicMeter {
    /// 0...1, a peak-ish level with a fast attack and a slow release, so it reads like a meter.
    private(set) var level: Float = 0
    private(set) var isRunning = false
    private(set) var error: String?
    /// "Insta360 Link 2" or "system default": what the meter is actually listening to.
    private(set) var deviceLabel = "system default"
    /// Buffers the tap has delivered since start, and the loudest sample in them: a meter at zero with
    /// buffers arriving is a QUIET mic; at zero with no buffers it is a tap that is not running; buffers
    /// arriving with a peak of exactly 0 is macOS handing over silence, which is what a denied
    /// microphone grant looks like (no error, all zeros).
    private(set) var buffersSeen = 0
    private(set) var peakEver: Float = 0
    /// The loudest raw sample per channel since start: on a 4-input interface this says which input
    /// the mic is actually on (the MOTU M4, 2026-09-21).
    private(set) var channelPeaks: [Float] = []
    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var wantedName: String?

    /// `deviceNamed` nil or "Same as system" = the system default input.
    func start(deviceNamed name: String? = nil) {
        guard !isRunning else { return }
        wantedName = name
        buffersSeen = 0; peakEver = 0; channelPeaks = []
        let e = AVAudioEngine()
        let input = e.inputNode
        deviceLabel = "system default"
        if let name, name != "Same as system", let id = Self.inputDeviceID(named: name), let unit = input.audioUnit {
            var dev = id
            let err = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
            if err == noErr { deviceLabel = name } else { ShowLog.log("mic meter: could not select \(name) (\(err)); metering the system default") }
        }
        ShowLog.log("mic meter on \(deviceLabel)")
        let format = input.inputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else { error = "no input device"; return }
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            guard let data = buffer.floatChannelData else { return }
            let n = Int(buffer.frameLength)
            guard n > 0 else { return }
            var peak: Float = 0
            let channels = Int(buffer.format.channelCount)
            var perChannel = [Float](repeating: 0, count: channels)
            for c in 0..<channels {
                let p = data[c]
                var cp: Float = 0
                for i in stride(from: 0, to: n, by: 4) { cp = max(cp, abs(p[i])) }
                perChannel[c] = cp
                peak = max(peak, cp)
            }
            // -50 dBFS floor to 0 dBFS full scale.
            let db = 20 * log10(max(peak, 1e-6))
            let scaled = max(0, min(1, (db + 50) / 50))
            Task { @MainActor in
                guard let self else { return }
                self.buffersSeen += 1
                self.peakEver = max(self.peakEver, peak)
                if self.channelPeaks.count != channels { self.channelPeaks = perChannel }
                else { for c in 0..<channels { self.channelPeaks[c] = max(self.channelPeaks[c], perChannel[c]) } }
                self.level = scaled > self.level ? scaled : self.level * 0.85 + scaled * 0.15
            }
        }
        do {
            try e.start()
            engine = e
            isRunning = true
            error = nil
        } catch {
            self.error = "mic meter: \(error.localizedDescription)"
            input.removeTap(onBus: 0)
        }
    }

    func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        isRunning = false
        level = 0
    }

    /// The SDK's mic changed: follow it (no-op when already on that device).
    func restart(deviceNamed name: String?) {
        guard isRunning, name != wantedName else { return }
        stop(); start(deviceNamed: name)
    }

    /// CoreAudio input device with this name, if present.
    nonisolated static func inputDeviceID(named name: String) -> AudioDeviceID? { deviceID(named: name, input: true) }
    /// CoreAudio output device with this name, if present (the pre-flight tone plays to the speaker the call will use).
    nonisolated static func outputDeviceID(named name: String) -> AudioDeviceID? { deviceID(named: name, input: false) }

    /// The name of the system default input or output device: what "Same as system" means right now.
    nonisolated static func systemDefaultDeviceName(input: Bool) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        var nameAddr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var cf: Unmanaged<CFString>?
        var nsize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &nsize, &cf) == noErr, let cf else { return nil }
        return cf.takeRetainedValue() as String
    }

    /// A device by name that has channels in the wanted direction. The same name can front two devices
    /// (an interface's input and output), so the direction is part of the match.
    nonisolated static func deviceID(named name: String, input: Bool) -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return nil }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return nil }
        for id in ids {
            var nameAddr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var cf: Unmanaged<CFString>?
            var nsize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &nsize, &cf) == noErr, let cf else { continue }
            let devName = cf.takeRetainedValue() as String
            guard devName == name else { continue }
            // Capable in the wanted direction? (has stream configuration channels on that scope)
            var inAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
            var bsize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &inAddr, 0, nil, &bsize) == noErr, bsize > 0 else { continue }
            let buf = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(bsize)); defer { buf.deallocate() }
            guard AudioObjectGetPropertyData(id, &inAddr, 0, nil, &bsize, buf) == noErr else { continue }
            let channels = UnsafeMutableAudioBufferListPointer(buf).reduce(0) { $0 + Int($1.mNumberChannels) }
            if channels > 0 { return id }
        }
        return nil
    }
}

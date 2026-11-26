//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation
import CoreAudio
import AudioToolbox
import os

// MARK: - One tap + aggregate + IO proc

/// A live process tap on one app, played through one output device. Owns the
/// three HAL objects and tears them down in order. Not @MainActor: created and
/// closed from the engine, rendered on the IO thread through `TapState`.
final class TapSession: @unchecked Sendable {
    enum Result: @unchecked Sendable { case success(TapSession), failure(String) }

    private let tapID: AudioObjectID
    private let aggregateID: AudioObjectID
    private let procID: AudioDeviceIOProcID
    let state: TapState
    private var closed = false

    private init(tapID: AudioObjectID, aggregateID: AudioObjectID, procID: AudioDeviceIOProcID, state: TapState) {
        self.tapID = tapID; self.aggregateID = aggregateID; self.procID = procID; self.state = state
    }

    static func open(source: MusicEngine.Source, output: MusicEngine.Output,
                     queue: DispatchQueue, uid: String, pfl: MusicEngine.Output? = nil) -> Result {
        let state = TapState()
        // 1. Tap: stereo mixdown of every process under the app, muted at the
        //    source so the room hears only OUR gain stage.
        let desc = CATapDescription(stereoMixdownOfProcesses: source.objectIDs)
        desc.uuid = UUID()
        desc.name = "ARC Presenter MUSIC"
        desc.muteBehavior = .mutedWhenTapped
        desc.isPrivate = true
        var tapID: AudioObjectID = kAudioObjectUnknown
        var err = AudioHardwareCreateProcessTap(desc, &tapID)
        guard err == noErr, tapID != kAudioObjectUnknown else {
            return .failure("Tap failed (\(describe(err))). Allow ARC Presenter under System Settings › Privacy & Security › Screen & System Audio Recording.")
        }

        // 2. The tap's stream layout, so the IO proc knows which input buffers
        //    are the tap (they come AFTER the output device's own input streams).
        var format = AudioStreamBasicDescription()
        if let f: AudioStreamBasicDescription = CoreAudioProps.value(tapID, CoreAudioProps.address(kAudioTapPropertyFormat)) {
            format = f
        } else {
            format.mChannelsPerFrame = 2
            format.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
        }
        state.configure(channels: max(1, Int(format.mChannelsPerFrame)),
                        interleaved: (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0)

        // 3. Private aggregate: output device (main, clock) + tap, drift compensated.
        // PFL (2026-09-19): the PFL device rides in the same aggregate as a second sub-device, drift
        // compensated against the main one; its output streams follow the main device's in the output
        // ABL, so the IO proc writes the pre-fader signal there at the PFL gain and the room never hears it.
        var subDevices: [[String: Any]] = [[kAudioSubDeviceUIDKey: output.uid]]
        if let pfl, pfl.uid != output.uid {
            subDevices.append([kAudioSubDeviceUIDKey: pfl.uid, kAudioSubDeviceDriftCompensationKey: 1])
            let mainStreams: [AudioObjectID] = CoreAudioProps.array(output.deviceID, CoreAudioProps.address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput))
            state.configurePFL(bufferIndex: max(1, mainStreams.count))
        }
        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "ARC Presenter MUSIC",
            kAudioAggregateDeviceUIDKey: uid,
            kAudioAggregateDeviceMainSubDeviceKey: output.uid,
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceIsStackedKey: 0,
            kAudioAggregateDeviceTapAutoStartKey: 1,
            kAudioAggregateDeviceSubDeviceListKey: subDevices,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: desc.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: 1,
            ]],
        ]
        var aggregateID: AudioObjectID = kAudioObjectUnknown
        err = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggregateID)
        guard err == noErr, aggregateID != kAudioObjectUnknown else {
            AudioHardwareDestroyProcessTap(tapID)
            return .failure("Aggregate device failed (\(describe(err)))")
        }

        // 4. IO proc: tap input → gain → output.
        var procID: AudioDeviceIOProcID?
        err = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { _, inputData, _, outputData, _ in
            state.render(input: inputData, output: outputData)
        }
        guard err == noErr, let procID else {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            AudioHardwareDestroyProcessTap(tapID)
            return .failure("IO proc failed (\(describe(err)))")
        }
        err = AudioDeviceStart(aggregateID, procID)
        guard err == noErr else {
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            AudioHardwareDestroyAggregateDevice(aggregateID)
            AudioHardwareDestroyProcessTap(tapID)
            return .failure("Device start failed (\(describe(err)))")
        }
        return .success(TapSession(tapID: tapID, aggregateID: aggregateID, procID: procID, state: state))
    }

    /// Keep the app muted but play nothing: the session gets its own silent
    /// state so the engine's fader state can move on to the next app.
    func hold() {
        state.detach()
    }

    func close() {
        guard !closed else { return }
        closed = true
        AudioDeviceStop(aggregateID, procID)
        AudioDeviceDestroyIOProcID(aggregateID, procID)
        AudioHardwareDestroyAggregateDevice(aggregateID)
        AudioHardwareDestroyProcessTap(tapID)
    }

    deinit { close() }

    private static func describe(_ err: OSStatus) -> String {
        let code = UInt32(bitPattern: err)
        let bytes = [24, 16, 8, 0].map { UInt8((code >> UInt32($0)) & 0xFF) }
        if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) {
            return "'\(String(bytes: bytes, encoding: .ascii) ?? "")' \(err)"
        }
        return "\(err)"
    }
}

// MARK: - Realtime state (IO proc side; no allocation, one short lock)

/// Everything the Core Audio IO thread touches. The main actor sets a target
/// gain; the IO proc ramps its running gain toward it across each buffer
/// (no zipper), applies it while copying tap input to device output, and
/// leaves max-hold peaks for the meter to read and reset.
final class TapState: @unchecked Sendable {
    private struct Shared {
        var targetGain: Float = 0
        var targetPFLGain: Float = 0
        var pflPeak: Float = 0
        var peakL: Float = 0
        var peakR: Float = 0
        /// The tap's INPUT, before the gain: signal present whatever the fader says (2026-09-19).
        var inPeakL: Float = 0
        var inPeakR: Float = 0
    }
    private let shared = OSAllocatedUnfairLock(initialState: Shared())
    // Written before the device starts, read only on the IO thread after.
    private var channels = 2
    private var interleaved = true
    private var gain: Float = 0
    private var pflGain: Float = 0
    /// Index of the PFL device's first output buffer in the aggregate's output ABL; nil = no PFL device.
    private var pflBuffer: Int?

    func configurePFL(bufferIndex: Int) { pflBuffer = bufferIndex }
    func setTargetPFLGain(_ g: Float) { shared.withLock { $0.targetPFLGain = max(0, min(1, g)) } }
    func readPFLPeak() -> Float { shared.withLock { s in let p = s.pflPeak; s.pflPeak = 0; return p } }

    func configure(channels: Int, interleaved: Bool) {
        self.channels = max(1, channels)
        self.interleaved = interleaved
    }

    func setTargetGain(_ g: Float) {
        shared.withLock { $0.targetGain = max(0, min(1, g)) }
    }

    /// A held session's IO proc keeps running (that is what keeps the app
    /// muted) but must output silence whatever the fader does next.
    private let detached = OSAllocatedUnfairLock(initialState: false)
    func detach() { detached.withLock { $0 = true } }

    /// Read-and-reset so a stalled IO thread decays the meter to silence.
    func readPeaks() -> (Float, Float) {
        shared.withLock { s in
            let out = (s.peakL, s.peakR)
            s.peakL = 0; s.peakR = 0
            return out
        }
    }
    /// Pre-fader, read-and-reset like the post-fader pair.
    func readInputPeaks() -> (Float, Float) {
        shared.withLock { s in
            let out = (s.inPeakL, s.inPeakR)
            s.inPeakL = 0; s.inPeakR = 0
            return out
        }
    }

    func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
        let outABL = UnsafeMutableAudioBufferListPointer(output)
        // Start from silence on every output stream (multi-channel interfaces
        // get music on 1+2 only).
        for buf in outABL {
            if let p = buf.mData { memset(p, 0, Int(buf.mDataByteSize)) }
        }

        guard !detached.withLock({ $0 }) else { return }

        let inABL = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let tapBuffers = interleaved ? 1 : channels
        guard inABL.count >= tapBuffers, let outBuf = outABL.first, let outData = outBuf.mData else { return }
        let firstTap = inABL.count - tapBuffers

        // Locate L and R sample runs in the tap's buffers (sub-device input
        // streams, if the output device has any, sit before the tap's).
        var lPtr: UnsafeMutablePointer<Float>?
        var rPtr: UnsafeMutablePointer<Float>?
        var stride = 1
        var frames = 0
        if interleaved {
            let buf = inABL[firstTap]
            guard let data = buf.mData else { return }
            let ch = max(1, Int(buf.mNumberChannels))
            stride = ch
            frames = Int(buf.mDataByteSize) / (ch * MemoryLayout<Float>.size)
            lPtr = data.assumingMemoryBound(to: Float.self)
            rPtr = ch > 1 ? lPtr! + 1 : lPtr
        } else {
            guard let l = inABL[firstTap].mData else { return }
            frames = Int(inABL[firstTap].mDataByteSize) / MemoryLayout<Float>.size
            lPtr = l.assumingMemoryBound(to: Float.self)
            rPtr = tapBuffers > 1 ? inABL[firstTap + 1].mData?.assumingMemoryBound(to: Float.self) ?? lPtr : lPtr
        }
        guard let l = lPtr, let r = rPtr, frames > 0 else { return }

        let outCh = max(1, Int(outBuf.mNumberChannels))
        let outFrames = Int(outBuf.mDataByteSize) / (outCh * MemoryLayout<Float>.size)
        let n = min(frames, outFrames)
        guard n > 0 else { return }
        let out = outData.assumingMemoryBound(to: Float.self)

        let (target, pflTarget) = shared.withLock { ($0.targetGain, $0.targetPFLGain) }
        var g = gain
        let step = (target - g) / Float(n)
        // PFL: the pre-fader signal into the PFL device's buffer at its own ramped gain.
        var pflPeak: Float = 0
        if let idx = pflBuffer, idx < outABL.count, let pflData = outABL[idx].mData {
            let pch = max(1, Int(outABL[idx].mNumberChannels))
            let pframes = Int(outABL[idx].mDataByteSize) / (pch * MemoryLayout<Float>.size)
            let pn = min(n, pframes)
            let pout = pflData.assumingMemoryBound(to: Float.self)
            var pg = pflGain
            let pstep = (pflTarget - pg) / Float(max(1, pn))
            for i in 0..<pn {
                pg += pstep
                let a = l[i * stride] * pg, b = r[i * stride] * pg
                if pch == 1 { pout[i] = (a + b) * 0.5 } else { pout[i * pch] = a; pout[i * pch + 1] = b }
                pflPeak = max(pflPeak, max(abs(a), abs(b)))
            }
            pflGain = pflTarget
        }
        var peakL: Float = 0, peakR: Float = 0
        var inL: Float = 0, inR: Float = 0

        if outCh == 1 {
            for i in 0..<n {
                g += step
                let a = l[i * stride], b = r[i * stride]
                inL = max(inL, abs(a)); inR = max(inR, abs(b))
                let s = (a + b) * 0.5 * g
                out[i] = s
                peakL = max(peakL, abs(s))
            }
            peakR = peakL
        } else {
            for i in 0..<n {
                g += step
                let a = l[i * stride], b = r[i * stride]
                inL = max(inL, abs(a)); inR = max(inR, abs(b))
                let sl = a * g
                let sr = b * g
                out[i * outCh] = sl
                out[i * outCh + 1] = sr
                peakL = max(peakL, abs(sl))
                peakR = max(peakR, abs(sr))
            }
        }
        gain = target

        let pl = min(peakL, 1), pr = min(peakR, 1), il = min(inL, 1), ir = min(inR, 1)
        let pp = min(pflPeak, 1)
        shared.withLock { s in
            s.peakL = max(s.peakL, pl)
            s.peakR = max(s.peakR, pr)
            s.inPeakL = max(s.inPeakL, il)
            s.inPeakR = max(s.inPeakR, ir)
            s.pflPeak = max(s.pflPeak, pp)
        }
    }
}

// MARK: - Core Audio property helpers

enum CoreAudioProps {
    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func value<T>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> T? {
        var addr = address
        guard AudioObjectHasProperty(object, &addr) else { return nil }
        var size = UInt32(MemoryLayout<T>.size)
        let ptr = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { ptr.deallocate() }
        let err = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, ptr)
        guard err == noErr else { return nil }
        return ptr.pointee
    }

    static func array<T>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> [T] {
        var addr = address
        guard AudioObjectHasProperty(object, &addr) else { return [] }
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<T>.size
        return [T](unsafeUninitializedCapacity: count) { buf, initialized in
            let err = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, buf.baseAddress!)
            initialized = err == noErr ? Int(size) / MemoryLayout<T>.size : 0
        }
    }

    static func string(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> String? {
        var addr = address
        guard AudioObjectHasProperty(object, &addr) else { return nil }
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>? = nil
        let err = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0)
        }
        guard err == noErr, let v = value else { return nil }
        return v.takeRetainedValue() as String
    }
}

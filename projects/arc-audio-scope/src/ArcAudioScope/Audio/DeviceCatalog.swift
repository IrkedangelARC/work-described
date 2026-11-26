//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import AVFoundation
import Foundation
#if os(macOS)
import CoreAudio
#endif

/// One interface the scope can measure through. Resolved by NAME, never by index or id
/// (karaoke's proven rule, docs/REUSE_karaoke.md A.1): ids change on every replug.
struct AudioInputDevice: Identifiable, Hashable {
    let name: String
    let inputChannels: Int
    let outputChannels: Int
    #if os(macOS)
    let deviceID: AudioObjectID
    #endif
    var id: String { name }
}

/// Source: the walk in karaoke/KaraokeKit/Sources/KaraokeKit/AudioRouter.swift `DeviceCatalog`,
/// rewritten for input devices with channel counts.
enum DeviceCatalog {
    #if os(macOS)
    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func channels(_ id: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Int {
        var a = address(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func name(_ id: AudioObjectID) -> String? {
        var a = address(kAudioObjectPropertyName)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var ref: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &ref) == noErr, let ref else { return nil }
        return ref.takeRetainedValue() as String
    }

    /// Every device with at least one input channel. An output-only box never offers itself as a mic.
    static func inputDevices() -> [AudioInputDevice] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var a = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &a, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            let ins = channels(id, kAudioObjectPropertyScopeInput)
            guard ins > 0, let n = name(id) else { return nil }
            return AudioInputDevice(name: n, inputChannels: ins, outputChannels: channels(id, kAudioObjectPropertyScopeOutput), deviceID: id)
        }
    }

    /// The system's default input, for a first launch with nothing chosen yet.
    static func defaultInputName() -> String? {
        var a = address(kAudioHardwarePropertyDefaultInputDevice)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var id = AudioObjectID(0)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &id) == noErr else { return nil }
        return name(id)
    }

    /// Ask the device for `rate` if it offers it. Returns the rate it ends up at.
    @discardableResult
    static func setSampleRate(_ device: AudioInputDevice, _ rate: Double) -> Double {
        var a = address(kAudioDevicePropertyNominalSampleRate)
        var size = UInt32(MemoryLayout<Float64>.size)
        var now: Float64 = 0
        AudioObjectGetPropertyData(device.deviceID, &a, 0, nil, &size, &now)
        guard now != rate else { return now }
        var want = rate
        if AudioObjectSetPropertyData(device.deviceID, &a, 0, nil, size, &want) == noErr {
            // The device reports the new rate a moment after it accepts it.
            for _ in 0..<20 {
                AudioObjectGetPropertyData(device.deviceID, &a, 0, nil, &size, &now)
                if now == rate { break }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        return now
    }

    /// Calls `handler` on the main queue whenever a device is plugged or unplugged.
    static func onDevicesChanged(_ handler: @escaping () -> Void) {
        var a = address(kAudioHardwarePropertyDevices)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, .main) { _, _ in handler() }
    }
    #else
    /// iPadOS routes one input at a time: the USB interface when it is plugged in.
    static func inputDevices() -> [AudioInputDevice] {
        let session = AVAudioSession.sharedInstance()
        let ports = session.availableInputs ?? []
        return ports.map {
            AudioInputDevice(name: $0.portName, inputChannels: max($0.channels?.count ?? 1, 1), outputChannels: 0)
        }
    }

    static func defaultInputName() -> String? {
        AVAudioSession.sharedInstance().currentRoute.inputs.first?.portName
    }

    static func onDevicesChanged(_ handler: @escaping () -> Void) {
        NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { _ in handler() }
    }
    #endif
}

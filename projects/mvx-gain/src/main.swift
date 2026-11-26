//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//  MVX Gain: menu bar preamp gain for a Shure MVX2U (and any USB input whose
//  CoreAudio input volume is settable in dB), so show Macs never need MOTIV Mix
//  and its virtual audio driver. CoreAudio only: no driver, no plug-in, no helper.
//  Plan: ~/Desktop/MVX-Gain-Plan.md
//

import AVFoundation
import AudioToolbox
import CoreAudio
import SwiftUI
import os

/// Field diagnostics: `log show --predicate 'subsystem == "com.example.arc.mvxgain"' --last 1h`
let log = Logger(subsystem: "com.example.arc.mvxgain", category: "gain")

// MARK: - CoreAudio helpers

struct InputDevice: Identifiable, Hashable {
    let id: AudioObjectID
    let name: String
    let uid: String
    let minDB: Float
    let maxDB: Float
    /// False for interfaces whose preamp is a physical knob (Shure X2u): they are still
    /// listed, because the Mac-input and audio-reset buttons are what fix Zoom losing them.
    let hasGain: Bool
    let hasMute: Bool
    var isShure: Bool { name.localizedCaseInsensitiveContains("shure") }
}

enum CA {
    static func addr(_ selector: AudioObjectPropertySelector,
                     _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func has(_ id: AudioObjectID, _ a: AudioObjectPropertyAddress) -> Bool {
        var a = a
        return AudioObjectHasProperty(id, &a)
    }

    static func settable(_ id: AudioObjectID, _ a: AudioObjectPropertyAddress) -> Bool {
        var a = a
        var ok: DarwinBoolean = false
        return AudioObjectIsPropertySettable(id, &a, &ok) == noErr && ok.boolValue
    }

    static func getFloat(_ id: AudioObjectID, _ a: AudioObjectPropertyAddress) -> Float32? {
        var a = a, v: Float32 = 0, size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v) == noErr ? v : nil
    }

    static func getUInt32(_ id: AudioObjectID, _ a: AudioObjectPropertyAddress) -> UInt32? {
        var a = a, v: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v) == noErr ? v : nil
    }

    static func getRange(_ id: AudioObjectID, _ a: AudioObjectPropertyAddress) -> AudioValueRange? {
        var a = a, v = AudioValueRange(), size = UInt32(MemoryLayout<AudioValueRange>.size)
        return AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v) == noErr ? v : nil
    }

    @discardableResult
    static func setFloat(_ id: AudioObjectID, _ a: AudioObjectPropertyAddress, _ value: Float32) -> OSStatus {
        var a = a, v = value
        return AudioObjectSetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
    }

    @discardableResult
    static func setUInt32(_ id: AudioObjectID, _ a: AudioObjectPropertyAddress, _ value: UInt32) -> OSStatus {
        var a = a, v = value
        return AudioObjectSetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &v)
    }

    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var a = addr(selector)
        var ref: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &ref) == noErr, let ref else { return nil }
        return ref.takeRetainedValue() as String
    }

    static func deviceIDs() -> [AudioObjectID] {
        var a = addr(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static let volumeDB = addr(kAudioDevicePropertyVolumeDecibels, kAudioDevicePropertyScopeInput)
    static let volumeRange = addr(kAudioDevicePropertyVolumeRangeDecibels, kAudioDevicePropertyScopeInput)
    static let mute = addr(kAudioDevicePropertyMute, kAudioDevicePropertyScopeInput)

    /// Eligible = USB transport AND a settable input volume in dB. Virtual devices
    /// (MOTIV Mix Virtual, BlackHole) fail the transport test on their own.
    static func inputChannels(_ id: AudioObjectID) -> Int {
        var a = addr(kAudioDevicePropertyStreamConfiguration, kAudioDevicePropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    /// Eligible = USB transport with at least one input channel. Virtual devices
    /// (MOTIV Mix Virtual, BlackHole) fail the transport test on their own. An X2u
    /// shows as TWO devices named "Shure Digital"; only the input half passes.
    static func eligible(_ id: AudioObjectID) -> InputDevice? {
        guard getUInt32(id, addr(kAudioDevicePropertyTransportType)) == kAudioDeviceTransportTypeUSB,
              inputChannels(id) > 0
        else { return nil }
        let name = string(id, kAudioObjectPropertyName) ?? "USB input"
        let uid = string(id, kAudioDevicePropertyDeviceUID) ?? "\(id)"
        var lo: Float = 0, hi: Float = 0, gain = false
        if has(id, volumeDB), settable(id, volumeDB), let r = getRange(id, volumeRange), r.mMaximum > r.mMinimum {
            lo = Float(r.mMinimum); hi = Float(r.mMaximum); gain = true
        }
        return InputDevice(id: id, name: name, uid: uid, minDB: lo, maxDB: hi,
                           hasGain: gain, hasMute: has(id, mute) && settable(id, mute))
    }
}

// MARK: - Model

final class GainModel: ObservableObject {
    @Published var devices: [InputDevice] = []
    @Published var gainDB: Float = 0
    @Published var muted = false
    @Published var peakDB: Float = -60
    @Published var meterNote: String?
    @Published var isDefaultInput = false
    @Published var resetting = false
    /// MOTIV Mix's virtual driver lives in coreaudiod and is the prime suspect for
    /// Zoom losing the mic (plan section 1). Neither button below cures it while installed.
    @Published var motivDriverInstalled = false
    static let motivDriverPath = "/Library/Audio/Plug-Ins/HAL/ShureVirtualAudio.driver"
    @Published var presets: [Int] {
        didSet { defaults.set(presets, forKey: "presets") }
    }
    @Published var restoreOnConnect: Bool {
        didSet { defaults.set(restoreOnConnect, forKey: "restoreOnConnect") }
    }
    @Published var preferredUID: String? {
        didSet { defaults.set(preferredUID, forKey: "preferredUID"); readCurrent() }
    }

    private let defaults = UserDefaults.standard
    private var knownUIDs: Set<String> = []
    private var watched: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private var engine: AVAudioEngine?
    /// The meter opens the mic (orange dot); it may run ONLY while the panel is visible.
    var panelOpen = false

    var current: InputDevice? {
        devices.first { $0.uid == preferredUID } ?? devices.first
    }

    init() {
        presets = (defaults.array(forKey: "presets") as? [Int]) ?? [24, 36, 48]
        restoreOnConnect = defaults.object(forKey: "restoreOnConnect") as? Bool ?? true
        preferredUID = defaults.string(forKey: "preferredUID")
        var a = CA.addr(kAudioHardwarePropertyDevices)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, .main) { [weak self] _, _ in
            self?.refresh()
        }
        var def = CA.addr(kAudioHardwarePropertyDefaultInputDevice)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &def, .main) { [weak self] _, _ in
            self?.readCurrent()
        }
        refresh()
    }

    func refresh() {
        let found = CA.deviceIDs().compactMap(CA.eligible)
            .sorted { ($0.isShure ? 0 : 1, $0.hasGain ? 0 : 1, $0.name) < ($1.isShure ? 0 : 1, $1.hasGain ? 0 : 1, $1.name) }
        // Restore BEFORE reading: a device that resets on replug would otherwise
        // overwrite its remembered gain with the reset value.
        for d in found where !knownUIDs.contains(d.uid) && d.hasGain {
            if restoreOnConnect, let saved = defaults.object(forKey: "gain.\(d.uid)") as? Float {
                let target = min(max(saved, d.minDB), d.maxDB)
                let st = CA.setFloat(d.id, CA.volumeDB, target)
                log.notice("restore \(d.name, privacy: .public) -> \(target) dB (status \(st))")
            }
        }
        let gone = knownUIDs.subtracting(found.map(\.uid))
        if !gone.isEmpty { log.notice("unplugged: \(gone.joined(separator: ","), privacy: .public)") }
        for d in found where !knownUIDs.contains(d.uid) {
            log.notice("connected \(d.name, privacy: .public) uid=\(d.uid, privacy: .public) gain \(d.hasGain ? "\(d.minDB)...\(d.maxDB) dB" : "hardware knob")")
        }
        knownUIDs = Set(found.map(\.uid))
        let live = Set(found.map(\.id))
        for (id, block) in watched where !live.contains(id) {
            for var a in [CA.volumeDB, CA.mute] { AudioObjectRemovePropertyListenerBlock(id, &a, .main, block) }
            watched[id] = nil
        }
        for d in found where watched[d.id] == nil {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.readCurrent() }
            for var a in [CA.volumeDB, CA.mute] { AudioObjectAddPropertyListenerBlock(d.id, &a, .main, block) }
            watched[d.id] = block
        }
        devices = found
        readCurrent()
    }

    func readCurrent() {
        guard let d = current else { return }
        if d.hasGain, let v = CA.getFloat(d.id, CA.volumeDB) {
            gainDB = v
            defaults.set(v, forKey: "gain.\(d.uid)")
        }
        muted = (CA.getUInt32(d.id, CA.mute) ?? 0) != 0
        isDefaultInput = CA.getUInt32(AudioObjectID(kAudioObjectSystemObject),
                                      CA.addr(kAudioHardwarePropertyDefaultInputDevice)) == d.id
        motivDriverInstalled = FileManager.default.fileExists(atPath: Self.motivDriverPath)
    }

    /// Zoom set to "Same as System" follows the Mac default input; this needs no
    /// password and interrupts nothing.
    func makeDefaultInput() {
        guard let d = current else { return }
        let st = CA.setUInt32(AudioObjectID(kAudioObjectSystemObject),
                              CA.addr(kAudioHardwarePropertyDefaultInputDevice), d.id)
        log.notice("default input -> \(d.name, privacy: .public) (status \(st))")
        readCurrent()
    }

    /// Restarts coreaudiod (launchd brings it straight back). Every app re-reads the
    /// device list, which is what makes Zoom list a mic it had lost. Interrupts ALL
    /// audio for a few seconds, a live Zoom call included, so it is confirmed first.
    func resetAudioSystem() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Restart macOS audio?"
        alert.informativeText = "Every app loses audio for a few seconds, including a Zoom call in progress. "
            + "Zoom then rescans and should list the mic again. Asks for an administrator password."
        alert.addButton(withTitle: "Restart Audio")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        resetting = true
        log.notice("audio reset requested")
        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            task.arguments = ["-e", "do shell script \"/usr/bin/killall coreaudiod\" with administrator privileges"]
            var status: Int32 = -1
            do { try task.run(); task.waitUntilExit(); status = task.terminationStatus } catch {}
            log.notice("audio reset finished: status \(status)")
            // coreaudiod needs a moment to come back; the device listener normally fires,
            // this is the fallback.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                self.resetting = false
                self.knownUIDs = []  // re-apply remembered gain after the restart
                self.refresh()
            }
        }
    }

    func setGain(_ db: Float) {
        guard let d = current, d.hasGain else { return }
        let target = min(max(db.rounded(), d.minDB), d.maxDB)
        guard target != gainDB.rounded() else { return }  // slider ticks repeat the same step
        let st = CA.setFloat(d.id, CA.volumeDB, target)
        if st != noErr { log.error("set gain \(target) dB failed: \(st)") }
        readCurrent()  // show what the device accepted; it may round
    }

    func toggleMute() {
        guard let d = current, CA.has(d.id, CA.mute) else { return }
        let st = CA.setUInt32(d.id, CA.mute, muted ? 0 : 1)
        log.notice("mute -> \(!self.muted) (status \(st))")
        readCurrent()
    }

    // MARK: Meter, only while the panel is open

    func startMeter() {
        stopMeter()
        guard panelOpen, let d = current else { return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                DispatchQueue.main.async { if ok { self.startMeter() } else { self.meterNote = "Allow microphone access in System Settings" } }
            }
            return
        default:
            meterNote = "Allow microphone access in System Settings"
            return
        }
        meterNote = nil
        let engine = AVAudioEngine()
        let input = engine.inputNode
        guard let au = input.audioUnit else { return }
        var devID = d.id
        guard AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                   &devID, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr else { return }
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0, fmt.channelCount > 0 else { return }
        input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak self] buf, _ in
            guard let ch = buf.floatChannelData else { return }
            var peak: Float = 0
            for c in 0..<Int(buf.format.channelCount) {
                for i in 0..<Int(buf.frameLength) { peak = max(peak, abs(ch[c][i])) }
            }
            let db = peak > 0 ? 20 * log10(peak) : -120
            DispatchQueue.main.async {
                guard let self else { return }
                self.peakDB = max(-60, min(0, max(db, self.peakDB - 1.5)))
            }
        }
        do {
            try engine.start()
            self.engine = engine
        } catch {
            input.removeTap(onBus: 0)
            meterNote = "Meter unavailable"
            log.error("meter start failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func stopMeter() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        peakDB = -60
    }
}

// MARK: - UI

struct PanelView: View {
    @ObservedObject var model: GainModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let d = model.current {
                HStack {
                    Text(d.name).font(.headline).lineLimit(1)
                    Spacer()
                    if model.devices.count > 1 {
                        Picker("", selection: Binding(get: { d.uid }, set: { model.preferredUID = $0 })) {
                            ForEach(model.devices) { Text($0.name).tag($0.uid) }
                        }
                        .labelsHidden()
                        .frame(width: 110)
                    }
                }
                if d.hasGain {
                HStack(alignment: .firstTextBaseline) {
                    Text("Gain").foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(model.gainDB.rounded())) dB")
                        .font(.system(size: 28, weight: .semibold, design: .monospaced))
                }
                Slider(value: Binding(get: { model.gainDB }, set: { model.setGain($0) }),
                       in: d.minDB...d.maxDB, step: 1)
                HStack {
                    ForEach(model.presets.indices, id: \.self) { i in
                        Button("\(model.presets[i]) dB") { model.setGain(Float(model.presets[i])) }
                            .contextMenu {
                                Button("Set to current") { model.presets[i] = Int(model.gainDB.rounded()) }
                            }
                    }
                    Spacer()
                    if d.hasMute { muteButton }
                }
                } else {
                    HStack {
                        Text("Gain is set on the device (hardware knob)")
                            .font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        if d.hasMute { muteButton }
                    }
                }
                MeterView(db: model.peakDB, note: model.meterNote)
                HStack {
                    if model.isDefaultInput {
                        Label("Mac input", systemImage: "checkmark.circle.fill")
                            .font(.caption).foregroundStyle(.green)
                    } else {
                        Button("Use as Mac input") { model.makeDefaultInput() }
                    }
                    Spacer()
                    Button(model.resetting ? "Resetting…" : "Reset audio…") { model.resetAudioSystem() }
                        .disabled(model.resetting)
                        .help("Restart macOS audio so Zoom rescans its mics. Interrupts all audio briefly.")
                }
                if d.hasGain {
                    Toggle("Restore gain when plugged in", isOn: $model.restoreOnConnect)
                }
            } else {
                Text("No USB mic found.")
                    .foregroundStyle(.secondary)
                Button(model.resetting ? "Resetting…" : "Reset audio…") { model.resetAudioSystem() }
                    .disabled(model.resetting)
            }
            if model.motivDriverInstalled {
                Text("MOTIV Mix audio driver is installed. It is the likely cause of Zoom losing the mic: uninstall MOTIV Mix and restart.")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .padding(14)
        .frame(width: 280)
        .onAppear { model.panelOpen = true; model.startMeter() }
        .onDisappear { model.panelOpen = false; model.stopMeter() }
        .onChange(of: model.current?.uid) { _ in model.startMeter() }
        // Belt and braces: clicking away closes the panel and deactivates the app,
        // and onDisappear is not guaranteed for MenuBarExtra windows on every macOS.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.panelOpen = true
            model.startMeter()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            model.panelOpen = false
            model.stopMeter()
        }
    }
}

extension PanelView {
    var muteButton: some View {
        Button(model.muted ? "Unmute" : "Mute") { model.toggleMute() }
            .tint(model.muted ? .red : nil)
            .buttonStyle(.borderedProminent)
    }
}

struct MeterView: View {
    let db: Float
    let note: String?

    var body: some View {
        if let note {
            Text(note).font(.caption).foregroundStyle(.secondary)
        } else {
            HStack {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2).fill(Color.secondary.opacity(0.2))
                        RoundedRectangle(cornerRadius: 2).fill(color)
                            .frame(width: g.size.width * CGFloat((db + 60) / 60))
                    }
                }
                .frame(height: 8)
                Text(db <= -60 ? "-inf dBFS" : "\(Int(db.rounded())) dBFS")
                    .font(.caption.monospaced())
                    .frame(width: 70, alignment: .trailing)
            }
        }
    }

    private var color: Color { db > -3 ? .red : db >= -12 ? .yellow : .green }
}

@main
struct MVXGainApp: App {
    @StateObject private var model = GainModel()

    var body: some Scene {
        MenuBarExtra {
            PanelView(model: model)
        } label: {
            if model.current == nil {
                Image(systemName: "mic")
            } else {
                Image(systemName: model.muted ? "mic.slash.fill" : "mic.fill")
                if model.current?.hasGain == true {
                    Text("\(Int(model.gainDB.rounded()))")
                }
            }
        }
        .menuBarExtraStyle(.window)
    }
}

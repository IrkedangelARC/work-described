// ARC Audio Scope, step 0 measurements on the Mac (plan items 2, 3, 6).
// Build and run: tools/step0/run_step0_mac.sh
// Plays SILENCE only. Sets the interface to 48 kHz (the plan's default rate).
// Usage: step0_mac [device name fragment, default "AMS-24"] [seconds, default 5]

import AVFoundation
import Accelerate
import CoreAudio
import Foundation

let fragment = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AMS-24"
let seconds = CommandLine.arguments.count > 2 ? Double(CommandLine.arguments[2]) ?? 5 : 5
let targetRate = 48_000.0

func addr(_ sel: AudioObjectPropertySelector,
          _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func getArray<T>(_ obj: AudioObjectID, _ a: AudioObjectPropertyAddress, _ zero: T) -> [T] {
    var a = a
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(obj, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
    var out = [T](repeating: zero, count: Int(size) / MemoryLayout<T>.stride)
    guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &out) == noErr else { return [] }
    return out
}

func getOne<T>(_ obj: AudioObjectID, _ a: AudioObjectPropertyAddress, _ zero: T) -> T? {
    var a = a
    var size = UInt32(MemoryLayout<T>.stride)
    var out = zero
    guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &out) == noErr else { return nil }
    return out
}

func name(_ obj: AudioObjectID) -> String {
    var a = addr(kAudioObjectPropertyName)
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.stride)
    var ref: Unmanaged<CFString>?
    guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &ref) == noErr, let r = ref else { return "?" }
    return r.takeRetainedValue() as String
}

func db(_ v: Float) -> String { v > 0 ? String(format: "%.1f", 20 * log10(v)) : "-inf" }

// ---------------------------------------------------------------- device
let system = AudioObjectID(kAudioObjectSystemObject)
let devices = getArray(system, addr(kAudioHardwarePropertyDevices), AudioObjectID(0))
guard let dev = devices.first(where: { name($0).localizedCaseInsensitiveContains(fragment) }) else {
    print("FAIL: no device matching \"\(fragment)\". Present: \(devices.map(name))")
    exit(1)
}
print("DEVICE: \(name(dev)) (id \(dev))")
let transport = getOne(dev, addr(kAudioDevicePropertyTransportType), UInt32(0)) ?? 0
print("transport: \(transport == kAudioDeviceTransportTypeUSB ? "USB" : String(transport))")

let rates = getArray(dev, addr(kAudioDevicePropertyAvailableNominalSampleRates), AudioValueRange())
print("available rates: \(rates.map { Int($0.mMinimum) })")
let rateBefore = getOne(dev, addr(kAudioDevicePropertyNominalSampleRate), Float64(0)) ?? 0
print("rate before: \(Int(rateBefore))")
if rateBefore != targetRate {
    var a = addr(kAudioDevicePropertyNominalSampleRate)
    var r = targetRate
    let st = AudioObjectSetPropertyData(dev, &a, 0, nil, UInt32(MemoryLayout<Float64>.size), &r)
    Thread.sleep(forTimeInterval: 1.0)
    print("set 48000: status \(st)")
}
let rateNow = getOne(dev, addr(kAudioDevicePropertyNominalSampleRate), Float64(0)) ?? 0
print("rate now: \(Int(rateNow))")

let bufNow = getOne(dev, addr(kAudioDevicePropertyBufferFrameSize), UInt32(0)) ?? 0
let bufRange = getOne(dev, addr(kAudioDevicePropertyBufferFrameSizeRange), AudioValueRange()) ?? AudioValueRange()
print("buffer frames: \(bufNow) (range \(Int(bufRange.mMinimum)) to \(Int(bufRange.mMaximum)))")

var reported: [String: UInt32] = [:]
for (label, scope) in [("input", kAudioObjectPropertyScopeInput), ("output", kAudioObjectPropertyScopeOutput)] {
    let lat = getOne(dev, addr(kAudioDevicePropertyLatency, scope), UInt32(0)) ?? 0
    let safety = getOne(dev, addr(kAudioDevicePropertySafetyOffset, scope), UInt32(0)) ?? 0
    let streams = getArray(dev, addr(kAudioDevicePropertyStreams, scope), AudioObjectID(0))
    var streamLat: UInt32 = 0
    var fmt = "none"
    if let s = streams.first {
        streamLat = getOne(s, addr(kAudioStreamPropertyLatency), UInt32(0)) ?? 0
        if let p = getOne(s, addr(kAudioStreamPropertyPhysicalFormat), AudioStreamBasicDescription()) {
            fmt = "\(p.mChannelsPerFrame) ch, \(p.mBitsPerChannel) bit, \(Int(p.mSampleRate)) Hz"
        }
    }
    let total = lat + safety + streamLat + bufNow
    reported[label] = total
    print(String(format: "%@: streams %d, physical %@, device latency %d, safety offset %d, stream latency %d, + buffer %d = %d frames (%.2f ms)",
                 label, streams.count, fmt, lat, safety, streamLat, bufNow, total, Double(total) / rateNow * 1000))
}
let rt = (reported["input"] ?? 0) + (reported["output"] ?? 0)
print(String(format: "reported round trip: %d frames (%.2f ms). REPORTED, not measured; needs a loopback cable to confirm.",
             rt, Double(rt) / rateNow * 1000))

// ---------------------------------------------------------------- one engine, in + out
print("\nMIC PERMISSION: \(["notDetermined", "restricted", "denied", "authorized"][AVCaptureDevice.authorizationStatus(for: .audio).rawValue])")

final class Stats {
    let lock = NSLock()
    var buffers = 0, frames = 0, lastLen = 0
    var peak = [Float](repeating: 0, count: 8)
    var sumSq = [Double](repeating: 0, count: 8)
    var rendered = 0
}
let stats = Stats()
let engine = AVAudioEngine()

func pin(_ unit: AudioUnit?, _ label: String) -> Bool {
    guard let unit else { print("FAIL: no \(label) audio unit"); return false }
    var d = dev
    let st = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                  &d, UInt32(MemoryLayout<AudioObjectID>.size))
    print("pin \(label) unit to device: status \(st)")
    return st == noErr
}
let pinnedIn = pin(engine.inputNode.audioUnit, "input")
let pinnedOut = pin(engine.outputNode.audioUnit, "output")

let inFmt = engine.inputNode.outputFormat(forBus: 0)
let outFmt = engine.outputNode.inputFormat(forBus: 0)
print("engine input format: \(inFmt.channelCount) ch, \(Int(inFmt.sampleRate)) Hz")
print("engine output format: \(outFmt.channelCount) ch, \(Int(outFmt.sampleRate)) Hz")

let silence = AVAudioSourceNode { _, _, frameCount, abl -> OSStatus in
    for b in UnsafeMutableAudioBufferListPointer(abl) { memset(b.mData, 0, Int(b.mDataByteSize)) }
    stats.rendered += Int(frameCount)
    return noErr
}
engine.attach(silence)
engine.connect(silence, to: engine.mainMixerNode, format: outFmt)

engine.inputNode.installTap(onBus: 0, bufferSize: 2048, format: inFmt) { buf, _ in
    guard let ch = buf.floatChannelData else { return }
    let n = vDSP_Length(buf.frameLength)
    stats.lock.lock()
    stats.buffers += 1
    stats.frames += Int(buf.frameLength)
    stats.lastLen = Int(buf.frameLength)
    for c in 0..<min(Int(buf.format.channelCount), 8) {
        var p: Float = 0, ms: Float = 0
        vDSP_maxmgv(ch[c], 1, &p, n)
        vDSP_measqv(ch[c], 1, &ms, n)
        stats.peak[c] = max(stats.peak[c], p)
        stats.sumSq[c] += Double(ms) * Double(n)
    }
    stats.lock.unlock()
}

var engineOK = false
do {
    try engine.start()
    engineOK = true
    print(String(format: "engine running. presentation latency: input %.2f ms, output %.2f ms",
                 engine.inputNode.presentationLatency * 1000, engine.outputNode.presentationLatency * 1000))
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    engine.stop()
} catch {
    print("FAIL: engine.start: \(error)")
}

stats.lock.lock()
print("tap: \(stats.buffers) buffers, \(stats.frames) frames in \(seconds) s (expected about \(Int(seconds * inFmt.sampleRate))), last buffer \(stats.lastLen) frames")
print("output rendered: \(stats.rendered) frames of silence")
for c in 0..<Int(inFmt.channelCount) {
    let rms = stats.frames > 0 ? Float(sqrt(stats.sumSq[c] / Double(stats.frames))) : 0
    print("input \(c + 1): peak \(db(stats.peak[c])) dBFS, rms \(db(rms)) dBFS")
}
let gotAudio = stats.frames > Int(seconds * inFmt.sampleRate * 0.9)
let rendered = stats.rendered > Int(seconds * outFmt.sampleRate * 0.9)
let allZero = stats.peak.allSatisfy { $0 == 0 }
stats.lock.unlock()
print("ITEM 2 (one engine, AMS-24 in AND out): \(engineOK && pinnedIn && pinnedOut && gotAudio && rendered ? "PASS" : "FAIL")")
if allZero { print("WARNING: every input sample is exactly zero. That is a denied microphone permission, not a quiet room.") }

// ---------------------------------------------------------------- DSP budget (this host)
func median(_ xs: [Double]) -> Double { xs.sorted()[xs.count / 2] }
func timeIt(_ runs: Int, _ body: () -> Void) -> (med: Double, worst: Double) {
    var t: [Double] = []
    for _ in 0..<runs {
        let s = DispatchTime.now().uptimeNanoseconds
        body()
        t.append(Double(DispatchTime.now().uptimeNanoseconds - s) / 1e6)
    }
    return (median(t), t.max() ?? 0)
}

print("\nDSP BUDGET on \(Host.current().localizedName ?? "this Mac") (frame at 20 slices/s = 50 ms)")
var total = 0.0
for log2n in [15, 14, 13, 12, 11] {
    let n = 1 << log2n
    let setup = vDSP_create_fftsetup(vDSP_Length(log2n), FFTRadix(kFFTRadix2))!
    var input = (0..<n).map { _ in Float.random(in: -1...1) }
    var window = [Float](repeating: 0, count: n)
    vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
    var re = [Float](repeating: 0, count: n / 2), im = [Float](repeating: 0, count: n / 2)
    var mag = [Float](repeating: 0, count: n / 2)
    var windowed = [Float](repeating: 0, count: n)
    let r = timeIt(300) {
        vDSP_vmul(&input, 1, &window, 1, &windowed, 1, vDSP_Length(n))
        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBytes { raw in
                    vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(n / 2))
                }
                vDSP_fft_zrip(setup, &split, 1, vDSP_Length(log2n), FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &mag, 1, vDSP_Length(n / 2))
            }
        }
    }
    total += r.med
    print(String(format: "FFT %5d (window + fft + magnitudes): median %.4f ms, worst %.4f ms", n, r.med, r.worst))
    vDSP_destroy_fftsetup(setup)
}

let block = 2400  // 50 ms at 48 kHz
let centres = (0..<31).map { 1000.0 * pow(2.0, Double($0 - 17) / 3.0) }
let setups: [vDSP_biquad_Setup] = centres.map { f in
    let w0 = 2 * Double.pi * min(f, 0.45 * targetRate) / targetRate
    let alpha = sin(w0) / (2 * 4.32)
    let a0 = 1 + alpha
    let one = [alpha / a0, 0, -alpha / a0, -2 * cos(w0) / a0, (1 - alpha) / a0]
    return vDSP_biquad_CreateSetup(one + one + one, 3)!
}
var delays = [[Float]](repeating: [Float](repeating: 0, count: 2 * 3 + 2), count: 31)
var x = (0..<block).map { _ in Float.random(in: -1...1) }
var y = [Float](repeating: 0, count: block)
let bq = timeIt(300) {
    for b in 0..<31 {
        vDSP_biquad(setups[b], &delays[b], &x, 1, &y, 1, vDSP_Length(block))
        var ms: Float = 0
        vDSP_measqv(&y, 1, &ms, vDSP_Length(block))
    }
}
total += bq.med
print(String(format: "31 bands x 3 biquads over %d samples, 1 channel: median %.4f ms, worst %.4f ms", block, bq.med, bq.worst))
print(String(format: "sum of medians (5 FFT sizes + filter bank, 1 channel): %.4f ms of a 50 ms frame", total))
print("ITEM 6 (this host): \(total * 2 < 5 ? "PASS" : "CHECK") (two channels would be about \(String(format: "%.3f", total * 2)) ms)")

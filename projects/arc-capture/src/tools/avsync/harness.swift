//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

// A/V sync harness: records the QuickTime window playing clapper.mp4 through
// ScreenCaptureKit with ARC Capture's exact stream configuration and its
// unmodified VideoRecorder, so the delivered clip measures the recorder alone.
import Foundation
import AppKit
import ScreenCaptureKit
import AVFoundation

// A command-line process must bring the window server up itself before ScreenCaptureKit
// (CGS_REQUIRE_INIT assertion otherwise), and run a real run loop for its callbacks.
_ = NSApplication.shared

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let seconds = Double(CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "26") ?? 26
let match = CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : "clapper"

final class Screen: NSObject, SCStreamOutput, SCStreamDelegate {
    let rec: VideoRecorder; var frames = 0; var audio = 0; var started = false; var first: CMTime?
    var aFirst: CMTime?; var aLast: CMTime?; var aSamples = 0; var aGaps = 0; var aGapSec = 0.0; var aPrevEnd: CMTime?
    var vFirstHost = 0.0; var vFirstPTS = 0.0; var vLastHost = 0.0; var vLastPTS = 0.0
    init(_ r: VideoRecorder) { rec = r }
    func stream(_ s: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sb.isValid else { return }
        if type == .screen {
            guard let pb = CMSampleBufferGetImageBuffer(sb) else { return }
            let ts = CMSampleBufferGetPresentationTimeStamp(sb)
            if first == nil { first = ts }
            // Production starts the recorder on motion; here after one second of stream.
            if !started, CMTimeSubtract(ts, first!).seconds >= 1.0 {
                try! rec.startRecording(to: out, width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb)); started = true
            }
            if started {
                let host = CMClockGetTime(CMClockGetHostTimeClock()).seconds
                if frames == 0 { vFirstHost = host; vFirstPTS = ts.seconds }
                vLastHost = host; vLastPTS = ts.seconds
                rec.appendFrame(pb, timestamp: ts); frames += 1
            }
        } else if type == .audio, started {
            let pts = CMSampleBufferGetPresentationTimeStamp(sb); let n = CMSampleBufferGetNumSamples(sb)
            if aFirst == nil { aFirst = pts }
            if let prev = aPrevEnd { let gap = CMTimeSubtract(pts, prev).seconds; if gap > 0.002 { aGaps += 1; aGapSec += gap } }
            aPrevEnd = CMTimeAdd(pts, CMTime(value: CMTimeValue(n), timescale: 48000)); aLast = aPrevEnd; aSamples += n
            rec.appendAudio(sb); audio += 1
        }
    }
    func stream(_ s: SCStream, didStopWithError e: Error) { print("stream stopped: \(e)") }
}

Task {
    do {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let w = content.windows.first(where: { ($0.title ?? "").localizedCaseInsensitiveContains(match) && $0.frame.width > 300 }) else {
            print("no window titled *\(match)*"); exit(2)
        }
        print("window \(w.windowID) \"\(w.title ?? "")\" \(Int(w.frame.width))x\(Int(w.frame.height)) app \(w.owningApplication?.applicationName ?? "?")")
        let filter = SCContentFilter(desktopIndependentWindow: w)
        let c = SCStreamConfiguration()
        let scale: CGFloat = 2
        c.width = Int(w.frame.width * scale); c.height = Int(w.frame.height * scale)
        c.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        c.pixelFormat = kCVPixelFormatType_32BGRA
        c.queueDepth = 3
        c.showsCursor = false
        c.capturesAudio = true; c.sampleRate = 48000; c.channelCount = 2; c.excludesCurrentProcessAudio = true
        let rec = VideoRecorder(); rec.frameRate = 30
        let sink = Screen(rec)
        let s = SCStream(filter: filter, configuration: c, delegate: sink)
        try s.addStreamOutput(sink, type: .screen, sampleHandlerQueue: DispatchQueue(label: "cap", qos: .userInteractive))
        try s.addStreamOutput(sink, type: .audio, sampleHandlerQueue: DispatchQueue(label: "aud", qos: .userInteractive))
        try await s.startCapture()
        try await Task.sleep(for: .seconds(seconds))
        try await s.stopCapture()
        let url = try await rec.stopRecording()
        print("recorded \(url.path)  frames \(sink.frames)  dropped \(rec.droppedFrames)")
        let span = CMTimeSubtract(sink.aLast ?? .zero, sink.aFirst ?? .zero).seconds
        print(String(format: "AUDIO from SCK: buffers %d  samples %d (= %.3f s)  PTS span %.3f s  gaps %d totalling %.3f s  | appended by recorder: %d buffers (%d discarded by the ready guard)",
              sink.audio, sink.aSamples, Double(sink.aSamples)/48000, span, sink.aGaps, sink.aGapSec, rec.audioSamples, sink.audio - rec.audioSamples))
        print("recorder: pending at stop \(rec.pendingAudioCount)  rejected \(rec.audioRejected)")
        print(String(format: "VIDEO: PTS span %.3f s over host span %.3f s (ratio %.4f)", sink.vLastPTS - sink.vFirstPTS, sink.vLastHost - sink.vFirstHost, (sink.vLastPTS - sink.vFirstPTS)/(sink.vLastHost - sink.vFirstHost)))
    } catch { print("error: \(error)"); exit(1) }
    exit(0)
}
RunLoop.main.run()

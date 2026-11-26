//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import AVFoundation
import CoreVideo

/// Is there an ANIMATION in this clip, or only a cut? PowerPoint's commonest build is "Appear" (1 ms) and its
/// commonest transition is none: the recording of either holds no motion, only a before and an after. Played as
/// video that is a player swap and a wait for what is a cut between two stills (2026-09-17, on a deck of
/// Appear builds: "these slides have simple builds yet they show 3.8 s of animation? i think this is the problem";
/// measured there: build 1's clip showed the finished build in EVERY frame, the 7.5 s "transition" was 0.23 s of
/// the old slide, a hard cut, then 7.3 s of a still).
///
/// A frame is IN BETWEEN when it differs from both the first and the last frame of the clip. A cut has none (or a
/// frame or two while PowerPoint repaints); an animation has them for as long as it runs. Measured against the
/// ends, not frame to frame, so a slow fade whose every step is small still counts: mid fade it is far from both.
enum MotionProbe {
    struct Verdict: Equatable {
        /// Seconds during which the picture was neither the first frame nor the last.
        var inBetweenSeconds: Double
        /// The clip ends on another picture than it starts on.
        var endsDifferent: Bool
        var frames: Int
        /// Nothing in it that a cut between two stills does not show.
        var isCut: Bool { inBetweenSeconds <= MotionProbe.cutTolerance }
    }
    /// A repaint across two or three frames is still a cut.
    static let cutTolerance = 0.12
    /// A pixel counts as changed past this many grey levels (H.264 noise on a flat slide stays under it)...
    static let pixelThreshold: Int = 26
    /// ...and a frame as different when this share of its pixels changed (one short line of small text is about 0.15 %).
    static let frameThreshold = 0.0003

    static func probe(_ url: URL) async -> Verdict? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first, let reader = try? AVAssetReader(asset: asset) else { return nil }
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 180])
        out.alwaysCopiesSampleData = false
        guard reader.canAdd(out) else { return nil }
        reader.add(out)
        guard reader.startReading() else { return nil }
        var frames: [(t: Double, luma: [UInt8])] = []
        while let sample = out.copyNextSampleBuffer() {
            guard let px = CMSampleBufferGetImageBuffer(sample) else { continue }
            frames.append((CMSampleBufferGetPresentationTimeStamp(sample).seconds, luma(of: px)))
            if frames.count > 3600 { break }        // two minutes at 30 fps: a movie, not a build
        }
        let duration = (try? await asset.load(.duration).seconds) ?? frames.last?.t ?? 0
        return verdict(frames: frames, duration: duration)
    }

    /// Pure: the frames (time, 8-bit luma of equal length) in, the verdict out.
    static func verdict(frames: [(t: Double, luma: [UInt8])], duration: Double) -> Verdict? {
        guard let first = frames.first?.luma, let last = frames.last?.luma, !first.isEmpty else { return nil }
        var between = 0.0
        for (i, f) in frames.enumerated() where i > 0 && i < frames.count - 1 {
            if differs(f.luma, first), differs(f.luma, last) {
                between += max(0, (i + 1 < frames.count ? frames[i + 1].t : duration) - f.t)
            }
        }
        return Verdict(inBetweenSeconds: (between * 100).rounded() / 100, endsDifferent: differs(first, last), frames: frames.count)
    }

    static func differs(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count, !a.isEmpty else { return true }
        var changed = 0
        for i in 0..<a.count where abs(Int(a[i]) - Int(b[i])) > pixelThreshold { changed += 1 }
        return Double(changed) / Double(a.count) > frameThreshold
    }

    private static func luma(of px: CVPixelBuffer) -> [UInt8] {
        CVPixelBufferLockBaseAddress(px, .readOnly); defer { CVPixelBufferUnlockBaseAddress(px, .readOnly) }
        let w = CVPixelBufferGetWidth(px), h = CVPixelBufferGetHeight(px), stride = CVPixelBufferGetBytesPerRow(px)
        guard let base = CVPixelBufferGetBaseAddress(px)?.assumingMemoryBound(to: UInt8.self) else { return [] }
        var out = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            let row = base + y * stride
            for x in 0..<w { let p = row + x * 4; out[y * w + x] = UInt8((Int(p[0]) * 29 + Int(p[1]) * 150 + Int(p[2]) * 77) >> 8) }
        }
        return out
    }
}

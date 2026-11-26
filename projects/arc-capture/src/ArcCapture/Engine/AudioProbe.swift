//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import AVFoundation

/// Does a clip carry sound? MotionProbe judges a build clip by its PICTURE alone, and a
/// still picture with a soundtrack (a slide that plays audio, a movie of one frame) was
/// judged a cut and its clip deleted, sound and all (keynote3 on the mini, 2026-09-18:
/// a 69 s movie with sound dropped as a cut). The peak of the audio track, read once.
enum AudioProbe {
    /// Below -50 dBFS is silence for this purpose (SCK's captured hiss sits under -60).
    static let floor: Float = 0.00316

    /// The clip's peak sample, 0...1; nil when it has no audio track or none could be read.
    static func peak(_ url: URL) async -> Float? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first, let reader = try? AVAssetReader(asset: asset) else { return nil }
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false])
        out.alwaysCopiesSampleData = false
        guard reader.canAdd(out) else { return nil }
        reader.add(out)
        guard reader.startReading() else { return nil }
        var peak: Int16 = 0
        var samples = 0
        while let sample = out.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(sample) {
            var length = 0, ptr: UnsafeMutablePointer<CChar>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &ptr) == noErr, let ptr else { continue }
            ptr.withMemoryRebound(to: Int16.self, capacity: length / 2) { p in
                for i in 0..<(length / 2) { let v = p[i] == Int16.min ? Int16.max : abs(p[i]); if v > peak { peak = v } }
            }
            samples += length / 2
            if samples > 48_000 * 2 * 120 { break }   // two minutes of stereo: a movie, and its answer is known by then
        }
        return Float(peak) / Float(Int16.max)
    }

    static func hasSound(_ url: URL) async -> Bool {
        guard let p = await peak(url) else { return false }
        return p > floor
    }
}

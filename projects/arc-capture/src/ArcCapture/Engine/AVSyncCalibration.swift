//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation

/// How far behind the sound this machine's captured picture runs.
///
/// ScreenCaptureKit taps an app's audio as it plays but delivers the window's picture later, so a clip
/// recorded from PowerPoint has its sound ahead of its picture by a constant amount that differs per
/// machine: MEASURED 2026-09-17 with the flash+click reference deck, 590 ms on the Mac Studio and 350 ms on
/// laptop-06, spread 12-20 ms over seven events, no drift, while PowerPoint's own output was in sync in
/// the room. The recorder writes the audio track that much later so the two line up.
///
/// Measure it with `tools/avsync/reference/ARC AV Reference.pptx`, then
/// `tools/avsync/measure-deck.sh <that>.arcdeck`: the MEAN it prints, negated, is the value to set.
enum AVSyncCalibration {
    private static let key = "avAudioOffsetMs"

    /// Milliseconds the audio is held back. Zero when this machine has never been calibrated.
    static var offsetMs: Double {
        get { UserDefaults.standard.double(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static var offsetSeconds: Double { offsetMs / 1000 }

    /// `--audio-offset MS` on any run sets it for this machine and every run after it. `--audio-offset 0`
    /// turns it off, which is how a capture is made for a fresh measurement.
    static func applyLaunchArgument(_ arguments: [String] = CommandLine.arguments) -> Double? {
        guard let i = arguments.firstIndex(of: "--audio-offset"), i + 1 < arguments.count,
              let ms = Double(arguments[i + 1]) else { return nil }
        offsetMs = ms
        return ms
    }

    /// A sane range: the measured values are 350-590 ms and a machine that needs more than a second is
    /// telling us something else is wrong, so the value is clamped rather than trusted blindly.
    static var clampedSeconds: Double { min(max(offsetSeconds, 0), 1.5) }
}

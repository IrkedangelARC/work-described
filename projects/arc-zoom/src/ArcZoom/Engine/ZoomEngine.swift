//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation
import CoreVideo

/// One participant as the sidecar knows them. `id` is the Zoom SDK's user id.
struct Participant: Identifiable, Equatable, Sendable {
    let id: UInt32
    var name: String
    var isHost = false
    var isCoHost = false
    var isMe = false
    var videoOn = true
    /// Unmuted. Meaningless unless `audioJoined`: the SDK reports a participant with NO audio as
    /// "not muted", which is how MIC OPEN lit on a sidecar that had never joined the meeting audio
    /// (2026-09-21: audio.send 0, audio.recv 0, no sound in the room).
    var audioOn = true
    /// In the meeting AUDIO (VoIP joined), as opposed to merely in the meeting.
    var audioJoined = true
    var handRaised = false
    /// Spotlighted IN THE MEETING (everyone sees it), not the sidecar's own program choice.
    var isSpotlighted = false
    /// Position in the SDK's spotlight list (0 = spotlit first). PROGRAM follows the LOWEST rank, so
    /// adding a second spotlight never moves the room's screen, and the SPOTLIGHT grid keeps the order
    /// the operator made it in. nil when not spotlit.
    var spotlightRank: Int?
    /// The operator's name for this person, shown in the room instead of the Zoom name.
    var friendlyName: String?

    var displayName: String { friendlyName ?? name }
}

enum MeetingState: String, Sendable {
    case idle, joining, inMeeting, reconnecting, failed
}

/// THE SDK BOUNDARY. Everything the sidecar needs from Zoom, and nothing else. Two implementations:
/// `FakeZoomEngine` (synthetic participants with real moving frames, so the whole chain from roster to
/// the window ARC Presenter takes is testable with no SDK and no meeting) and `SDKZoomEngine` (the Zoom
/// Meeting SDK, filled in by Phase 0 of PLAN.md).
///
/// TWO KINDS OF SELECTION, deliberately separate:
/// - `spotlight(_:)` is a Zoom call. It changes what EVERY attendee in the meeting sees. Host or co-host.
/// - the sidecar's own PROGRAM choice (`Sidecar.program`) is local: it changes what the ROOM sees on the
///   program monitor and asks Zoom for nothing. Zoom's "pin" is therefore not in this protocol at all;
///   the sidecar simply draws whoever it was told to draw.
@MainActor
protocol ZoomEngine: AnyObject {
    /// "fake" or "sdk", for the operator page and the control API.
    var kind: String { get }
    var state: MeetingState { get }
    var lastError: String? { get }
    var participants: [Participant] { get }
    var meetingNumber: String? { get }
    /// The sidecar is sharing a window into the meeting (the SHARE window of ARC Presenter).
    var isSharing: Bool { get }
    var sharedWindowTitle: String? { get }

    /// A decoded frame for one participant, IOSurface-backed so a CALayer can take it with no copy.
    var onFrame: ((UInt32, CVPixelBuffer) -> Void)? { get set }
    var onRosterChange: (() -> Void)? { get set }
    var onStateChange: ((MeetingState) -> Void)? { get set }

    func join(meeting: String, passcode: String?, displayName: String) async -> Bool
    func leave() async

    /// Raw video is per participant and explicitly subscribed in the SDK; the boundary says so.
    func subscribe(to id: UInt32) async -> Bool
    func unsubscribe(from id: UInt32)

    /// nil clears the spotlight. Meeting-wide, needs host or co-host.
    func spotlight(_ id: UInt32?, on: Bool) async -> Bool
    func mute(_ id: UInt32, on: Bool) async -> Bool

    /// Share a window of ANOTHER app by its title, which is how Presenter's "ARC Presenter Program"
    /// reaches the remote without the operator touching Zoom's picker.
    func startShare(windowTitle: String, withSound: Bool) async -> Bool
    func stopShare() async
}

extension ZoomEngine {
    var isInMeeting: Bool { state == .inMeeting }
    func participant(_ id: UInt32) -> Participant? { participants.first { $0.id == id } }
    /// Everyone but us: what the room is ever shown.
    var remotes: [Participant] { participants.filter { !$0.isMe } }
    var spotlighted: Participant? { participants.first(where: \.isSpotlighted) }
}

/// A frame factory shared by the fake engine and (later) the SDK's YUV conversion: a BGRA pixel buffer
/// with IOSurface backing, which is the only kind a CALayer can show without a copy.
enum PixelBufferFactory {
    static func make(width: Int, height: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                         kCVPixelFormatType_32BGRA, attrs as CFDictionary, &buffer)
        return status == kCVReturnSuccess ? buffer : nil
    }

    /// Draw into a buffer with Core Graphics. The closure gets a context in TOP-LEFT origin space
    /// (flipped), because that is how text and layout read.
    static func draw(into buffer: CVPixelBuffer, _ body: (CGContext, CGSize) -> Void) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer),
              let ctx = CGContext(data: base, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return }
        body(ctx, CGSize(width: w, height: h))
    }
}

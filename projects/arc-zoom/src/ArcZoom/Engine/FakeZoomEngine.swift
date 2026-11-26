//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import AppKit
import CoreVideo
import CoreText

/// A meeting that is not a meeting: synthetic participants whose frames MOVE, delivered through the
/// same callback and in the same pixel format the Zoom SDK will use. It exists so everything except
/// the SDK can be built, tested and drilled today: the roster, the layouts, the output windows, the
/// control API, and above all whether ARC Presenter can take "ARC Zoom Program" as a source.
///
/// When Phase 0 lands `SDKZoomEngine`, nothing above this line changes, and this stays as the rehearsal
/// rig: a show can be set up and practised with no meeting and no remote people.
@MainActor
@Observable
final class FakeZoomEngine: ZoomEngine {
    let kind = "fake"
    private(set) var state: MeetingState = .idle
    private(set) var lastError: String?
    private(set) var participants: [Participant] = []
    private(set) var meetingNumber: String?
    private(set) var isSharing = false
    private(set) var sharedWindowTitle: String?

    @ObservationIgnored var onFrame: ((UInt32, CVPixelBuffer) -> Void)?
    @ObservationIgnored var onRosterChange: (() -> Void)?
    @ObservationIgnored var onStateChange: ((MeetingState) -> Void)?

    /// 640x360 per participant: enough to see that it is live and cheap enough for eight of them.
    private let frameSize = CGSize(width: 640, height: 360)
    private let fps = 30.0
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var tick = 0
    @ObservationIgnored private var subscribed: Set<UInt32> = []
    /// A RING of buffers per participant, not one. Handing a CALayer the SAME IOSurface every frame,
    /// even with fresh pixels drawn into it, is not a change as far as CoreAnimation is concerned: the
    /// layer is never marked dirty, the window server never recomposites, and anything capturing that
    /// window with ScreenCaptureKit sees `idle` for ever. Measured 2026-09-20: ARC Presenter's stream on
    /// this window delivered 0 frames and 2,954 idle statuses while the window itself was plainly
    /// animating, because a one-shot `SCScreenshotManager` render forces a composite and a stream does
    /// not. The Zoom SDK hands out a fresh buffer from its own pool per frame, so rotating here is also
    /// the honest imitation.
    @ObservationIgnored private var pools: [UInt32: [CVPixelBuffer]] = [:]
    @ObservationIgnored private var poolIndex: [UInt32: Int] = [:]
    private static let poolDepth = 3

    /// Test-pattern colours, one per seat, in the order people join.
    private static let colours: [CGColor] = [
        CGColor(red: 0.16, green: 0.35, blue: 0.55, alpha: 1),
        CGColor(red: 0.48, green: 0.20, blue: 0.24, alpha: 1),
        CGColor(red: 0.20, green: 0.42, blue: 0.30, alpha: 1),
        CGColor(red: 0.42, green: 0.34, blue: 0.16, alpha: 1),
        CGColor(red: 0.34, green: 0.24, blue: 0.46, alpha: 1),
        CGColor(red: 0.18, green: 0.40, blue: 0.44, alpha: 1),
    ]

    private static let cast = ["ARC Tech (me)", "Dr. Jane Smith", "Guest Speaker", "Panel Guest", "Front Office", "Remote Producer"]

    // MARK: - ZoomEngine

    func join(meeting: String, passcode: String?, displayName: String) async -> Bool {
        guard state != .inMeeting else { return true }
        lastError = nil
        set(.joining)
        try? await Task.sleep(nanoseconds: 400_000_000)   // the SDK takes about this long
        meetingNumber = meeting.isEmpty ? "000 0000 0000" : meeting
        participants = [Participant(id: 1, name: displayName.isEmpty ? Self.cast[0] : displayName, isHost: true, isMe: true)]
        set(.inMeeting)
        startClock()
        onRosterChange?()
        return true
    }

    func leave() async {
        timer?.invalidate(); timer = nil
        participants = []; subscribed = []; pools = [:]; poolIndex = [:]
        meetingNumber = nil
        isSharing = false; sharedWindowTitle = nil
        set(.idle)
        onRosterChange?()
    }

    func subscribe(to id: UInt32) async -> Bool {
        guard participants.contains(where: { $0.id == id }) else { return false }
        subscribed.insert(id)
        return true
    }

    func unsubscribe(from id: UInt32) {
        subscribed.remove(id)
        pools[id] = nil; poolIndex[id] = nil
    }

    /// Multi-spotlight like the SDK: on adds to the end of the order, off removes one, nil clears all.
    func spotlight(_ id: UInt32?, on: Bool = true) async -> Bool {
        guard state == .inMeeting else { return false }
        var order = participants.filter { $0.isSpotlighted }.sorted { ($0.spotlightRank ?? .max) < ($1.spotlightRank ?? .max) }.map(\.id)
        if let id { if on { if !order.contains(id) { order.append(id) } } else { order.removeAll { $0 == id } } } else { order = [] }
        for i in participants.indices {
            let rank = order.firstIndex(of: participants[i].id)
            participants[i].isSpotlighted = rank != nil
            participants[i].spotlightRank = rank
        }
        onRosterChange?()
        return true
    }

    func mute(_ id: UInt32, on: Bool) async -> Bool {
        guard let i = participants.firstIndex(where: { $0.id == id }) else { return false }
        participants[i].audioOn = !on
        onRosterChange?()
        return true
    }

    func startShare(windowTitle: String, withSound: Bool) async -> Bool {
        guard state == .inMeeting else { lastError = "not in a meeting"; return false }
        // The fake cannot really share, but it CAN tell the truth about whether the window exists,
        // which is the half of the question that catches a typo or a closed SHARE window.
        let exists = Self.windowExists(titled: windowTitle)
        guard exists else { lastError = "no on-screen window titled \"\(windowTitle)\""; return false }
        isSharing = true; sharedWindowTitle = windowTitle
        return true
    }

    func stopShare() async {
        isSharing = false; sharedWindowTitle = nil
    }

    // MARK: - The rehearsal rig

    /// Add a synthetic remote. The operator page and `POST /fake/add` use it to build a meeting shape
    /// before the real people exist.
    @discardableResult
    func addParticipant(name: String? = nil) -> Participant? {
        guard state == .inMeeting, participants.count < Self.cast.count else { return nil }
        let id = (participants.map(\.id).max() ?? 0) + 1
        let p = Participant(id: id, name: name ?? Self.cast[min(Int(id) - 1, Self.cast.count - 1)])
        participants.append(p)
        onRosterChange?()
        return p
    }

    func removeParticipant(_ id: UInt32) {
        participants.removeAll { $0.id == id && !$0.isMe }
        unsubscribe(from: id)
        onRosterChange?()
    }

    func setVideo(_ id: UInt32, on: Bool) {
        guard let i = participants.firstIndex(where: { $0.id == id }) else { return }
        participants[i].videoOn = on
        onRosterChange?()
    }

    func rename(_ id: UInt32, friendly: String?) {
        guard let i = participants.firstIndex(where: { $0.id == id }) else { return }
        participants[i].friendlyName = (friendly?.isEmpty ?? true) ? nil : friendly
        onRosterChange?()
    }

    // MARK: - Frames

    private func startClock() {
        timer?.invalidate()
        timer = Timer.common(every: 1.0 / fps) { [weak self] in self?.emit() }
    }

    private func emit() {
        tick &+= 1
        for p in participants where subscribed.contains(p.id) && p.videoOn {
            guard let buffer = buffer(for: p.id) else { continue }
            draw(p, into: buffer)
            onFrame?(p.id, buffer)
        }
    }

    /// The next buffer in this participant's ring. See `pools` for why it must not be the same one twice.
    private func buffer(for id: UInt32) -> CVPixelBuffer? {
        if pools[id] == nil {
            var ring: [CVPixelBuffer] = []
            for _ in 0..<Self.poolDepth {
                if let b = PixelBufferFactory.make(width: Int(frameSize.width), height: Int(frameSize.height)) { ring.append(b) }
            }
            guard !ring.isEmpty else { return nil }
            pools[id] = ring
        }
        guard let ring = pools[id], !ring.isEmpty else { return nil }
        let i = (poolIndex[id] ?? 0) % ring.count
        poolIndex[id] = (i + 1) % ring.count
        return ring[i]
    }

    /// A test pattern that proves three things at a glance: which participant this is, that the picture
    /// is moving, and roughly how old it is.
    private func draw(_ p: Participant, into buffer: CVPixelBuffer) {
        let seat = Int(p.id) - 1
        let colour = Self.colours[seat % Self.colours.count]
        let frameNo = tick
        PixelBufferFactory.draw(into: buffer) { ctx, size in
            ctx.setFillColor(colour)
            ctx.fill(CGRect(origin: .zero, size: size))

            // A bar that sweeps left to right once a second: motion you can see from across a room.
            let phase = CGFloat(frameNo % Int(self.fps)) / CGFloat(self.fps)
            ctx.setFillColor(CGColor(gray: 1, alpha: 0.30))
            ctx.fill(CGRect(x: phase * size.width, y: 0, width: max(6, size.width / 40), height: size.height))

            // A hairline frame, so a tile's edges are visible against a black window.
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.25))
            ctx.setLineWidth(2)
            ctx.stroke(CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1))

            Self.text(p.displayName, in: ctx, at: CGPoint(x: 24, y: size.height - 64), size: 34, weight: .bold)
            Self.text("id \(p.id)   frame \(frameNo)", in: ctx, at: CGPoint(x: 24, y: 28), size: 20, weight: .regular)
            if p.isSpotlighted {
                Self.text("SPOTLIGHT", in: ctx, at: CGPoint(x: 24, y: size.height - 110), size: 22, weight: .heavy)
            }
        }
    }

    /// Core Text straight into the context: no NSGraphicsContext, so this is safe wherever it runs.
    private static func text(_ s: String, in ctx: CGContext, at point: CGPoint, size: CGFloat, weight: NSFont.Weight) {
        let attr = NSAttributedString(string: s, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: size, weight: weight),
            .foregroundColor: NSColor.white,
        ])
        let line = CTLineCreateWithAttributedString(attr)
        ctx.textPosition = point
        CTLineDraw(line, ctx)
    }

    /// Is there an on-screen window with this title, owned by anyone? The share check.
    nonisolated static func windowExists(titled title: String) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return false }
        return list.contains { ($0[kCGWindowName as String] as? String) == title }
    }

    private func set(_ s: MeetingState) {
        guard state != s else { return }
        state = s
        onStateChange?(s)
    }
}

//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import AppKit
import SwiftUI

/// V4 build plan items 3 and 4: the switch between the live deck and a parked
/// PowerPoint show, and black while PowerPoint is live. Presenter keeps focus
/// throughout (architecture B) and SourceRouter forwards the clicker; nothing
/// here is sent to PowerPoint.
///
/// Two reveal modes, both a fade through black on things Presenter owns:
///
/// `.composite` (default): the program window stays OPAQUE. A ScreenCaptureKit
///   stream of PowerPoint's show window is drawn into it and faded up over the
///   black veil. Measured 2026-09-16: a transparent program window lets the
///   per-display menu bar show over the slideshow on the program display, and
///   no presentation option or system setting hides it there; an opaque window
///   covers it. PowerPoint keeps rendering under the opaque window (~37 fps
///   through transitions, tools/covered_video_capture_bench.swift).
///
/// `.transparent` (fallback, e.g. no Screen Recording permission): the program
///   window's alpha goes to 0 so the show underneath is seen directly.
///
/// The confidence window fades to alpha 0 either way, so PowerPoint's
/// Presenter View parked on that display shows through.
@MainActor
@Observable
final class SwitchEngine {
    enum State: String {
        case deck
        case fadingToPowerPoint
        case powerpoint
        case fadingToDeck
    }
    enum RevealMode: String {
        case composite
        case transparent
    }

    private(set) var state: State = .deck
    var mode: RevealMode = .composite
    /// 0 = the deck shows, 1 = black. ProgramOutputView paints it over the deck.
    private(set) var veil: Double = 0
    /// Composite mode: opacity of the captured PowerPoint layer above the veil.
    private(set) var reveal: Double = 0
    private(set) var powerPointBlack = false
    private(set) var lastError: String?
    var fadeSeconds: Double = 0.3

    /// Which external source the switch targets: the last one prepared or taken.
    /// `.powerpoint` until a window is attached (V4 behaviour unchanged).
    private(set) var external: LiveSource = .powerpoint
    /// `.powerpoint` state means "an external source is live"; `external` says which.
    var isPowerPointLive: Bool { state == .powerpoint }
    var isExternalLive: Bool { state == .powerpoint }
    var liveSource: LiveSource { isExternalLive ? external : .deck }
    func isExternalArmed(_ source: LiveSource) -> Bool { external == source }
    var isBusy: Bool { state == .fadingToPowerPoint || state == .fadingToDeck }

    /// Window alpha, injectable so the state machine is unit-testable. Main
    /// actor: both fades are started together with `async let` and must not
    /// race each other.
    @MainActor
    protocol OutputWindows {
        func setAlpha(_ alpha: CGFloat, of output: OutputType, over seconds: Double) async
    }
    /// The captured show (composite mode), injectable for the same reason.
    @MainActor
    protocol LiveCapture: AnyObject {
        var isRunning: Bool { get }
        var lastError: String? { get }
        func start() async -> Bool
        func stop() async
    }

    private let router: SourceRouter
    private let windows: OutputWindows
    private let powerPointCapture: LiveCapture
    private let windowCapture: LiveCapture?
    /// The capture for the current external source.
    private var capture: LiveCapture { external == .window ? (windowCapture ?? powerPointCapture) : powerPointCapture }
    private let powerPointIsReady: () -> Bool
    private let windowIsReady: () -> Bool
    private func isReady(_ source: LiveSource) -> Bool { source == .window ? windowIsReady() : powerPointIsReady() }
    /// Silences the deck's live players while PowerPoint is live and brings
    /// exactly those back on return. Mute, not pause: a paused live loop stayed
    /// paused after the return (2026-09-16).
    private let silenceDeck: () -> Void
    private let restoreDeck: () -> Void
    /// Keeps the parked PowerPoint silent while the deck is live and lets it sound again on the
    /// take (PowerPointMute). Field, 2026-09-18: a movie left playing in the parked show kept
    /// sounding through the room after the RETURN. Mute, never pause (2026-09-16).
    private let mutePowerPoint: () -> Void
    private let unmutePowerPoint: () -> Void
    /// The same for a parked window's app (WindowSource, 2026-09-18).
    private let muteWindow: () -> Void
    private let unmuteWindow: () -> Void
    private func mute(_ source: LiveSource) { source == .window ? muteWindow() : mutePowerPoint() }
    private func unmute(_ source: LiveSource) { source == .window ? unmuteWindow() : unmutePowerPoint() }

    init(router: SourceRouter, capture: LiveCapture, windowCapture: LiveCapture? = nil,
         powerPointIsReady: @escaping () -> Bool, windowIsReady: @escaping () -> Bool = { false },
         silenceDeck: @escaping () -> Void, restoreDeck: @escaping () -> Void,
         mutePowerPoint: @escaping () -> Void = {}, unmutePowerPoint: @escaping () -> Void = {},
         muteWindow: @escaping () -> Void = {}, unmuteWindow: @escaping () -> Void = {},
         windows: OutputWindows = NSWindowOutputs()) {
        self.router = router
        self.powerPointCapture = capture
        self.windowCapture = windowCapture
        self.windows = windows
        self.powerPointIsReady = powerPointIsReady
        self.windowIsReady = windowIsReady
        self.silenceDeck = silenceDeck
        self.restoreDeck = restoreDeck
        self.mutePowerPoint = mutePowerPoint
        self.unmutePowerPoint = unmutePowerPoint
        self.muteWindow = muteWindow
        self.unmuteWindow = unmuteWindow
        router.powerPointBlack = { [weak self] in self?.togglePowerPointBlack() }
    }

    /// Make `source` the one the next TAKE goes to. Refused while an external
    /// source is live or fading (the capture is in use).
    @discardableResult
    func arm(_ source: LiveSource) -> Bool {
        guard source.isExternal, state == .deck, !isPreparing else { return false }
        if external != source { ShowLog.log("armed \(source.rawValue)") }
        external = source
        return true
    }

    /// Composite mode: start the capture as soon as PowerPoint is parked, so any
    /// system dialog (the monthly screen-recording re-consent) and the stream
    /// warm-up happen during prep, not on the take. Safe to call repeatedly.
    /// The API calls it after a park; the take calls it again as a last resort.
    private(set) var isPreparing = false
    @discardableResult
    func prepare(_ source: LiveSource? = nil) async -> Bool {
        if let source { guard arm(source) else { return false } }
        guard mode == .composite, state == .deck, !isPreparing else { return capture.isRunning }
        guard isReady(external) else { return false }
        isPreparing = true
        defer { isPreparing = false }
        let ok = await capture.start()
        if !ok { lastError = capture.lastError ?? "the PowerPoint capture did not start" }
        ShowLog.log(ok ? "capture prepared" : "capture NOT prepared: \(lastError ?? "?")")
        return ok
    }

    /// Switch the program output to the parked PowerPoint show. False when
    /// PowerPoint is not parked and verified, a switch is already under way, or
    /// (composite mode) the capture could not start; `lastError` says why. The
    /// state only leaves `.deck` once the picture exists, so a capture that
    /// hangs behind a system dialog can never wedge the engine.
    @discardableResult
    func takePowerPoint() async -> Bool { await take(.powerpoint) }
    @discardableResult
    func takeWindow() async -> Bool { await take(.window) }

    @discardableResult
    func take(_ source: LiveSource) async -> Bool {
        guard source.isExternal else {
            lastError = "\(source.rawValue) is not an external source"
            ShowLog.log("TAKE refused: \(lastError ?? "?")")
            return false
        }
        // An operator who picks a window in the popover and hits TAKE at once arrives while
        // prepare() is still running: measured at 0.12 s after attach, and the take was DROPPED
        // with no log line at all, leaving "armed window, live deck" and nothing to explain it
        // (drill 2026-09-18). Dropping an operator's take on a live console is the worst of the
        // three answers, so wait for the prepare rather than refuse it.
        if isPreparing {
            ShowLog.log("TAKE waiting: the capture is still preparing")
            let deadline = Date().addingTimeInterval(5)
            while isPreparing, Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
        }
        guard !isPreparing else {
            lastError = "the capture was still preparing after 5 s"
            ShowLog.log("TAKE refused: \(lastError ?? "?")")
            return false
        }
        guard state == .deck else {
            lastError = "a switch is already under way (\(state.rawValue))"
            ShowLog.log("TAKE refused: \(lastError ?? "?")")
            return false
        }
        guard isReady(source) else {
            lastError = source == .window ? "no window is attached and ready" : "PowerPoint is not parked and ready"
            ShowLog.log("TAKE refused: \(lastError ?? "?")")
            return false
        }
        arm(source)
        lastError = nil
        if mode == .composite, !capture.isRunning {
            guard await prepare() else { ShowLog.log("TAKE refused: \(lastError ?? "capture")"); return false }
        }
        state = .fadingToPowerPoint
        // Clicks during the fade already belong to the source; routing them to
        // the deck moved it under black (audit R10).
        router.live = source
        // The source is heard again from here: its audio belongs to the take.
        unmute(source)
        await animateVeil(1)
        // The deck is under black now: silence it, keep it running.
        silenceDeck()
        switch mode {
        case .composite:
            async let picture: () = animateReveal(1)
            async let confidence: () = windows.setAlpha(0, of: .confidence, over: fadeSeconds)
            _ = await (picture, confidence)
        case .transparent:
            async let program: () = windows.setAlpha(0, of: .program, over: fadeSeconds)
            async let confidence: () = windows.setAlpha(0, of: .confidence, over: fadeSeconds)
            _ = await (program, confidence)
        }
        powerPointBlack = false
        state = .powerpoint
        ShowLog.log("TAKE \(source == .window ? "window" : "PowerPoint") (\(mode.rawValue))")
        SlideTrackRecorder.record(.program) { $0.program = source == .window ? "window" : "powerpoint"; $0.note = mode.rawValue }
        return true
    }

    @discardableResult
    func returnToDeck() async -> Bool {
        guard state == .powerpoint else { return false }
        // A black toggle still fading must finish first, or its reveal target
        // races this one's (audit R10).
        if let fade = blackFade { await fade.value; blackFade = nil }
        state = .fadingToDeck
        router.live = .deck
        // PowerPoint's own media is NOT touched: setting its `slide state` to
        // paused/running over AppleScript froze the show window's video while
        // the audio kept going (2026-09-16). Media left playing under the
        // shield is MUTED instead (a process tap held silent, 2026-09-18) until
        // the next take.
        mute(external)
        switch mode {
        case .composite:
            async let picture: () = animateReveal(0)
            async let confidence: () = windows.setAlpha(1, of: .confidence, over: fadeSeconds)
            _ = await (picture, confidence)
        case .transparent:
            async let program: () = windows.setAlpha(1, of: .program, over: fadeSeconds)
            async let confidence: () = windows.setAlpha(1, of: .confidence, over: fadeSeconds)
            _ = await (program, confidence)
        }
        powerPointBlack = false
        await animateVeil(0)
        restoreDeck()
        // The capture keeps running: the SOURCES module shows what is parked
        // under the shield, and the next take is instant. PowerPointSource.close
        // stops it.
        state = .deck
        ShowLog.log("RETURN to deck")
        SlideTrackRecorder.record(.program) { $0.program = "deck" }
        return true
    }

    /// The live source is gone (PowerPoint quit, the capture died). Return to
    /// the deck rather than hold a frozen frame; `lastError` tells the operator
    /// why. When not live, just record the reason.
    func sourceLost(_ reason: String) async {
        lastError = reason
        // Nothing left to keep quiet; a tap on a gone process is released.
        unmute(external)
        guard state == .powerpoint else {
            ShowLog.log("source lost while \(state.rawValue): \(reason)")
            return
        }
        ShowLog.error("SOURCE LOST: \(reason), returning to deck")
        await returnToDeck()
    }

    /// Black on the PowerPoint source is Presenter's own black coming back
    /// (the veil is still up behind the picture), never PowerPoint's black.
    func togglePowerPointBlack() {
        guard state == .powerpoint else { return }
        powerPointBlack.toggle()
        let black = powerPointBlack
        ShowLog.log(black ? "BLACK on PowerPoint" : "BLACK off")
        blackFade = Task {
            switch mode {
            case .composite:   await animateReveal(black ? 0 : 1)
            case .transparent: await windows.setAlpha(black ? 1 : 0, of: .program, over: fadeSeconds)
            }
        }
    }
    /// The fade started by the last black toggle, awaitable (tests, API).
    private(set) var blackFade: Task<Void, Never>?

    private func animateVeil(_ value: Double) async {
        withAnimation(.linear(duration: fadeSeconds)) { veil = value }
        try? await Task.sleep(for: .seconds(fadeSeconds))
    }

    private func animateReveal(_ value: Double) async {
        withAnimation(.linear(duration: fadeSeconds)) { reveal = value }
        try? await Task.sleep(for: .seconds(fadeSeconds))
    }

    var stateJSON: String {
        let err = lastError.map { "\"\($0.replacingOccurrences(of: "\"", with: "'"))\"" } ?? "null"
        // presentationOptions and isActive are here because the menu bar over a
        // revealed PowerPoint show depends on both (docs/V4_SWITCHER.md, fact 8).
        return "{\"state\":\"\(state.rawValue)\",\"live\":\"\(liveSource.rawValue)\",\"armed\":\"\(external.rawValue)\",\"mode\":\"\(mode.rawValue)\",\"veil\":\(veil),\"reveal\":\(reveal),\"powerPointBlack\":\(powerPointBlack),\"captureRunning\":\(capture.isRunning),\"error\":\(err),\"fadeSeconds\":\(fadeSeconds),\"presenterActive\":\(NSApp.isActive),\"presentationOptions\":\(NSApp.presentationOptions.rawValue)}"
    }
}

/// The real windows: Presenter's program and confidence NSWindows, found by
/// title exactly as DisplayManager finds them.
struct NSWindowOutputs: SwitchEngine.OutputWindows {
    nonisolated init() {}   // used as a default argument, which is evaluated outside the actor

    func setAlpha(_ alpha: CGFloat, of output: OutputType, over seconds: Double) async {
        let title = output.windowTitle
        let targets = NSApplication.shared.windows.filter { $0.title == title && $0.isVisible }
        guard !targets.isEmpty else { return }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = seconds
                context.timingFunction = CAMediaTimingFunction(name: .linear)
                for window in targets { window.animator().alphaValue = alpha }
            }, completionHandler: {
                for window in targets { window.alphaValue = alpha }
                done.resume()
            })
        }
    }
}

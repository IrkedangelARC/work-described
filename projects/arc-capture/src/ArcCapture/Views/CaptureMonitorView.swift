//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI
import Combine

/// The real-time monitor: what the capture is doing, in the ARC PTZ console
/// language. Live frame with the phase overlaid; a fixed rail of modules
/// (DECK, NOW, STREAM, WARNINGS); the captured filmstrip with type badges;
/// the log. Used by the GUI while capturing and by `--watch` runs.
struct CaptureMonitorView: View {
    @Bindable var session: CaptureSession
    @State private var monitor = CaptureMonitor.shared
    @State private var ticker = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    private let thumbH: CGFloat = 72
    @Environment(\.captureLayout) private var layout

    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var windowsTick = 0

    var body: some View {
        VStack(spacing: 0) {
            CaptureHeader(screen: "MONITOR", subject: session.sourceFile?.deletingPathExtension().lastPathComponent, state: screenState, stateDetail: monitor.phase.uppercased()) {
                if session.state != .complete && session.state != .error {
                    Text("HANDS OFF THE KEYBOARD AND MOUSE").font(ARCTheme.mono(12, .heavy)).foregroundStyle(ARCTheme.ink)
                        .padding(.horizontal, 10).padding(.vertical, 6).background(ARCTheme.warn).cornerRadius(ARCTheme.cornerRadius)
                }
                Text(clock(monitor.elapsed)).font(ARCTheme.mono(22, .heavy)).foregroundStyle(ARCTheme.textPrimary).monospacedDigit()
            }
            ARCTheme.divider.frame(height: 1)
            VStack(spacing: ARCTheme.paddingSmall) {
                HStack(alignment: .top, spacing: ARCTheme.paddingSmall) {
                    preview
                        .arcModule(title: "PICTURE", tint: ARCTheme.secGreen,
                                   badge: monitor.recording ? ARCBandBadge(text: String(format: "REC %.1f s", monitor.recordingSeconds), fill: ARCTheme.arcRed) : nil)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    rail.scrollsWhenShort().frame(width: layout.railW)   // a short window scrolls the rail, never clips it
                }
                .frame(maxHeight: .infinity)
                filmstrip
                    .arcModule(title: "CAPTURED", tint: ARCTheme.secCrimson, badge: ARCBandBadge(text: "\(session.slides.count) OF \(monitor.totalSlides)", fill: ARCTheme.ink))
                CaptureLogList(lines: monitor.lines)
                    .frame(height: layout.logH)
                    .arcModule(title: "LOG", tint: ARCTheme.line)
                    .arcExpandButton("The whole log, with a filter", on: windowsTick >= 0 && ControlWindow.isOpen(title: CaptureWindows.log.title)) {
                        ControlWindow.toggle(id: CaptureWindows.log.id, title: CaptureWindows.log.title, open: openWindow, dismiss: dismissWindow)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { windowsTick += 1 }
                    }
            }
            .padding(.horizontal, ARCTheme.paddingMedium).padding(.vertical, ARCTheme.paddingSmall)
            CaptureFooter {
                FooterRow {
                    // Two ways out, and the difference matters under pressure: one keeps the slides captured so far, one keeps nothing (V3, plan 1.5).
                    ARCActionButton("STOP AND KEEP", enabled: !session.slides.isEmpty && session.state != .complete, fill: ARCTheme.secGreen) { Task { await session.stopAndKeep() } }
                        .help("End the show now and write a deck of the \(session.slides.count) slide(s) captured so far")
                    ARCChip("CANCEL", tint: ARCTheme.secOrange) { Task { await session.cancelCapture() } }.help("Stop the capture now and keep nothing")
                }
                .arcModule(title: "ACTION", tint: ARCTheme.secOrange, hugging: true)
                FooterRow {
                    ARCStatusTile(name: "STREAM", state: monitor.lastFrameAge > 5 ? String(format: "%.0f S AGO", monitor.lastFrameAge) : String(format: "%.0f FPS", monitor.framesPerSecond), level: monitor.lastFrameAge > 5 ? .warn : .ok, widest: ("STREAM", "120 S AGO"))
                    ARCStatusTile(name: "SOUND", state: monitor.soundAge < 0 ? "NONE YET" : (monitor.soundAge < 0.6 ? "PLAYING" : String(format: "SILENT %.0f S", monitor.soundAge)), level: monitor.soundAge < 0 ? .off : .ok, widest: ("SOUND", "SILENT 999 S"))
                    ARCStatusTile(name: "WARNINGS", state: monitor.warnings.isEmpty ? "NONE" : "\(monitor.warnings.count)", level: monitor.warnings.isEmpty ? .ok : .warn, widest: ("WARNINGS", "NONE"))
                    ARCStatusTile(name: "STALLS", state: "\(monitor.stalls)", level: monitor.stalls == 0 ? .ok : .warn, widest: ("STALLS", "99"))
                }
                .arcModule(title: "STATUS", tint: ARCTheme.secGreen, hugging: true)
                Spacer(minLength: 0)
            }
        }
        .background(ARCTheme.background)
        .onReceive(ticker) { _ in
            monitor.tick()
            let heard = session.audioMeter.lastAudibleAt
            monitor.soundAge = heard == .distantPast ? -1 : Date().timeIntervalSince(heard)
            if monitor.holdRemaining > 0 { monitor.holdRemaining = max(0, monitor.holdRemaining - 0.25) }
            if monitor.recording { monitor.recordingSeconds += 0.25 } else { monitor.recordingSeconds = 0 }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { _ in DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { windowsTick += 1 } }
    }

    private var screenState: CaptureScreenState {
        switch session.state {
        case .error: .error
        case .complete: .complete
        case .idle: .idle
        default: .capturing
        }
    }

    // MARK: Preview

    private var preview: some View {
        // The picture is the flexible element: it fills whatever the rail
        // leaves, aspect-fit and centred, never its native pixel size (it sat
        // small in the top-left corner, 2026-09-12).
        ZStack {
            Color.black
            if let frame = session.frameCapture.latestFrame {
                Image(nsImage: frame).resizable().aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                Text("no frames yet").font(ARCTheme.bodyText).foregroundStyle(ARCTheme.textTertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .overlay(alignment: .bottomLeading) {
            HStack(spacing: 8) {
                if monitor.recording {
                    HStack(spacing: 5) {
                        Circle().fill(ARCTheme.liveRed).frame(width: 8, height: 8)
                        Text("REC \(String(format: "%.1f", monitor.recordingSeconds)) s")
                    }
                }
                if monitor.holdTotal > 0 && monitor.holdRemaining > 0 {
                    Text("HOLD \(Int(monitor.holdRemaining)) s of \(Int(monitor.holdTotal))")
                }
                if monitor.clicksExpected >= 0 {
                    Text("CLICK \(monitor.clicksDone)/\(monitor.clicksExpected)")
                }
            }
            .font(ARCTheme.statusBadge).foregroundStyle(ARCTheme.textPrimary)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.black.opacity(0.6)).cornerRadius(4)
            .padding(12)
        }
        .cornerRadius(3)
    }

    // MARK: Rail

    private var rail: some View {
        VStack(spacing: ARCTheme.paddingSmall) {
            VStack(alignment: .leading, spacing: 3) {
                row("slides", "\(session.slides.count) of \(monitor.totalSlides)")
                row("hidden", "\(monitor.hiddenSlides)")
                row("movies", "\(monitor.movieSlides)")
                row("loops", "\(monitor.loopSlides)")
                row("auto-advance", "\(monitor.autoAdvanceSlides)")
                row("transitions", "\(monitor.transitionsCaptured) captured")
            }
            .arcModule(title: "DECK", tint: ARCTheme.secBlue)

            VStack(alignment: .leading, spacing: 3) {
                row("pptx slide", "\(monitor.pptxSlide)")
                row("phase", monitor.phase)
                row("clicks", monitor.clicksExpected >= 0 ? "\(monitor.clicksDone) / \(monitor.clicksExpected)" : "—")
                row("hold", monitor.holdRemaining > 0 ? "\(Int(monitor.holdRemaining)) s" : "—")
                row("recording", monitor.recording ? String(format: "%.1f s", monitor.recordingSeconds) : "—")
            }
            .arcModule(title: "NOW", tint: ARCTheme.secOrange)

            VStack(alignment: .leading, spacing: 3) {
                Text(monitor.lastCaptured).font(ARCTheme.mono(13, .heavy))
                    .foregroundStyle(monitor.lastCaptured.hasPrefix("TRANSITION") ? ARCTheme.arcRed : ARCTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .arcModule(title: "LAST CAPTURED", tint: monitor.lastCaptured.hasPrefix("TRANSITION") ? ARCTheme.arcRed : ARCTheme.secCrimson)

            // STREAM and WARNINGS live in the footer's STATUS tiles and the LOG window: the rail is the
            // constraining axis of this screen and five modules pushed the header under the title bar (2026-09-19).
            Spacer(minLength: 0)
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) {
            Text(k.uppercased()).font(ARCTheme.mono(12, .heavy)).foregroundStyle(ARCTheme.textSecondary)
            Spacer()
            Text(v).font(ARCTheme.mono(14, .heavy)).foregroundStyle(ARCTheme.textPrimary)
                .multilineTextAlignment(.trailing)
        }
    }

    // MARK: Filmstrip

    private var filmstrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 6) {
                    ForEach(session.slides) { s in
                      HStack(spacing: 6) {
                        if s.entryClipURL != nil || s.transition || s.transitionIn {
                            // The way into this slide, captured as its own clip
                            // (a separate entry clip, or the slide's whole clip
                            // being the transition). The thumbnail is the page.
                            VStack(spacing: 2) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 3).fill(ARCTheme.arcRed.opacity(0.22))
                                    RoundedRectangle(cornerRadius: 3).stroke(ARCTheme.arcRed, lineWidth: 2)
                                    Text("TRN").font(ARCTheme.mono(9, .heavy)).foregroundStyle(ARCTheme.arcRed)
                                        .rotationEffect(.degrees(-90)).fixedSize()
                                }
                                .frame(width: 22, height: thumbH)
                                Text("in").font(ARCTheme.mono(9, .heavy)).foregroundStyle(ARCTheme.arcRed)
                            }
                        }
                        VStack(spacing: 2) {
                            Image(nsImage: s.thumbnail).resizable().aspectRatio(contentMode: .fit)
                                .frame(width: thumbH * 16 / 9, height: thumbH)
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(badgeColor(s), lineWidth: 1))
                            HStack(spacing: 4) {
                                Text("\(s.pptxSlide ?? s.id)").font(ARCTheme.mono(11, .heavy)).foregroundStyle(ARCTheme.textSecondary)
                                Text(badge(s)).font(ARCTheme.mono(9, .heavy)).foregroundStyle(badgeColor(s))
                            }
                        }
                      }
                      .id(s.id)
                    }
                }
                .padding(.horizontal, ARCTheme.paddingSmall)
            }
            .frame(height: thumbH + 22)
            .onChange(of: session.slides.count) { _, _ in
                if let last = session.slides.last { withAnimation { proxy.scrollTo(last.id, anchor: .trailing) } }
            }
        }
    }

    private func badge(_ s: CaptureResult) -> String {
        if s.loop { return "LOOP" }
        if s.transition { return "IMG" }      // the TRN box before it is the clip; this is the page
        return s.isVideo ? "VID" : "IMG"
    }
    private func badgeColor(_ s: CaptureResult) -> Color {
        if s.loop { return ARCTheme.warn }
        if s.transition { return ARCTheme.line }
        return s.isVideo ? ARCTheme.secCrimson : ARCTheme.line
    }

    private func clock(_ t: TimeInterval) -> String { String(format: "%02d:%02d", Int(t) / 60, Int(t) % 60) }
}

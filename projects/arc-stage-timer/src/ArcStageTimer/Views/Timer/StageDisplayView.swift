//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI

/// Full-screen stage-facing view for external HDMI display or remote iPad.
/// Supports three output modes:
///   - Standard: Full-screen timer (original layout)
///   - Confidence Overlay: Timer elements at edges on transparent background (ATEM DSK)
///   - Confidence PIP: Timer surround with designated PIP zone (ATEM DVE)
///
/// When `isMatte` is true, renders white-on-black for ATEM linear key signal.
struct StageDisplayView: View {
    @Environment(StageDisplayState.self) private var display
    @Environment(\.openWindow) private var openWindow
    var confidenceConfig: ConfidenceMonitorConfig? = nil
    var isMatte: Bool = false
    /// When true, paints NO opaque backdrop — used by the DeckLink fill+key
    /// output, where window transparency becomes the key alpha channel.
    var transparentBackground: Bool = false

    private let messageScale: CGFloat = 0.75

    var body: some View {
        let scheme = display.colorScheme

        ZStack {
            if !transparentBackground {
                scheme.stageBackground.ignoresSafeArea()
            }

            if let config = confidenceConfig, config.isEnabled {
                // Confidence overlays render on dark backgrounds — except for
                // the DeckLink fill+key window, which stays fully transparent
                ZStack {
                    if !transparentBackground {
                        Color.black.ignoresSafeArea()
                    }
                    switch config.mode {
                    case .overlay:
                        confidenceOverlayContent(config: config)
                    case .pip:
                        confidencePIPContent(config: config)
                    }
                }
            } else {
                // Standard stage display
                ZStack {
                    layoutContent
                        .opacity(display.stageMode == .timer ? 1 : 0)
                    ClockDisplayView(stage: true)
                        .opacity(display.stageMode == .clock ? 1 : 0)
                    HoldDisplayView(
                        eventName: display.holdEventName,
                        stage: true
                    )
                    .opacity(display.stageMode == .hold ? 1 : 0)
                }
                .animation(.easeInOut(duration: 0.5), value: display.stageMode)
            }

            // TEXT ALERT (2026-09-24): a full-width red banner across the top that stays until cleared. Above
            // every layout and stage mode, below a flash.
            if let alert = display.alert {
                GeometryReader { geo in
                    VStack(spacing: 0) {
                        AlertBannerView(text: alert, fontSize: max(24, geo.size.height * 0.08),
                                        height: max(64, geo.size.height * 0.22), isMatte: isMatte)
                        Spacer(minLength: 0)
                    }
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .transition(.opacity)
            }

            // Flash overlay — full screen color burst
            if !isMatte, let flashColor = display.flashColor {
                flashColor
                    .ignoresSafeArea()
                    .opacity(display.flashOpacity)
                    .allowsHitTesting(false)
            } else if isMatte, display.flashOpacity > 0 {
                Color.white
                    .ignoresSafeArea()
                    .opacity(display.flashOpacity)
                    .allowsHitTesting(false)
            }
        }
        .preferredColorScheme(scheme.isLightBackground ? .light : .dark)
        .environment(\.displayColorScheme, scheme)
        #if os(macOS)
        // When only a stage window was restored, this view is the one that can open the console.
        .onReceive(NotificationCenter.default.publisher(for: .openControlWindow)) { _ in
            DisplayPlacement.openOutput(StageWindowID.control, using: openWindow)
        }
        #endif
    }

    // MARK: - Layouts

    /// The CONFIDENCE MONITOR layout picked on the console (StageLayout); CLASSIC is the original stack below.
    @ViewBuilder
    private var layoutContent: some View {
        switch display.stageLayout {
        case .classic: timerContent
        case .arc: StageArcLayout(isMatte: isMatte)
        case .bigNumber: StageBigNumberLayout(isMatte: isMatte)
        case .split: StageSplitLayout(isMatte: isMatte)
        case .clockAndTimer: StageClockAndTimerLayout(isMatte: isMatte)
        }
    }

    // MARK: - Standard Timer Content (original layout, CLASSIC)

    private var timerContent: some View {
        let showOffset = display.isScheduledShow && display.showStartedAt != nil
        let hasMessage = display.message != nil && !(display.message?.isEmpty ?? true) && display.messageOpacity > 0
        let sch = display.colorScheme

        return GeometryReader { geo in
            let totalHeight = geo.size.height
            let cueInfoFrac = sch.layoutCueInfoFraction
            let countdownFrac = sch.layoutCountdownFraction
            let progressFrac = sch.layoutProgressFraction
            let offsetFrac = sch.layoutOffsetFraction

            // ARC Style on the stage (2026-09-17: the ARC design applied to the stage display): a labelled
            // rule above the cue and a footer with the show and the mark. Both are carved out of the number's
            // share so the presets' fractions still sum to one. The number stays the biggest thing on the glass.
            let headerH = max(30, totalHeight * 0.045)
            let footerH = max(44, totalHeight * 0.065)
            let topH = totalHeight * cueInfoFrac
            // The header comes out of the cue zone below, the footer out of the number.
            let countdownH = totalHeight * (showOffset ? countdownFrac : countdownFrac + offsetFrac) - footerH
            let progressH = totalHeight * progressFrac
            let offsetH = showOffset ? totalHeight * offsetFrac : 0
            let labelSize = max(13, totalHeight * 0.02)
            let sideInset = max(24, geo.size.width * 0.025)

            ZStack {
                display.colorState.backgroundColor(for: display.colorScheme).ignoresSafeArea()

                VStack(spacing: 0) {
                    // NOW, on a hairline: the console's band, drawn as a rule so the ground stays black.
                    HStack(spacing: labelSize) {
                        stageLabel("NOW", size: labelSize, color: sch.textTertiary)
                        Rectangle().fill(sch.progressHairline).frame(height: 1)
                        if display.cueCount > 0 {
                            stageLabel("CUE \(display.cueIndex + 1) / \(display.cueCount)", size: labelSize, color: sch.textTertiary)
                        }
                    }
                    .padding(.horizontal, sideInset)
                    .frame(height: headerH, alignment: .bottom)
                    .padding(.bottom, labelSize * 0.5)

                    // Progress bar at top (Broadcast style)
                    if sch.progressPosition == .top && progressFrac > 0 {
                        stageProgressBar
                            .frame(height: progressH)
                            .padding(.horizontal, sch.progressStyle == .thinLine ? 0 : 40)
                    }

                    // Cue info zone OR message band
                    ZStack {
                        CueInfoPanel(
                            snapshot: display.currentCueSnapshot,
                            nextSnapshot: display.nextCueSnapshot,
                            stage: true
                        )
                        .opacity(hasMessage ? 0 : 1)

                        // A message is a BAND in the accent colour with ink text on it, the console's title
                        // band at stage size: it reads as an instruction from the desk, not as a caption. It
                        // was white text floating where the cue had been.
                        if let msg = display.message, !msg.isEmpty {
                            let bandFont = min(geo.size.width / CGFloat(max(msg.count, 8)) * 1.5, topH * 0.5)
                            Text(msg.uppercased())
                                .font(.system(size: bandFont, weight: .heavy, design: .monospaced))
                                .tracking(bandFont * 0.06)
                                .foregroundStyle(isMatte ? .black : ARCTheme.ink)
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                                .minimumScaleFactor(0.3)
                                .padding(.horizontal, sideInset)
                                .frame(maxWidth: .infinity)
                                .frame(height: topH * 0.72)
                                .background(isMatte ? Color.white : sch.stageAccent)
                                .clipShape(RoundedRectangle(cornerRadius: max(2, totalHeight * 0.004)))
                                .padding(.horizontal, sideInset)
                                // Under an ALERT the message waits: two bands on top of each other read as neither.
                                .opacity(display.alert == nil ? display.messageOpacity : 0)
                        }
                    }
                    .frame(height: topH - headerH - labelSize * 0.5)

                    // Countdown digits
                    CountdownDisplay(
                        displayTime: display.displayTime,
                        colorState: display.colorState,
                        isOvertime: display.isOvertime
                    )
                    .frame(height: countdownH)
                    .padding(.horizontal, sch.countdownHorizontalPadding)

                    // Progress bar at bottom (default position)
                    if sch.progressPosition == .bottom && progressFrac > 0 {
                        stageProgressBar
                            .frame(height: progressH)
                            .padding(.horizontal, sideInset)
                    }

                    // Offset banner
                    if showOffset {
                        offsetBanner(height: offsetH)
                            .frame(height: offsetH)
                    }

                    // Footer: the show on the left in mono caps, the ARC mark on the right, small and quiet.
                    // The only branding the room sees, and it never competes with the number.
                    HStack(alignment: .center, spacing: labelSize) {
                        stageLabel(showLabel, size: labelSize, color: sch.textTertiary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Image("ARCLogo")
                            .renderingMode(.template)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(height: footerH * 0.9)
                            .foregroundStyle(isMatte ? .white : (sch.isLightBackground ? ARCTheme.arcRed.opacity(0.55) : ARCTheme.arcRed.opacity(0.75)))
                    }
                    .padding(.horizontal, sideInset)
                    .frame(height: footerH)
                    .allowsHitTesting(false)
                }
            }
        }
    }

    /// The show's line in the footer: "JOB-0001  ANNUAL SUMMIT", or just the name, or nothing.
    private var showLabel: String {
        let name = display.showName.uppercased()
        if let arc = display.showArcNumber, !arc.isEmpty { return name.isEmpty ? arc : "\(arc)   \(name)" }
        return name
    }

    /// A console label at stage size: mono, heavy, caps, tracked.
    private func stageLabel(_ text: String, size: CGFloat, color: Color) -> some View {
        Text(text)
            .font(.system(size: size, weight: .heavy, design: .monospaced))
            .tracking(size * 0.14)
            .foregroundStyle(isMatte ? .white : color)
    }

    // MARK: - Confidence Overlay Content (transparent background, elements at edges)

    @ViewBuilder
    private func confidenceOverlayContent(config: ConfidenceMonitorConfig) -> some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let accentColor: Color = isMatte ? .white : display.colorState.color(for: display.colorScheme)

            // Accent bar
            accentBar(config: config, accentColor: accentColor, width: w, height: h)

            switch config.layout {
            case .cornerBrackets:
                cornerBracketsOverlay(config: config, width: w, height: h, accentColor: accentColor)
            case .glassBars:
                glassBarsOverlay(config: config, width: w, height: h, accentColor: accentColor)
            case .sidePanel:
                sidePanelOverlay(config: config, width: w, height: h, accentColor: accentColor)
            case .minimalCorners:
                minimalCornersOverlay(config: config, width: w, height: h, accentColor: accentColor)
            default:
                // PIP layouts shouldn't reach here, but fallback to corner brackets
                cornerBracketsOverlay(config: config, width: w, height: h, accentColor: accentColor)
            }

            // Message overlay — bottom edge so it doesn't obscure keyed video
            if config.showMessage, let msg = display.message, !msg.isEmpty {
                messageOverlay(msg, width: w, height: h, position: .bottom, scale: config.messageScale)
            }
        }
    }

    // MARK: - Confidence PIP Content (opaque surround with PIP zone)

    @ViewBuilder
    private func confidencePIPContent(config: ConfidenceMonitorConfig) -> some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let accentColor: Color = isMatte ? .white : display.colorState.color(for: display.colorScheme)

            // Opaque background (matte = black for key transparency)
            if !isMatte {
                display.colorState.backgroundColor(for: display.colorScheme).ignoresSafeArea()
            }

            switch config.layout {
            case .surroundClassic:
                surroundClassicPIP(config: config, width: w, height: h, accentColor: accentColor)
            case .surroundWide:
                surroundWidePIP(config: config, width: w, height: h, accentColor: accentColor)
            case .surroundStack:
                surroundStackPIP(config: config, width: w, height: h, accentColor: accentColor)
            default:
                surroundClassicPIP(config: config, width: w, height: h, accentColor: accentColor)
            }

            // PIP zone — transparent hole in matte, guide rect in fill
            pipZoneIndicator(config: config, width: w, height: h)

            // Accent bar
            accentBar(config: config, accentColor: accentColor, width: w, height: h)

            // Message overlay — bottom edge, below the countdown strip
            if config.showMessage, let msg = display.message, !msg.isEmpty {
                messageOverlay(msg, width: w, height: h, position: .bottom, scale: config.messageScale)
            }
        }
    }

    // MARK: - Overlay Layouts

    @ViewBuilder
    private func cornerBracketsOverlay(config: ConfidenceMonitorConfig, width: CGFloat, height: CGFloat, accentColor: Color) -> some View {
        let bracketLen: CGFloat = min(width, height) * 0.08
        let bracketThickness: CGFloat = max(config.accentBarSize, 2)
        let margin: CGFloat = 40 * CGFloat(config.elementMargin)
        let inset = CGFloat(config.overlayInset)

        // Top-left bracket + cue info
        if config.showCueInfo {
            VStack(alignment: .leading, spacing: 8) {
                CueInfoPanel(
                    snapshot: display.currentCueSnapshot,
                    nextSnapshot: config.showNextCue ? display.nextCueSnapshot : nil,
                    stage: true,
                    isMatte: isMatte
                )
            }
            // Anchored by its TOP-LEFT inside the bracket (2026-09-24). It was positioned by its CENTRE at
            // y = margin + 40, so a cue title at stage size (two lines and more) rose above the top of the screen:
            // The operator's field report, the KEY OVERLAY read "Remarks" with "Opening" cut off, on every display.
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: width * 0.5, alignment: .topLeading)
            .scaleEffect(CGFloat(config.cueInfoScale), anchor: .topLeading)
            .offset(x: Self.cueInfoTopLeft(width: width, height: height, margin: margin, rule: bracketThickness, inset: inset).x,
                    y: Self.cueInfoTopLeft(width: width, height: height, margin: margin, rule: bracketThickness, inset: inset).y)
        }

        // L-bracket top-left
        Path { p in
            p.move(to: CGPoint(x: margin, y: margin + bracketLen))
            p.addLine(to: CGPoint(x: margin, y: margin))
            p.addLine(to: CGPoint(x: margin + bracketLen, y: margin))
        }
        .stroke(accentColor, lineWidth: bracketThickness)

        // Bottom-right bracket + countdown
        if config.showCountdown {
            CountdownDisplay(
                displayTime: display.displayTime,
                colorState: display.colorState,
                isOvertime: display.isOvertime,
                isMatte: isMatte
            )
            .frame(width: width * 0.35 * CGFloat(config.countdownScale), height: height * 0.2 * CGFloat(config.countdownScale))
            .position(
                x: lerp(width - margin - width * 0.175, width / 2, t: inset),
                y: lerp(height - margin - height * 0.12, height / 2, t: inset)
            )
        }

        // L-bracket bottom-right
        Path { p in
            p.move(to: CGPoint(x: width - margin, y: height - margin - bracketLen))
            p.addLine(to: CGPoint(x: width - margin, y: height - margin))
            p.addLine(to: CGPoint(x: width - margin - bracketLen, y: height - margin))
        }
        .stroke(accentColor, lineWidth: bracketThickness)

        // Progress bar along bottom
        if config.showProgressBar {
            stageProgressBar
                .frame(width: width - margin * 2, height: 6 * CGFloat(config.progressBarScale))
                .position(x: width / 2, y: height - margin / 2)
        }

        // Offset in bottom-left
        if config.showOffset, display.isScheduledShow, display.showStartedAt != nil {
            offsetBanner(height: 40 * CGFloat(config.offsetScale))
                .position(
                    x: lerp(margin + 120, width / 2, t: inset),
                    y: lerp(height - margin - 20, height / 2, t: inset)
                )
        }
    }

    /// Where the corner-brackets overlay puts the TOP-LEFT of its cue-info block: just inside the top-left
    /// bracket, moving toward the centre as the operator's inset grows. Never above the top of the screen.
    static func cueInfoTopLeft(width: CGFloat, height: CGFloat, margin: CGFloat, rule: CGFloat, inset: CGFloat) -> CGPoint {
        let t = min(max(inset, 0), 1)
        let home = CGPoint(x: margin + rule + 12, y: margin + rule + 8)
        let centre = CGPoint(x: width * 0.25, y: height * 0.25)
        return CGPoint(x: home.x + (centre.x - home.x) * t, y: max(0, home.y + (centre.y - home.y) * t))
    }

    /// Linear interpolation helper for overlay inset positioning
    private func lerp(_ a: CGFloat, _ b: CGFloat, t: CGFloat) -> CGFloat {
        a + (b - a) * t
    }

    @ViewBuilder
    private func glassBarsOverlay(config: ConfidenceMonitorConfig, width: CGFloat, height: CGFloat, accentColor: Color) -> some View {
        let barHeight: CGFloat = height * 0.12 * CGFloat(config.elementMargin)

        // Top glass bar
        ZStack {
            if !isMatte {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .environment(\.colorScheme, .dark)
                    .opacity(0.85)
            } else {
                Rectangle().fill(Color.white)
            }

            HStack {
                if config.showCueInfo {
                    CueInfoPanel(
                        snapshot: display.currentCueSnapshot,
                        nextSnapshot: config.showNextCue ? display.nextCueSnapshot : nil,
                        compact: true,
                        stage: true,
                        isMatte: isMatte
                    )
                    .scaleEffect(CGFloat(config.cueInfoScale))
                }
                Spacer()
                if config.showClock {
                    Text(timeString())
                        .font(.system(size: barHeight * 0.4, weight: .light, design: .monospaced))
                        .foregroundStyle(isMatte ? .white : ARCTheme.textSecondary)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 30)
        }
        .frame(width: width, height: barHeight)
        .position(x: width / 2, y: barHeight / 2)

        // Bottom glass bar
        ZStack {
            if !isMatte {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .environment(\.colorScheme, .dark)
                    .opacity(0.85)
            } else {
                Rectangle().fill(Color.white)
            }

            HStack(spacing: 20) {
                if config.showCountdown {
                    CountdownDisplay(
                        displayTime: display.displayTime,
                        colorState: display.colorState,
                        isOvertime: display.isOvertime,
                        isMatte: isMatte
                    )
                    .scaleEffect(CGFloat(config.countdownScale))
                    .frame(maxWidth: width * 0.4)
                }

                if config.showProgressBar {
                    stageProgressBar
                        .frame(maxWidth: width * 0.4, maxHeight: 12 * CGFloat(config.progressBarScale))
                }

                if config.showOffset, display.isScheduledShow, display.showStartedAt != nil {
                    offsetBanner(height: barHeight * 0.6 * CGFloat(config.offsetScale))
                }
            }
            .padding(.horizontal, 30)
        }
        .frame(width: width, height: barHeight)
        .position(x: width / 2, y: height - barHeight / 2)
    }

    @ViewBuilder
    private func sidePanelOverlay(config: ConfidenceMonitorConfig, width: CGFloat, height: CGFloat, accentColor: Color) -> some View {
        let panelWidth: CGFloat = width * 0.22 * CGFloat(config.elementMargin)

        ZStack {
            if !isMatte {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .environment(\.colorScheme, .dark)
                    .opacity(0.9)
            } else {
                Rectangle().fill(Color.white)
            }

            VStack(spacing: 16) {
                if config.showCueInfo {
                    CueInfoPanel(
                        snapshot: display.currentCueSnapshot,
                        nextSnapshot: config.showNextCue ? display.nextCueSnapshot : nil,
                        compact: true,
                        stage: true,
                        isMatte: isMatte
                    )
                    .scaleEffect(CGFloat(config.cueInfoScale))
                }

                Spacer()

                if config.showCountdown {
                    CountdownDisplay(
                        displayTime: display.displayTime,
                        colorState: display.colorState,
                        isOvertime: display.isOvertime,
                        isMatte: isMatte
                    )
                    .frame(height: height * 0.2 * CGFloat(config.countdownScale))
                }

                if config.showProgressBar {
                    stageProgressBar
                        .frame(height: 8 * CGFloat(config.progressBarScale))
                        .padding(.horizontal, 12)
                }

                if config.showOffset, display.isScheduledShow, display.showStartedAt != nil {
                    offsetBanner(height: 30 * CGFloat(config.offsetScale))
                }

                Spacer()
            }
            .padding(.vertical, 20)
        }
        .frame(width: panelWidth, height: height)
        .position(x: panelWidth / 2, y: height / 2)
    }

    @ViewBuilder
    private func minimalCornersOverlay(config: ConfidenceMonitorConfig, width: CGFloat, height: CGFloat, accentColor: Color) -> some View {
        let margin: CGFloat = 40 * CGFloat(config.elementMargin)
        let inset = CGFloat(config.overlayInset)

        // Countdown bottom-right — large
        if config.showCountdown {
            CountdownDisplay(
                displayTime: display.displayTime,
                colorState: display.colorState,
                isOvertime: display.isOvertime,
                isMatte: isMatte
            )
            .frame(width: width * 0.3 * CGFloat(config.countdownScale), height: height * 0.15 * CGFloat(config.countdownScale))
            .position(
                x: lerp(width - margin - width * 0.15, width / 2, t: inset),
                y: lerp(height - margin - height * 0.08, height / 2, t: inset)
            )
        }

        // Cue title top-left — small
        if config.showCueInfo, let snap = display.currentCueSnapshot {
            VStack(alignment: .leading, spacing: 4) {
                Text(snap.title)
                    .font(.system(size: 20 * CGFloat(config.cueInfoScale), weight: .bold))
                    .foregroundStyle(isMatte ? .white : ARCTheme.textPrimary)
                    .lineLimit(1)
                if let speakers = snap.speakers, !speakers.isEmpty {
                    Text(speakers)
                        .font(.system(size: 14 * CGFloat(config.cueInfoScale), weight: .medium))
                        .foregroundStyle(isMatte ? .white : ARCTheme.accent)
                        .lineLimit(1)
                }
            }
            .position(
                x: lerp(margin + 100, width / 2, t: inset),
                y: lerp(margin + 20, height / 2, t: inset)
            )
        }

        // Progress bar bottom edge
        if config.showProgressBar {
            stageProgressBar
                .frame(width: width - margin * 2, height: 4 * CGFloat(config.progressBarScale))
                .position(x: width / 2, y: height - margin / 2)
        }
    }

    // MARK: - PIP Layouts

    @ViewBuilder
    private func surroundClassicPIP(config: ConfidenceMonitorConfig, width: CGFloat, height: CGFloat, accentColor: Color) -> some View {
        let mg = CGFloat(config.elementMargin)
        let topH = height * 0.15 * mg
        let bottomH = height * 0.2 * mg

        // Top strip — cue info
        if config.showCueInfo {
            CueInfoPanel(
                snapshot: display.currentCueSnapshot,
                nextSnapshot: config.showNextCue ? display.nextCueSnapshot : nil,
                compact: true,
                stage: true,
                isMatte: isMatte
            )
            .scaleEffect(CGFloat(config.cueInfoScale))
            .frame(width: width, height: topH)
            .position(x: width / 2, y: topH / 2)
        }

        // Bottom strip — countdown + progress
        VStack(spacing: 8) {
            if config.showCountdown {
                CountdownDisplay(
                    displayTime: display.displayTime,
                    colorState: display.colorState,
                    isOvertime: display.isOvertime,
                    isMatte: isMatte
                )
                .frame(height: bottomH * 0.65 * CGFloat(config.countdownScale))
            }

            if config.showProgressBar {
                stageProgressBar
                    .frame(height: 10 * CGFloat(config.progressBarScale))
                    .padding(.horizontal, 40)
            }

            if config.showOffset, display.isScheduledShow, display.showStartedAt != nil {
                offsetBanner(height: bottomH * 0.2 * CGFloat(config.offsetScale))
            }
        }
        .frame(width: width, height: bottomH)
        .position(x: width / 2, y: height - bottomH / 2)
    }

    @ViewBuilder
    private func surroundWidePIP(config: ConfidenceMonitorConfig, width: CGFloat, height: CGFloat, accentColor: Color) -> some View {
        let panelWidth = width * 0.28 * CGFloat(config.elementMargin)

        // Left panel — all timer info
        VStack(spacing: 16) {
            if config.showCueInfo {
                CueInfoPanel(
                    snapshot: display.currentCueSnapshot,
                    nextSnapshot: config.showNextCue ? display.nextCueSnapshot : nil,
                    compact: true,
                    stage: true,
                    isMatte: isMatte
                )
                .scaleEffect(CGFloat(config.cueInfoScale))
            }

            Spacer()

            if config.showCountdown {
                CountdownDisplay(
                    displayTime: display.displayTime,
                    colorState: display.colorState,
                    isOvertime: display.isOvertime,
                    isMatte: isMatte
                )
                .frame(height: height * 0.25 * CGFloat(config.countdownScale))
            }

            if config.showProgressBar {
                stageProgressBar
                    .frame(height: 8 * CGFloat(config.progressBarScale))
                    .padding(.horizontal, 12)
            }

            if config.showOffset, display.isScheduledShow, display.showStartedAt != nil {
                offsetBanner(height: 30 * CGFloat(config.offsetScale))
            }

            Spacer()
        }
        .padding(.vertical, 20)
        .frame(width: panelWidth, height: height)
        .position(x: panelWidth / 2, y: height / 2)
    }

    @ViewBuilder
    private func surroundStackPIP(config: ConfidenceMonitorConfig, width: CGFloat, height: CGFloat, accentColor: Color) -> some View {
        let mg = CGFloat(config.elementMargin)
        let topH = height * 0.12 * mg
        let bottomH = height * 0.15 * mg

        // Compact countdown top
        if config.showCountdown {
            CountdownDisplay(
                displayTime: display.displayTime,
                colorState: display.colorState,
                isOvertime: display.isOvertime,
                isMatte: isMatte
            )
            .scaleEffect(CGFloat(config.countdownScale))
            .frame(width: width, height: topH)
            .position(x: width / 2, y: topH / 2)
        }

        // Info strip bottom
        HStack(spacing: 16) {
            if config.showCueInfo {
                CueInfoPanel(
                    snapshot: display.currentCueSnapshot,
                    nextSnapshot: config.showNextCue ? display.nextCueSnapshot : nil,
                    compact: true,
                    stage: true,
                    isMatte: isMatte
                )
                .scaleEffect(CGFloat(config.cueInfoScale))
            }
            if config.showProgressBar {
                stageProgressBar
                    .frame(maxWidth: width * 0.3, maxHeight: 8 * CGFloat(config.progressBarScale))
            }
        }
        .frame(width: width, height: bottomH)
        .position(x: width / 2, y: height - bottomH / 2)
    }

    // MARK: - Shared Components

    @ViewBuilder
    private func pipZoneIndicator(config: ConfidenceMonitorConfig, width: CGFloat, height: CGFloat) -> some View {
        let zoneRect = CGRect(
            x: config.pipZoneX * width,
            y: config.pipZoneY * height,
            width: config.pipZoneWidth * width,
            height: config.pipZoneHeight * height
        )

        if isMatte {
            // Black rectangle in key = transparent in ATEM composite
            Rectangle()
                .fill(Color.black)
                .frame(width: zoneRect.width, height: zoneRect.height)
                .position(x: zoneRect.midX, y: zoneRect.midY)
        }
        // Fill output: no indicator needed (ATEM DVE places content here)
    }

    @ViewBuilder
    private func accentBar(config: ConfidenceMonitorConfig, accentColor: Color, width: CGFloat, height: CGFloat) -> some View {
        let size = config.accentBarSize

        switch config.accentBarPosition {
        case .top:
            Rectangle().fill(accentColor)
                .frame(width: width, height: size)
                .position(x: width / 2, y: size / 2)
        case .bottom:
            Rectangle().fill(accentColor)
                .frame(width: width, height: size)
                .position(x: width / 2, y: height - size / 2)
        case .left:
            Rectangle().fill(accentColor)
                .frame(width: size, height: height)
                .position(x: size / 2, y: height / 2)
        case .right:
            Rectangle().fill(accentColor)
                .frame(width: size, height: height)
                .position(x: width - size / 2, y: height / 2)
        }
    }

    enum MessagePosition {
        case center, bottom
    }

    @ViewBuilder
    private func messageOverlay(_ msg: String, width: CGFloat, height: CGFloat, position: MessagePosition = .center, scale: Double = 1.0) -> some View {
        let yPos: CGFloat = switch position {
        case .center: height / 2
        case .bottom: height - height * 0.05
        }

        Text(msg.uppercased())
            .font(.system(size: height * 0.08 * CGFloat(scale), weight: .bold, design: display.colorScheme.fontDesign))
            .foregroundStyle(.white)
            .shadow(color: display.colorScheme.textShadowColor, radius: display.colorScheme.textShadowRadius, x: display.colorScheme.textShadowX, y: display.colorScheme.textShadowY)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .minimumScaleFactor(0.3)
            .frame(maxWidth: width * 0.8)
            .position(x: width / 2, y: yPos)
            .opacity(display.messageOpacity)
    }

    private var stageProgressBar: some View {
        let snap = display.currentCueSnapshot
        let duration = Double(snap?.durationSeconds ?? 1)
        let warnFrac = duration > 0 ? Double(snap?.warningThreshold ?? 0) / duration : 0
        let dangerFrac = duration > 0 ? Double(snap?.dangerThreshold ?? 0) / duration : 0

        return ProgressBar(
            progress: display.progress,
            colorState: display.colorState,
            warningThreshold: warnFrac,
            dangerThreshold: dangerFrac,
            height: 40,
            isMatte: isMatte
        )
    }

    private func offsetBanner(height: CGFloat) -> some View {
        let status = display.offsetStatus
        let fontSize = max(height * 0.35, 16)
        let labelSize = max(height * 0.2, 12)
        let design = display.colorScheme.fontDesign
        return HStack(spacing: 16) {
            Text(display.showOffsetDisplay)
                .font(.system(size: fontSize, weight: .heavy, design: design))
            Text(status.label)
                .font(.system(size: labelSize, weight: .bold, design: design))
                .tracking(2)
        }
        .foregroundStyle(isMatte ? .white : status.color)
        .shadow(color: isMatte ? .clear : display.colorScheme.textShadowColor, radius: display.colorScheme.textShadowRadius, x: display.colorScheme.textShadowX, y: display.colorScheme.textShadowY)
        .padding(.horizontal, 40)
        .padding(.vertical, 8)
        .background(isMatte ? Color.white.opacity(0.3) : status.color.opacity(0.18), in: Capsule())
        .shadow(color: isMatte ? .clear : display.colorScheme.elementShadowColor, radius: display.colorScheme.elementShadowRadius, x: display.colorScheme.elementShadowX, y: display.colorScheme.elementShadowY)
    }

    private func timeString() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "h:mm a"
        return fmt.string(from: .now)
    }
}

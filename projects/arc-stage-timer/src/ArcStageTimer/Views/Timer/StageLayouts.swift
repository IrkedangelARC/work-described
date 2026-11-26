//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI

// MARK: - Layout

/// How the CONFIDENCE MONITOR arranges its pieces (2026-09-25: a variety of looks and
/// layouts, starting with an ARC style). Independent of the Display Theme, which sets colours and type,
/// so every layout works in every theme.
enum StageLayout: String, CaseIterable, Identifiable, Codable {
    /// The console's bracket modules at stage size: NOW, TIMER, then NEXT / TIME / ENDS.
    case arc
    /// The original stack: cue on top, the number, the progress bar.
    case classic
    /// The number and almost nothing else, for a speaker far from the monitor.
    case bigNumber
    /// The number on the left, a column of NOW / NEXT / TIME / ENDS on the right.
    case split
    /// Time remaining and time of day with equal weight, for a room that runs on the clock.
    case clockAndTimer

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .arc: "ARC"
        case .classic: "Classic"
        case .bigNumber: "Big Number"
        case .split: "Split"
        case .clockAndTimer: "Clock + Timer"
        }
    }

    var description: String {
        switch self {
        case .arc: "Bracket modules · NOW, TIMER, NEXT, TIME, ENDS"
        case .classic: "Cue on top · number · progress bar"
        case .bigNumber: "The number fills the glass · one line of cue"
        case .split: "Number left · NOW, NEXT, TIME, ENDS right"
        case .clockAndTimer: "Remaining and time of day, equal size"
        }
    }

    var icon: String {
        switch self {
        case .arc: "square.split.1x2"
        case .classic: "rectangle.split.1x2"
        case .bigNumber: "textformat.size.larger"
        case .split: "rectangle.split.2x1"
        case .clockAndTimer: "clock"
        }
    }

    static let defaultsKey = "stageLayout"

    /// The last layout picked on this Mac (ARC when none has been).
    static var saved: StageLayout {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(StageLayout.init(rawValue:)) ?? .arc
    }
}

// MARK: - Shared pieces

/// What the stage layouts share: the words for the timer's state, the time a cue ends, labels.
struct StageParts {
    let display: StageDisplayState
    let isMatte: Bool

    var scheme: DisplayColorScheme { display.colorScheme }

    /// The timer's state in a word the speaker can act on.
    var stateWord: String {
        if display.state == "paused" { return "PAUSED" }
        switch display.colorState {
        case .idle: return "STANDBY"
        case .nominal: return "RUNNING"
        case .warning: return "WRAP UP"
        case .danger: return "FINAL"
        case .overtime: return "OVERTIME"
        }
    }

    var stateColor: Color {
        if isMatte { return .white }
        if display.state == "paused" { return scheme.textTertiary }
        return display.colorState.color(for: scheme)
    }

    var showOffset: Bool { display.isScheduledShow && display.showStartedAt != nil }

    var hasMessage: Bool { !(display.message ?? "").isEmpty && display.messageOpacity > 0 && display.alert == nil }

    var showLabel: String {
        let name = display.showName.uppercased()
        if let arc = display.showArcNumber, !arc.isEmpty { return name.isEmpty ? arc : "\(arc)   \(name)" }
        return name
    }

    func color(_ c: Color) -> Color { isMatte ? .white : c }

    /// A console label at stage size: mono, heavy, caps, tracked.
    func label(_ text: String, size: CGFloat, color c: Color? = nil) -> some View {
        Text(text.uppercased())
            .font(.system(size: size, weight: .heavy, design: .monospaced))
            .tracking(size * 0.14)
            .foregroundStyle(color(c ?? scheme.textTertiary))
            .lineLimit(1)
    }

    func title(_ text: String, size: CGFloat) -> some View {
        Text(text)
            .font(.system(size: size, weight: scheme.titleWeight, design: scheme.fontDesign))
            .foregroundStyle(color(scheme.textPrimary))
            .lineLimit(2)
            .minimumScaleFactor(0.4)
    }

    func speakers(_ text: String, size: CGFloat) -> some View {
        Text(text)
            .font(.system(size: size, weight: scheme.speakersWeight, design: scheme.fontDesign))
            .foregroundStyle(color(scheme.stageAccent))
            .lineLimit(1)
            .minimumScaleFactor(0.4)
    }

    func secondary(_ text: String, size: CGFloat) -> some View {
        Text(text)
            .font(.system(size: size, weight: scheme.subtitleWeight, design: scheme.fontDesign))
            .foregroundStyle(color(scheme.textSecondary))
            .lineLimit(1)
            .minimumScaleFactor(0.4)
    }

    var countdown: some View {
        CountdownDisplay(displayTime: display.displayTime, colorState: display.colorState,
                         isOvertime: display.isOvertime, isMatte: isMatte)
    }

    func progress(height: CGFloat) -> some View {
        let snap = display.currentCueSnapshot
        let duration = Double(max(snap?.durationSeconds ?? 1, 1))
        return ProgressBar(progress: display.progress, colorState: display.colorState,
                           warningThreshold: Double(snap?.warningThreshold ?? 0) / duration,
                           dangerThreshold: Double(snap?.dangerThreshold ?? 0) / duration,
                           height: height, isMatte: isMatte)
    }

    static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm"
        return f
    }()

    static let meridiemFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "a"
        return f
    }()

    /// When the cue ends at this rate: now plus what is left (nil while nothing is running or in overtime).
    func endsAt(_ now: Date) -> Date? {
        guard display.state == "running" || display.state == "paused", !display.isOvertime,
              display.remainingSeconds > 0 else { return nil }
        return now.addingTimeInterval(Double(display.remainingSeconds))
    }

    /// The schedule readout: "+4:12" BEHIND in a scheduled show, else the clock time the cue ends ("10:42" AM).
    /// `unit` sits after the value; `status` is the offset's word, only in a scheduled show.
    func scheduleReadout(_ now: Date) -> (value: String, unit: String, status: String?, color: Color) {
        if showOffset {
            return (display.showOffsetDisplay, "", display.offsetStatus.label, color(display.offsetStatus.color))
        }
        if let end = endsAt(now) {
            return (Self.clockFormatter.string(from: end), Self.meridiemFormatter.string(from: end), nil, color(scheme.textPrimary))
        }
        return ("--:--", "", nil, color(scheme.textTertiary))
    }
}

/// The desk's message at stage size: a band in the accent colour with ink text, the console's title band.
struct StageMessageBand: View {
    let text: String
    let height: CGFloat
    let isMatte: Bool
    @Environment(\.displayColorScheme) private var scheme

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width / CGFloat(max(text.count, 8)) * 1.5, height * 0.62)
            Text(text.uppercased())
                .font(.system(size: size, weight: .heavy, design: .monospaced))
                .tracking(size * 0.06)
                .foregroundStyle(isMatte ? .black : ARCTheme.ink)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.3)
                .padding(.horizontal, size * 0.4)
                .frame(width: geo.size.width, height: geo.size.height)
                .background(isMatte ? Color.white : scheme.stageAccent)
                .clipShape(RoundedRectangle(cornerRadius: max(2, height * 0.03)))
        }
        .frame(height: height)
    }
}

extension View {
    /// THE BRACKET at stage size, drawn on the theme's own ground so light themes keep a light glass:
    /// a filled title band in `tint` with ink text, a thickened leading rule, a 6-unit corner.
    func stageBracket(_ title: String, tint: Color, badge: String? = nil, badgeTint: Color? = nil,
                      scale s: CGFloat, ground: Color) -> some View {
        let r = 6 * min(s, 3)
        let band = (11 * s).rounded() + 9 * s
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text(title.uppercased())
                    .font(.system(size: (11 * s).rounded(), weight: .heavy, design: .monospaced))
                    .tracking(1.4 * s)
                    .foregroundStyle(ARCTheme.ink)
                    .lineLimit(1)
                    .padding(.leading, 8 * s)
                Spacer(minLength: 6 * s)
                if let badge {
                    Rectangle().fill(ground).frame(width: 2 * s)
                    Text(badge.uppercased())
                        .font(.system(size: (10 * s).rounded(), weight: .heavy, design: .monospaced))
                        .foregroundStyle(badgeTint == nil ? ARCTheme.text0 : ARCTheme.ink)
                        .lineLimit(1).fixedSize()
                        .padding(.horizontal, 8 * s)
                        .frame(maxHeight: .infinity)
                        .background(badgeTint ?? ARCTheme.ink)
                }
            }
            .frame(height: band)
            .background(tint)
            self
                .padding(8 * s)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(ground)
        .overlay(alignment: .leading) { Rectangle().fill(tint).frame(width: 4 * min(s, 3)) }
        .clipShape(RoundedRectangle(cornerRadius: r))
        .overlay(RoundedRectangle(cornerRadius: r).strokeBorder(tint, lineWidth: 1.5 * min(s, 3)))
    }
}

// MARK: - ARC

/// The console's language on the glass. NOW (orange, the operate colour), the TIMER whose band IS the
/// timer's state, then NEXT, TIME and ENDS in a row, and the show with the mark underneath.
struct StageArcLayout: View {
    @Environment(StageDisplayState.self) private var display
    var isMatte: Bool = false

    var body: some View {
        let p = StageParts(display: display, isMatte: isMatte)
        let sch = p.scheme
        GeometryReader { geo in
            let H = geo.size.height, W = geo.size.width
            let s = max(1, min(H / 420, W / 760))            // band, rule and padding grow with the glass
            let pad = max(10, H * 0.016), gap = max(6, H * 0.011)
            let nowH = H * 0.24, rowH = H * 0.17, footH = max(28, H * 0.045)
            let ground = sch.isLightBackground ? sch.stageBackground : Color(red: 0x10/255, green: 0x11/255, blue: 0x13/255)
            let neutral = sch.isLightBackground ? Color(white: 0.55) : ARCTheme.text2

            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let now = ctx.date
                VStack(spacing: gap) {
                    // NOW
                    ZStack {
                        HStack(alignment: .center, spacing: 0) {
                            VStack(alignment: .leading, spacing: nowH * 0.03) {
                                p.title(display.currentCueSnapshot?.title ?? "—", size: nowH * 0.30)
                                if let sub = display.currentCueSnapshot?.subtitle, !sub.isEmpty {
                                    p.secondary(sub, size: nowH * 0.15)
                                }
                                if let sp = display.currentCueSnapshot?.speakers, !sp.isEmpty {
                                    p.speakers(sp, size: nowH * 0.15)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .opacity(p.hasMessage ? 0 : 1)
                        if p.hasMessage, let msg = display.message {
                            StageMessageBand(text: msg, height: nowH * 0.62, isMatte: isMatte)
                                .opacity(display.messageOpacity)
                        }
                    }
                    .stageBracket("Now", tint: p.color(ARCTheme.secOrange),
                                  badge: display.cueCount > 0 ? "CUE \(display.cueIndex + 1) / \(display.cueCount)" : nil,
                                  scale: s, ground: ground)
                    .frame(height: nowH)

                    // TIMER: the band is the state
                    VStack(spacing: gap) {
                        p.countdown
                        p.progress(height: max(8, H * 0.018))
                    }
                    .stageBracket("Timer", tint: p.stateColor, badge: p.stateWord, scale: s, ground: ground)

                    // NEXT · TIME · ENDS
                    HStack(spacing: gap) {
                        VStack(alignment: .leading, spacing: rowH * 0.04) {
                            p.title(display.nextCueSnapshot?.title ?? "End of show", size: rowH * 0.26)
                                .foregroundStyle(p.color(sch.textSecondary))
                            if let sp = display.nextCueSnapshot?.speakers, !sp.isEmpty {
                                p.speakers(sp, size: rowH * 0.17)
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .stageBracket("Next", tint: p.color(ARCTheme.secBlue), scale: s, ground: ground)
                        .frame(width: W * 0.46)

                        readout(StageParts.clockFormatter.string(from: now), unit: StageParts.meridiemFormatter.string(from: now),
                                color: p.color(sch.textPrimary), rowH: rowH, p: p)
                            .stageBracket("Time", tint: p.color(ARCTheme.secGreen), scale: s, ground: ground)

                        let sched = p.scheduleReadout(now)
                        readout(sched.value, unit: sched.unit, color: sched.color, rowH: rowH, p: p)
                            .stageBracket(p.showOffset ? "Schedule" : "Ends", tint: p.color(neutral),
                                          badge: sched.status, scale: s, ground: ground)
                    }
                    .frame(height: rowH)

                    // The show and the mark
                    HStack {
                        p.label(p.showLabel, size: footH * 0.42)
                        Spacer(minLength: 0)
                        Image("ARCLogo").renderingMode(.template).resizable().aspectRatio(contentMode: .fit)
                            .frame(height: footH * 0.8)
                            .foregroundStyle(isMatte ? .white : ARCTheme.arcRed.opacity(sch.isLightBackground ? 0.55 : 0.75))
                    }
                    .frame(height: footH)
                }
                .padding(pad)
            }
        }
    }

    private func readout(_ value: String, unit: String, color: Color, rowH: CGFloat, p: StageParts) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: rowH * 0.05) {
            Text(value)
                .font(.system(size: rowH * 0.38, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(color)
                .lineLimit(1).minimumScaleFactor(0.4)
            if !unit.isEmpty {
                p.label(unit, size: rowH * 0.14)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Big Number

/// The number fills the glass. One line above it says what is on and what is next.
struct StageBigNumberLayout: View {
    @Environment(StageDisplayState.self) private var display
    var isMatte: Bool = false

    var body: some View {
        let p = StageParts(display: display, isMatte: isMatte)
        GeometryReader { geo in
            let H = geo.size.height
            let lineH = H * 0.09, pad = max(16, geo.size.width * 0.02)
            ZStack(alignment: .top) {
                display.colorState.backgroundColor(for: p.scheme).opacity(isMatte ? 0 : 1)
                VStack(spacing: 0) {
                    HStack(spacing: lineH * 0.3) {
                        p.title(display.currentCueSnapshot?.title ?? "", size: lineH * 0.5)
                            .lineLimit(1)
                        Spacer(minLength: lineH)
                        if let next = display.nextCueSnapshot?.title {
                            p.label("Next", size: lineH * 0.26)
                            p.secondary(next, size: lineH * 0.4)
                        }
                    }
                    .padding(.horizontal, pad)
                    .frame(height: lineH)
                    p.countdown
                        .padding(.horizontal, pad * 0.5)
                    p.progress(height: max(6, H * 0.012))
                        .padding(.horizontal, pad)
                        .padding(.bottom, pad * 0.8)
                }
                if p.hasMessage, let msg = display.message {
                    StageMessageBand(text: msg, height: H * 0.2, isMatte: isMatte)
                        .padding(pad)
                        .opacity(display.messageOpacity)
                }
            }
        }
    }
}

// MARK: - Split

/// The number on the left, the words on the right, hairlines between.
struct StageSplitLayout: View {
    @Environment(StageDisplayState.self) private var display
    var isMatte: Bool = false

    var body: some View {
        let p = StageParts(display: display, isMatte: isMatte)
        let sch = p.scheme
        GeometryReader { geo in
            let H = geo.size.height, W = geo.size.width
            let pad = max(16, W * 0.02)
            let colW = W * 0.36
            let unit = H / 4
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let now = ctx.date
                ZStack(alignment: .top) {
                    display.colorState.backgroundColor(for: sch).opacity(isMatte ? 0 : 1)
                    HStack(spacing: 0) {
                        VStack(spacing: pad * 0.5) {
                            HStack {
                                p.label(p.stateWord, size: H * 0.03, color: p.stateColor)
                                Spacer()
                                if display.cueCount > 0 { p.label("CUE \(display.cueIndex + 1) / \(display.cueCount)", size: H * 0.03) }
                            }
                            p.countdown
                            p.progress(height: max(8, H * 0.016))
                        }
                        .padding(pad)
                        .frame(width: W - colW)

                        Rectangle().fill(p.color(sch.progressHairline)).frame(width: 1).padding(.vertical, pad)

                        VStack(alignment: .leading, spacing: 0) {
                            cell("Now", h: unit * 1.3) {
                                // Under a message the band covers this cell; a two-line title would show below it.
                                VStack(alignment: .leading, spacing: unit * 0.05) {
                                    p.title(display.currentCueSnapshot?.title ?? "—", size: unit * 0.24)
                                    if let sp = display.currentCueSnapshot?.speakers, !sp.isEmpty { p.speakers(sp, size: unit * 0.14) }
                                }
                                .opacity(p.hasMessage ? 0 : 1)
                            }
                            rule(p)
                            cell("Next", h: unit * 1.0) {
                                p.secondary(display.nextCueSnapshot?.title ?? "End of show", size: unit * 0.18)
                            }
                            rule(p)
                            cell("Time", h: unit * 0.85) {
                                bigReadout(StageParts.clockFormatter.string(from: now), StageParts.meridiemFormatter.string(from: now),
                                           color: p.color(sch.textPrimary), size: unit * 0.34, p: p)
                            }
                            rule(p)
                            let sched = p.scheduleReadout(now)
                            cell(p.showOffset ? "Schedule" : "Ends", h: unit * 0.85) {
                                bigReadout(sched.value, sched.status ?? sched.unit, color: sched.color, size: unit * 0.34, p: p)
                            }
                        }
                        .padding(.horizontal, pad)
                        .frame(width: colW)
                    }
                    if p.hasMessage, let msg = display.message {
                        StageMessageBand(text: msg, height: H * 0.2, isMatte: isMatte)
                            .padding(.horizontal, pad).padding(.top, pad * 0.25)
                            .opacity(display.messageOpacity)
                    }
                }
            }
        }
    }

    private func cell<Content: View>(_ name: String, h: CGFloat, @ViewBuilder content: () -> Content) -> some View {
        let p = StageParts(display: display, isMatte: isMatte)
        return VStack(alignment: .leading, spacing: h * 0.05) {
            p.label(name, size: max(12, h * 0.1))
            content()
            Spacer(minLength: 0)
        }
        .padding(.vertical, h * 0.08)
        .frame(height: h, alignment: .top)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func rule(_ p: StageParts) -> some View {
        Rectangle().fill(p.color(p.scheme.progressHairline)).frame(height: 1)
    }

    private func bigReadout(_ value: String, _ unit: String, color: Color, size: CGFloat, p: StageParts) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: size * 0.15) {
            Text(value)
                .font(.system(size: size, weight: .semibold, design: .monospaced))
                .monospacedDigit().foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.4)
            if !unit.isEmpty { p.label(unit, size: size * 0.35) }
        }
    }
}

// MARK: - Clock + Timer

/// Time remaining and time of day at the same size, labelled, for a room that runs on the wall clock.
struct StageClockAndTimerLayout: View {
    @Environment(StageDisplayState.self) private var display
    var isMatte: Bool = false

    var body: some View {
        let p = StageParts(display: display, isMatte: isMatte)
        let sch = p.scheme
        GeometryReader { geo in
            let H = geo.size.height, W = geo.size.width
            let pad = max(16, W * 0.02)
            let titleH = H * 0.13, labelSize = max(13, H * 0.028)
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let now = ctx.date
                ZStack(alignment: .top) {
                    VStack(spacing: 0) {
                        HStack(spacing: pad) {
                            p.title(display.currentCueSnapshot?.title ?? "", size: titleH * 0.42).lineLimit(1)
                            Spacer(minLength: pad)
                            if let sp = display.currentCueSnapshot?.speakers, !sp.isEmpty { p.speakers(sp, size: titleH * 0.3) }
                        }
                        .frame(height: titleH)

                        row(label: "Remaining · " + p.stateWord, labelColor: p.stateColor, labelSize: labelSize) {
                            p.countdown
                        }
                        .background(display.colorState.backgroundColor(for: sch).opacity(isMatte ? 0 : 1))
                        .clipShape(RoundedRectangle(cornerRadius: 6))

                        p.progress(height: max(6, H * 0.012)).padding(.vertical, H * 0.015)

                        row(label: "Time of day", labelColor: p.color(sch.textTertiary), labelSize: labelSize) {
                            GeometryReader { g in
                                let text = StageParts.clockFormatter.string(from: now)
                                let size = min(g.size.width / CGFloat(max(text.count, 5)) * 1.8, g.size.height * 0.68)
                                HStack(alignment: .firstTextBaseline, spacing: size * 0.08) {
                                    Text(text)
                                        .font(.system(size: size, weight: sch.countdownWeight, design: sch.fontDesign))
                                        .monospacedDigit()
                                    Text(StageParts.meridiemFormatter.string(from: now))
                                        .font(.system(size: size * 0.22, weight: .heavy, design: .monospaced))
                                }
                                .foregroundStyle(p.color(sch.textPrimary))
                                .lineLimit(1).minimumScaleFactor(0.3)
                                .frame(width: g.size.width, height: g.size.height)
                            }
                        }
                        .frame(height: H * 0.34)

                        HStack(spacing: labelSize * 0.7) {
                            if let next = display.nextCueSnapshot?.title {
                                p.label("Next", size: labelSize)
                                p.secondary(next, size: labelSize * 1.5)
                            }
                            Spacer(minLength: 0)
                            if p.showOffset {
                                p.label(display.showOffsetDisplay + "  " + display.offsetStatus.label, size: labelSize, color: display.offsetStatus.color)
                            }
                        }
                        .frame(height: H * 0.07)
                    }
                    .padding(.horizontal, pad)

                    if p.hasMessage, let msg = display.message {
                        StageMessageBand(text: msg, height: H * 0.2, isMatte: isMatte)
                            .padding(pad)
                            .opacity(display.messageOpacity)
                    }
                }
            }
        }
    }

    private func row<Content: View>(label: String, labelColor: Color, labelSize: CGFloat, @ViewBuilder content: () -> Content) -> some View {
        let p = StageParts(display: display, isMatte: isMatte)
        return VStack(alignment: .leading, spacing: 0) {
            p.label(label, size: labelSize, color: labelColor)
                .padding(.leading, labelSize * 0.6)
                .padding(.top, labelSize * 0.4)
            content()
        }
    }
}

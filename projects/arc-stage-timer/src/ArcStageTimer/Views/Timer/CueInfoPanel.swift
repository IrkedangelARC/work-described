//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI

struct CueInfoPanel: View {
    let title: String?
    let subtitle: String?
    let speakers: String?
    let nextTitle: String?
    let nextSpeakers: String?
    var compact: Bool = false
    var stage: Bool = false
    var isMatte: Bool = false

    @Environment(\.displayColorScheme) private var scheme

    // Init from Cue objects (local controller mode)
    init(currentCue: Cue?, nextCue: Cue?, compact: Bool = false, stage: Bool = false, isMatte: Bool = false) {
        self.title = currentCue?.title
        self.subtitle = currentCue?.subtitle
        self.speakers = currentCue?.speakers
        self.nextTitle = nextCue?.title
        self.nextSpeakers = nextCue?.speakers
        self.compact = compact
        self.stage = stage
        self.isMatte = isMatte
    }

    // Init from CueSnapshot (remote display mode)
    init(snapshot: CueSnapshot?, nextSnapshot: CueSnapshot?, compact: Bool = false, stage: Bool = false, isMatte: Bool = false) {
        self.title = snapshot?.title
        self.subtitle = snapshot?.subtitle
        self.speakers = snapshot?.speakers
        self.nextTitle = nextSnapshot?.title
        self.nextSpeakers = nextSnapshot?.speakers
        self.compact = compact
        self.stage = stage
        self.isMatte = isMatte
    }

    // MARK: - Scheme-aware fonts (stage uses scheme design; control panel uses ARCTheme defaults)

    private var titleFont: Font {
        if stage {
            return .system(size: 115, weight: scheme.titleWeight, design: scheme.fontDesign)
        }
        return compact ? ARCTheme.cueTitleCompact : ARCTheme.cueTitle
    }

    private var subtitleFont: Font {
        if stage {
            return .system(size: 77, weight: scheme.subtitleWeight, design: scheme.fontDesign)
        }
        return compact ? ARCTheme.cueSubtitleCompact : ARCTheme.cueSubtitle
    }

    private var speakersFont: Font {
        if stage {
            return .system(size: 72, weight: scheme.speakersWeight, design: scheme.fontDesign)
        }
        return compact ? ARCTheme.cueSpeakersCompact : ARCTheme.cueSpeakers
    }

    /// The NEXT label is smaller than the next cue's name, so the name is what is read.
    private var nextLabelSize: CGFloat {
        if stage { return 34 }
        return compact ? 11 : 20
    }

    private var nextUpFont: Font {
        if stage {
            return .system(size: 58, weight: scheme.speakersWeight, design: scheme.fontDesign)
        }
        return compact ? ARCTheme.nextUpCompact : ARCTheme.nextUp
    }

    // MARK: - Text colors
    // Matte always white. Stage non-compact uses scheme colors (supports light backgrounds).
    // Compact stage (confidence overlays) and control panel use ARCTheme (always dark bg).

    private var useSchemeColors: Bool { stage && !compact && !isMatte }

    private var primaryColor: Color {
        if isMatte { return .white }
        if useSchemeColors { return scheme.textPrimary }
        return ARCTheme.textPrimary
    }

    private var secondaryColor: Color {
        if isMatte { return .white }
        if useSchemeColors { return scheme.textSecondary }
        return ARCTheme.textSecondary
    }

    private var tertiaryColor: Color {
        if isMatte { return .white }
        if useSchemeColors { return scheme.textTertiary }
        return ARCTheme.textTertiary
    }

    private var accentColor: Color {
        if isMatte { return .white }
        if useSchemeColors { return scheme.stageAccent }
        return ARCTheme.accent
    }

    private var isOutline: Bool { scheme.isOutlineText && !isMatte }
    private var outlineW: CGFloat { stage ? 3.0 : 2.0 }

    private var shadowColor: Color {
        (isMatte || isOutline) ? .clear : scheme.textShadowColor
    }

    /// In outline mode, fill = bg color (invisible), outline = original color
    private func fill(_ color: Color) -> Color {
        isOutline ? scheme.stageBackground : color
    }

    var body: some View {
        VStack(spacing: compact ? 6 : stage ? 14 : 10) {
            if let title {
                VStack(spacing: compact ? 4 : stage ? 12 : 8) {
                    Text(title)
                        .font(titleFont)
                        .foregroundStyle(fill(primaryColor))
                        .textOutline(color: isOutline ? primaryColor : .clear, width: isOutline ? outlineW : 0)
                        .shadow(color: shadowColor, radius: scheme.textShadowRadius, x: scheme.textShadowX, y: scheme.textShadowY)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.6)

                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(subtitleFont)
                            .foregroundStyle(fill(secondaryColor))
                            .textOutline(color: isOutline ? secondaryColor : .clear, width: isOutline ? outlineW : 0)
                            .shadow(color: shadowColor, radius: scheme.textShadowRadius, x: scheme.textShadowX, y: scheme.textShadowY)
                            .multilineTextAlignment(.center)
                            // A long subtitle shrank to 70 % and then ran off the panel and under the ARC badge (seen in the
                            // review, 2026-09-17). On the OPERATOR's screen it wraps; on the stage one line is still
                            // the rule, because a wrapped line there reads as two cues.
                            .lineLimit(stage ? 1 : 2)
                            // 0.7 left a real subtitle truncated on the stage ("...warning a..."): the words matter more than the size.
                            .minimumScaleFactor(stage ? 0.45 : 0.55)
                    }

                    if let speakers, !speakers.isEmpty {
                        Text(speakers)
                            .font(speakersFont)
                            .foregroundStyle(fill(accentColor))
                            .textOutline(color: isOutline ? accentColor : .clear, width: isOutline ? outlineW : 0)
                            .shadow(color: shadowColor, radius: scheme.textShadowRadius, x: scheme.textShadowX, y: scheme.textShadowY)
                            .multilineTextAlignment(.center)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                }
            } else {
                Text("No Cue Selected")
                    .font(titleFont)
                    .foregroundStyle(fill(tertiaryColor))
                    .textOutline(color: isOutline ? tertiaryColor : .clear, width: isOutline ? outlineW : 0)
                    .shadow(color: shadowColor, radius: scheme.textShadowRadius, x: scheme.textShadowX, y: scheme.textShadowY)
            }

            if let nextTitle {
                HStack(spacing: stage ? 14 : 8) {
                    // A mono caps LABEL, the console's language (ARC Style on the stage, 2026-09-17), not a
                    // word in the same face as the cue.
                    Text("NEXT")
                        .font(.system(size: nextLabelSize, weight: .heavy, design: .monospaced))
                        .tracking(nextLabelSize * 0.12)
                        .foregroundStyle(fill(tertiaryColor))
                        .baselineOffset(nextLabelSize * 0.12)
                    Text(nextTitle)
                        .font(nextUpFont)
                        .foregroundStyle(fill(secondaryColor))
                        .lineLimit(1)
                    if let nextSpeakers, !nextSpeakers.isEmpty {
                        Text("—")
                            .font(nextUpFont)
                            .foregroundStyle(fill(tertiaryColor))
                        Text(nextSpeakers)
                            .font(nextUpFont)
                            .foregroundStyle(fill(tertiaryColor))
                            .lineLimit(1)
                    }
                }
                .textOutline(color: isOutline ? secondaryColor : .clear, width: isOutline ? outlineW : 0)
                .shadow(color: shadowColor, radius: scheme.textShadowRadius, x: scheme.textShadowX, y: scheme.textShadowY)
                .minimumScaleFactor(0.6)
            }
        }
        .padding(.horizontal, ARCTheme.paddingMedium)
    }
}

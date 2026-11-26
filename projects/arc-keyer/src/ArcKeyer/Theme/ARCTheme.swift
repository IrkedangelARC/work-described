//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI
@_exported import ARCStyle

/// ARC Keyer's own tokens, on top of the ONE shared ARC Style (the `arc-style` package: ground, module chrome,
/// section tints, the monospace type rule). The app carried its own copy of every token and drifted: a
/// near-black ground, a cyan accent, #A61C1C for the ARC red, 12 pt corners. Those are gone; what is left
/// here is what is the Keyer's alone: the console geometry and the colour of each display role.
extension ARCTheme {
    // MARK: Console geometry (one given quantity, the window; fixed rails, flexible preview)
    static let leftRailWidth: CGFloat = 272     // DISPLAYS / TEST PATTERN / CAPTURE
    static let rightRailWidth: CGFloat = 320    // KEY / CAPTURE / OUTPUTS: "DeckLink Fill+Key (ATEM)" + START
    static let windowMin = CGSize(width: 1280, height: 760)
    /// One row of the footer: a label over a value. The CAPTURE key in the left rail is built to this same
    /// height, so the CAPTURE, STATUS and OUTPUTS bands sit on one line without measuring anything.
    static var readoutH: CGFloat { (legible(10) * 1.25 + legible(14) * 1.25 + 1).rounded() }

    // MARK: The three roles a display can have, as the ID overlay and the DISPLAYS rows colour them
    static let roleSource = secBlue
    static let roleKeyOutput = arcRed        // the key output IS the live feed
    static let roleControl = text2
}

// MARK: - Console parts shared by the rails and the footer (alignment from identical construction)

/// A label over a value: the footer's FPS / RES / FRAMES tiles and the CAPTURE module's RES.
struct ARCReadout: View {
    let label: String
    let value: String
    var tint: Color = ARCTheme.text0
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label.uppercased())
                .font(ARCTheme.mono(10, .heavy))
                .foregroundStyle(ARCTheme.text2)
                .tracking(1)
            Text(verbatim: value)
                .font(ARCTheme.mono(14, .bold))
                .foregroundStyle(tint)
                .lineLimit(1)
        }
        .frame(height: ARCTheme.readoutH, alignment: .top)
    }
}

/// The one big key a rail has (START / STOP CAPTURE): as tall as a readout row, as wide as its module,
/// filled in its tint when it is on. Not an ARCChip, which is sized by its word.
struct ARCKey: View {
    let title: String
    var tint: Color = ARCTheme.secCrimson
    var on: Bool = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title.uppercased())
                .font(ARCTheme.mono(13, .heavy))
                .tracking(1.4)
                .foregroundStyle(on ? ARCTheme.ink : ARCTheme.text0)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .frame(height: ARCTheme.readoutH)
                .background(on ? tint : ARCTheme.surfaceLight)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(on ? tint : ARCTheme.line, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
    }
}

/// A row inside a module: raised on the panel ground with a hairline, tinted when it carries a role.
struct ARCRow<Content: View>: View {
    var tint: Color = ARCTheme.line
    @ViewBuilder let content: () -> Content
    var body: some View {
        content()
            .padding(.horizontal, ARCTheme.modulePad)
            .padding(.vertical, ARCTheme.paddingSmall)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ARCTheme.panel)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(tint, lineWidth: 1))
    }
}

//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI

/// ARC PTZ console language (arc-ptz QuadTheme.kt), shared with ARC Presenter (2026-09-12): near-black
/// ink, dark panels with 1 px hairlines, grey module ground, ARC red as the
/// single accent, green only for "live/ready", yellow for warnings, small
/// radii, monospace bold labels. Same tokens, so the two consoles read as
/// one family on the fleet laptops.
enum ARCTheme {
    // MARK: Palette (PTZ tokens)
    static let ink        = Color(red: 0x0B/255, green: 0x0B/255, blue: 0x0C/255)   // app ground
    static let panel      = Color(red: 0x16/255, green: 0x17/255, blue: 0x19/255)   // PanelBg
    static let moduleBg   = Color(red: 0x10/255, green: 0x11/255, blue: 0x13/255)   // module interior
    static let appGrey    = Color(red: 0x38/255, green: 0x38/255, blue: 0x38/255)   // chrome grey (raised)
    static let line       = Color(red: 0x2C/255, green: 0x2E/255, blue: 0x31/255)   // hairline
    static let text0      = Color(red: 0xE8/255, green: 0xE8/255, blue: 0xEA/255)
    static let text1      = Color(red: 0x8B/255, green: 0x8D/255, blue: 0x92/255)
    static let text2      = Color(red: 0x5E/255, green: 0x60/255, blue: 0x66/255)
    static let arcRed     = Color(red: 0xC1/255, green: 0x27/255, blue: 0x2D/255)   // the logo red, brand/arc_brand.json (was AccentQ #C8102E to 2026-09-18)
    static let live       = Color(red: 0x2F/255, green: 0xBF/255, blue: 0x71/255)   // LiveQ
    static let warn       = Color(red: 0xE6/255, green: 0xC2/255, blue: 0x29/255)   // WarnYellow
    // Section tints (PTZ module language): each functional group gets a border colour.
    static let secOrange  = Color(red: 0xE0/255, green: 0x91/255, blue: 0x43/255)
    static let secBlue    = Color(red: 0x5B/255, green: 0x8D/255, blue: 0xD9/255)
    static let secGreen   = Color(red: 0x57/255, green: 0xB3/255, blue: 0x68/255)
    static let secCrimson = Color(red: 0xC2/255, green: 0x4B/255, blue: 0x5A/255)

    // MARK: Names the views already use (mapped onto the tokens above)
    static let background    = ink
    static let surface       = panel
    static let surfaceLight  = appGrey
    static let textPrimary   = text0
    static let textSecondary = text1
    static let textTertiary  = text2
    static let accent        = arcRed
    static let divider       = line
    static let liveRed       = arcRed
    static let readyGreen    = live
    static let warningYellow = warn

    // MARK: Typography: monospace, bold labels, same sizes as before
    static let slideCounter = Font.system(size: 43, weight: .bold, design: .monospaced)
    static let headerBar    = Font.system(size: 22, weight: .bold, design: .monospaced)
    static let jumpField    = Font.system(size: 29, weight: .medium, design: .monospaced)
    static let clock        = Font.system(size: 29, weight: .medium, design: .monospaced)
    static let bodyText     = Font.system(size: 17, weight: .regular, design: .monospaced)
    static let caption      = Font.system(size: 14, weight: .bold, design: .monospaced)
    static let statusBadge  = Font.system(size: 15, weight: .bold, design: .monospaced)
    static let moduleTitle  = Font.system(size: 11, weight: .bold, design: .monospaced)

    static let modulePad: CGFloat = 8
    static let paddingSmall: CGFloat = 8
    static let paddingMedium: CGFloat = 16
    static let paddingLarge: CGFloat = 24
    static let cornerRadius: CGFloat = 5
}

extension View {
    /// THE BRACKET (2026-09-18), the same construction as the ARCStyle package's `arcModule`:
    /// a filled title band inside the box, title LEFT-aligned in ink on the section colour, the border
    /// thickened to a 4 pt rule down the leading edge. Grab still carries its own theme copy; adopt the
    /// package at the next release and delete this.
    func arcModule(title: String? = nil, tint: Color = ARCTheme.line) -> some View {
        let band = tint == ARCTheme.line ? ARCTheme.text2 : tint
        let neutral = tint == ARCTheme.line
        return VStack(spacing: 0) {
            if let title {
                HStack(spacing: 0) {
                    Text(title.uppercased())
                        .font(.system(size: 13, weight: .heavy, design: .monospaced))
                        .foregroundStyle(neutral ? ARCTheme.text0 : ARCTheme.ink)
                        .tracking(1.4)
                        .lineLimit(1)
                        .padding(.leading, ARCTheme.modulePad)
                    Spacer(minLength: 6)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 22)
                .background(band)
            }
            self
                .padding(ARCTheme.modulePad)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(ARCTheme.moduleBg)
        .overlay(alignment: .leading) { Rectangle().fill(band).frame(width: 4) }
        .clipShape(RoundedRectangle(cornerRadius: ARCTheme.cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: ARCTheme.cornerRadius).strokeBorder(band, lineWidth: 1.5))
    }
}

/// Muted explanatory line inside a module.
struct ARCModuleCaption: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .regular, design: .monospaced))
            .foregroundStyle(ARCTheme.text2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI

/// ARC Style tokens (arc-ptz QuadTheme.kt). THE copy: every Swift ARC app imports this package (`import ARCStyle`,
/// or one `@_exported import ARCStyle` per app). Approved for any ARC project by 2026-09-17.
/// ink, dark panels with 1 px hairlines, grey module ground, ARC red as the
/// single accent, green only for "live/ready", yellow for warnings, small
/// radii, monospace bold labels. Same tokens, so the two consoles read as
/// one family on the fleet laptops.
public enum ARCTheme {
    // MARK: Palette (PTZ tokens)
    public static let ink        = Color(red: 0x0B/255, green: 0x0B/255, blue: 0x0C/255)   // app ground
    public static let panel      = Color(red: 0x16/255, green: 0x17/255, blue: 0x19/255)   // PanelBg
    public static let moduleBg   = Color(red: 0x10/255, green: 0x11/255, blue: 0x13/255)   // module interior
    public static let subGroup   = Color(red: 0x26/255, green: 0x28/255, blue: 0x2C/255)   // labelled group panel inside a module
    public static let appGrey    = Color(red: 0x38/255, green: 0x38/255, blue: 0x38/255)   // chrome grey (raised)
    public static let line       = Color(red: 0x2C/255, green: 0x2E/255, blue: 0x31/255)   // hairline
    public static let text0      = Color(red: 0xE8/255, green: 0xE8/255, blue: 0xEA/255)
    public static let text1      = Color(red: 0x8B/255, green: 0x8D/255, blue: 0x92/255)
    public static let text2      = Color(red: 0x5E/255, green: 0x60/255, blue: 0x66/255)
    public static let arcRed     = Color(red: 0xC1/255, green: 0x27/255, blue: 0x2D/255)   // the logo red, brand/arc_brand.json (was AccentQ #C8102E to 2026-09-18)
    public static let live       = Color(red: 0x2F/255, green: 0xBF/255, blue: 0x71/255)   // LiveQ
    public static let warn       = Color(red: 0xE6/255, green: 0xC2/255, blue: 0x29/255)   // WarnYellow
    // Section tints: signal-flow stages (2026-09-18; roles in brand/arc_brand.json screen._roles).
    // blue IN (sources, deck, next) . orange OPERATE (the operator's hands: run order, NOW, camera motion)
    // green MONITOR (readouts, results, never an action) . crimson OUT (outputs, program, key)
    // arcRed is the mark, LIVE and danger: never a section band. A section with no signal role takes `line` (neutral band).
    public static let secOrange  = Color(red: 0xE0/255, green: 0x91/255, blue: 0x43/255)
    public static let secBlue    = Color(red: 0x5B/255, green: 0x8D/255, blue: 0xD9/255)
    public static let secGreen   = Color(red: 0x57/255, green: 0xB3/255, blue: 0x68/255)
    public static let secCrimson = Color(red: 0xC2/255, green: 0x4B/255, blue: 0x5A/255)

    // MARK: Names the views already use (mapped onto the tokens above)
    // QUAD ground: the modules sit on chrome grey, not on ink (QuadAll.kt 249, 2026-09-12).
    public static let background    = appGrey
    public static let surface       = moduleBg     // header strips and bars, like QUAD's 28 pt ModuleBg rows
    public static let surfaceLight  = panel        // raised controls inside a module (QButton ground)
    public static let textPrimary   = text0
    public static let textSecondary = text1
    public static let textTertiary  = text2
    public static let accent        = arcRed
    public static let divider       = line
    public static let liveRed       = arcRed
    public static let readyGreen    = live

    // MARK: Typography: monospace, bold labels, same sizes as before
    public static let slideCounter = Font.system(size: 43, weight: .bold, design: .monospaced)
    public static let headerBar    = Font.system(size: 22, weight: .bold, design: .monospaced)
    public static let jumpField    = Font.system(size: 29, weight: .medium, design: .monospaced)
    public static let clock        = Font.system(size: 29, weight: .medium, design: .monospaced)
    public static let bodyText     = Font.system(size: 17, weight: .regular, design: .monospaced)
    public static let caption      = Font.system(size: 14, weight: .bold, design: .monospaced)
    public static let statusBadge  = Font.system(size: 15, weight: .bold, design: .monospaced)
    public static let moduleTitle  = Font.system(size: 11, weight: .bold, design: .monospaced)

    /// Console text, in ONE place (2026-09-17: "the text on the control is
    /// a bit small and hard to read"). Views pass the DESIGN size; small text is
    /// raised to a floor of 12 pt and stepped up, big readouts (18 pt and over)
    /// are left alone because their containers are measured for them. The
    /// operator's Console Text Size preference scales the small text further.
    public static func mono(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        .system(size: legible(size), weight: weight, design: .monospaced)
    }
    public static func legible(_ size: CGFloat) -> CGFloat { legible(size, scale: textScale) }
    public static func legible(_ size: CGFloat, scale: CGFloat) -> CGFloat {
        guard size < 18 else { return size }
        let stepped = size <= 13 ? size + 2 : size + 1
        return (max(12, stepped) * scale).rounded()
    }
    /// 1.0 standard, 1.15 large, 1.3 larger. Read once at launch.
    public static let textScale: CGFloat = {
        let v = UserDefaults.standard.double(forKey: "consoleTextScale")
        return v >= 0.9 && v <= 1.5 ? CGFloat(v) : 1.0
    }()
    /// Height of a module's header band: its title at the legible size plus breathing room.
    public static var moduleHeaderH: CGFloat { (legible(11) + 9).rounded() }
    /// Height a scaled module's chrome takes besides its content: the band and the padding above and below.
    public static func moduleChromeH(scale: CGFloat) -> CGFloat { (moduleHeaderH * scale).rounded() + 2 * modulePad * scale }

    public static let paddingSmall: CGFloat = 6    // QUAD gap and margin: 6 pt
    public static let modulePad: CGFloat = 8       // arcModule interior (was a constant in each app's layout file)
    public static let paddingMedium: CGFloat = 10
    public static let paddingLarge: CGFloat = 24
    public static let cornerRadius: CGFloat = 6    // QUAD modules: 6 pt
    // The bracket (2026-09-18): the rule down a module's leading edge, the gap before a band's cap,
    // the gap between a bank's segments and the radius on a bank's outer ends.
    public static let leftRule: CGFloat = 4
    public static let capGap: CGFloat = 2
    public static let bankGap: CGFloat = 2
    public static let bankRadius: CGFloat = 4
}

public extension View {
    /// THE BRACKET (2026-09-18: "this is it. apply to everything"). A module is a rounded box on the
    /// grey ground with a 1.5 pt border in its section colour, a filled title band inside the box, and the
    /// border THICKENED to a 4 pt rule down the leading edge, so band and rule read as one bracket, the way
    /// a drawing title block or a rack panel label does. The title is LEFT-aligned in the band; a `badge` is
    /// a square ink cap at the band's trailing end, split off by a 2 pt gap of module ground. No curve
    /// anywhere but ARC's own 6 pt corner.
    /// `hugging`: a footer group as wide as its controls. `scale`: 1 at arm's length; a stage-facing display
    /// passes more and band, title, cap, rule and padding grow together.
    /// `onBandDoubleTap`: a double-click on the title band alone, for a module that opens something
    /// bigger than itself (Presenter's TIMER band opens the cue stack, 2026-09-18). The body is untouched.
    func arcModule(title: String? = nil, tint: Color = ARCTheme.line, hugging: Bool = false, badge: ARCBandBadge? = nil, scale: CGFloat = 1, onBandDoubleTap: (() -> Void)? = nil) -> some View {
        let band = tint == ARCTheme.line ? ARCTheme.text2 : tint
        let neutral = tint == ARCTheme.line
        let r = ARCTheme.cornerRadius * min(scale, 2)
        return VStack(spacing: 0) {
            if let title {
                HStack(spacing: 0) {
                    Text(title.uppercased())
                        .font(.system(size: (ARCTheme.legible(11) * scale).rounded(), weight: .heavy, design: .monospaced))
                        .foregroundStyle(neutral ? ARCTheme.text0 : ARCTheme.ink)
                        .tracking(1.4 * scale)
                        .lineLimit(1)
                        .padding(.leading, ARCTheme.modulePad * scale)
                    Spacer(minLength: 6 * scale)
                    if let badge {
                        // The cap: square, ink, full band height, a 2 pt gap of module ground before it.
                        Rectangle().fill(ARCTheme.moduleBg).frame(width: ARCTheme.capGap * scale)
                        Text(badge.text)
                            .font(.system(size: (ARCTheme.legible(10) * scale).rounded(), weight: .heavy, design: .monospaced))
                            .foregroundStyle(badge.fill == ARCTheme.ink ? ARCTheme.text0 : ARCTheme.ink)
                            .lineLimit(1).fixedSize()
                            .padding(.horizontal, 8 * scale)
                            .frame(maxHeight: .infinity)
                            .background(badge.fill)
                    }
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { onBandDoubleTap?() }
                .frame(height: (ARCTheme.moduleHeaderH * scale).rounded())
                .background(band)
            }
            self
                .padding(ARCTheme.modulePad * scale)
                .frame(maxWidth: hugging ? nil : .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: hugging, vertical: false)
        .background(ARCTheme.moduleBg)
        // The rule: the border, thickened on the leading edge only.
        .overlay(alignment: .leading) { Rectangle().fill(band).frame(width: ARCTheme.leftRule * min(scale, 2)) }
        .clipShape(RoundedRectangle(cornerRadius: r))
        .overlay(RoundedRectangle(cornerRadius: r).strokeBorder(band, lineWidth: 1.5 * min(scale, 2)))
    }
}

/// A BANK: related controls as ONE bar, split by 2 pt of ground, flat 4 pt corners on the outer ends only
/// (the bracket's control grouping). Five loose chips read as five buttons; a bank reads as one instrument.
/// `on` fills a segment in the section's tint. Vertical banks stack, first/last rounded top/bottom.
public struct ARCBankItem: Identifiable {
    public let id: String
    public let title: String
    public let on: Bool
    public let enabled: Bool
    public let action: () -> Void
    public init(_ title: String, on: Bool = false, enabled: Bool = true, id: String? = nil, action: @escaping () -> Void) {
        self.id = id ?? title; self.title = title; self.on = on; self.enabled = enabled; self.action = action
    }
}

public struct ARCBank: View {
    private let items: [ARCBankItem]
    private let tint: Color
    private let vertical: Bool
    private let scale: CGFloat

    public init(_ items: [ARCBankItem], tint: Color = ARCTheme.secBlue, vertical: Bool = false, scale: CGFloat = 1) {
        self.items = items; self.tint = tint; self.vertical = vertical; self.scale = scale
    }

    public var body: some View {
        let gap = ARCTheme.bankGap * scale
        let layout = vertical ? AnyLayout(VStackLayout(spacing: gap)) : AnyLayout(HStackLayout(spacing: gap))
        layout {
            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                let first = i == 0, last = i == items.count - 1
                Button(action: item.action) {
                    Text(item.title.uppercased())
                        .font(.system(size: (ARCTheme.legible(11) * scale).rounded(), weight: .heavy, design: .monospaced))
                        .foregroundStyle(item.on ? ARCTheme.ink : (item.enabled ? ARCTheme.text0 : ARCTheme.text1))
                        .lineLimit(1)
                        .padding(.horizontal, 10 * scale).padding(.vertical, 6 * scale)
                        .frame(maxWidth: .infinity)
                        .background(item.on ? tint : ARCTheme.surfaceLight)
                        .clipShape(ARCBankShape(first: first, last: last, vertical: vertical, radius: ARCTheme.bankRadius * scale))
                }
                .buttonStyle(.plain)
                .disabled(!item.enabled)
            }
        }
    }
}

/// Flat inner edges, 4 pt corners only on the bank's outer ends.
public struct ARCBankShape: Shape {
    let first: Bool, last: Bool, vertical: Bool, radius: CGFloat
    public func path(in rect: CGRect) -> Path {
        var tl: CGFloat = 0, tr: CGFloat = 0, bl: CGFloat = 0, br: CGFloat = 0
        if vertical { if first { tl = radius; tr = radius }; if last { bl = radius; br = radius } }
        else { if first { tl = radius; bl = radius }; if last { tr = radius; br = radius } }
        return Path(roundedRect: rect, cornerRadii: RectangleCornerRadii(topLeading: tl, bottomLeading: bl, bottomTrailing: br, topTrailing: tr))
    }
}

/// A short state shown in a module's title band.
public struct ARCBandBadge {
    public let text: String
    public let fill: Color
    public init(text: String, fill: Color) { self.text = text; self.fill = fill }
}

/// Muted explanatory line inside a module.
public struct ARCModuleCaption: View {
    let text: String
    public init(_ text: String) { self.text = text }
    public var body: some View {
        Text(text)
            .font(ARCTheme.mono(12, .regular))
            .foregroundStyle(ARCTheme.text1)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A console button: rectangular, monospace, on the panel ground with a hairline border, and FILLED in a
/// section's colour when it is on. The PTZ and karaoke consoles' `chip`, which ARC Presenter, ARC Capture and
/// ARC Stage Timer had each re-invented (Stage Timer as cyan capsules, which is not the ARC language).
///
/// `on` is the one that matters: a control that is doing something reads as filled, everything else recedes.
/// Red is reserved for LIVE and for danger, so an ordinary selected control takes its section's tint.
public struct ARCChip<Label: View>: View {
    private let tint: Color
    private let on: Bool
    private let wide: Bool
    private let scale: CGFloat
    private let action: () -> Void
    private let label: Label

    public init(tint: Color = ARCTheme.secBlue, on: Bool = false, wide: Bool = false, scale: CGFloat = 1,
                action: @escaping () -> Void, @ViewBuilder label: () -> Label) {
        self.tint = tint; self.on = on; self.wide = wide; self.scale = scale; self.action = action; self.label = label()
    }

    public var body: some View {
        Button(action: action) {
            label
                .font(.system(size: (ARCTheme.legible(11) * scale).rounded(), weight: .heavy, design: .monospaced))
                .foregroundStyle(on ? ARCTheme.ink : ARCTheme.text0)
                .lineLimit(1)
                .padding(.horizontal, 10 * scale).padding(.vertical, 6 * scale)
                .frame(maxWidth: wide ? .infinity : nil)
                .background(on ? tint : ARCTheme.surfaceLight)
                .overlay(RoundedRectangle(cornerRadius: 4 * scale).strokeBorder(on ? tint : ARCTheme.line, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 4 * scale))
        }
        .buttonStyle(.plain)
    }
}

public extension ARCChip where Label == Text {
    /// The common case: a word. It never wraps and never shrinks to an ellipsis on its own.
    init(_ title: String, tint: Color = ARCTheme.secBlue, on: Bool = false, wide: Bool = false, scale: CGFloat = 1,
         action: @escaping () -> Void) {
        self.init(tint: tint, on: on, wide: wide, scale: scale, action: action) { Text(title.uppercased()) }
    }
}

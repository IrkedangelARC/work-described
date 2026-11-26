//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI

enum ARCTheme {
    // MARK: - Brand
    static let arcRed = Color(red: 0xC1/255, green: 0x27/255, blue: 0x2D/255)   // #C1272D, the logo red (arc-style/brand/arc_brand.json)

    // MARK: - UI Colors
    static let background = Color(red: 0.07, green: 0.07, blue: 0.08)
    static let surface = Color(red: 0.12, green: 0.12, blue: 0.14)
    static let surfaceLight = Color(red: 0.18, green: 0.18, blue: 0.20)
    static let textPrimary = Color.white
    static let textSecondary = Color(white: 0.6)
    static let textTertiary = Color(white: 0.4)
    static let accent = Color(red: 0.2, green: 0.851, blue: 0.961)
    static let divider = Color(white: 0.2)
    static let liveRed = Color(red: 1, green: 0.15, blue: 0.15)
    static let readyGreen = Color(red: 0, green: 0.78, blue: 0.33)
    static let offlineGray = Color(white: 0.35)

    // MARK: - Fonts
    static let headerBar = Font.system(size: 14, weight: .bold, design: .monospaced)
    static let bodyText = Font.system(size: 14)
    static let caption = Font.system(size: 12, weight: .medium)
    static let monoSmall = Font.system(size: 11, weight: .medium, design: .monospaced)

    // MARK: - Spacing
    static let paddingSmall: CGFloat = 8
    static let paddingMedium: CGFloat = 16
    static let paddingLarge: CGFloat = 24
    static let cornerRadius: CGFloat = 8
    static let sidebarWidth: CGFloat = 260
}

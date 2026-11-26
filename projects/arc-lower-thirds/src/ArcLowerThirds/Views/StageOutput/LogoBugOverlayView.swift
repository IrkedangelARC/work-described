//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI

/// Persistent corner image overlay (logo bug / watermark).
/// Positioned by bugCorner with configurable margins. Fades in/out on isOnAir.
/// Uses graphic.logoData for the image and graphic.logoSize for height.
struct LogoBugOverlayView: View {
    let graphic: Graphic
    let isOnAir: Bool
    var isMatte: Bool = false

    var body: some View {
        ZStack(alignment: graphic.bugCorner.alignment) {
            Color.clear  // Full-frame hit area for alignment

            bugContent
                .padding(.horizontal, graphic.bugMarginH)
                .padding(.vertical, graphic.bugMarginV)
        }
        .opacity(isOnAir ? 1 : 0)
        .animation(.easeInOut(duration: 0.4), value: isOnAir)
    }

    @ViewBuilder
    private var bugContent: some View {
        if let logoData = graphic.logoData, let nsImage = NSImage(data: logoData) {
            // Image bug
            if isMatte {
                Image(nsImage: nsImage).resizable().scaledToFit()
                    .frame(height: graphic.logoSize)
                    .colorMultiply(.white)
                    .blendMode(.normal)
            } else {
                Image(nsImage: nsImage).resizable().scaledToFit()
                    .frame(height: graphic.logoSize)
                    .shadow(color: .black.opacity(0.5), radius: 4, x: 0, y: 2)
            }
        } else {
            // Text-only bug (uses line1 as label)
            Text(graphic.line1)
                .font(graphic.fontForLine1())
                .foregroundStyle(isMatte ? .white : ARCTheme.color(from: graphic.accentColor))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: graphic.cornerRadius)
                        .fill(isMatte ? Color.white : graphic.resolvedTitleBgColor.opacity(graphic.backgroundOpacity))
                )
        }
    }
}

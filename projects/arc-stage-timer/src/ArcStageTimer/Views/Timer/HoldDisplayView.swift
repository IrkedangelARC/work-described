//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI

/// Intermission/hold screen with ARC logo and optional event name.
/// `stage: true` uses large sizing for external HDMI display.
struct HoldDisplayView: View {
    var eventName: String = ""
    var stage: Bool = false

    var body: some View {
        VStack(spacing: stage ? 40 : 20) {
            Spacer()
            Image("ARCLogo")
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: stage ? 400 : 200)
                .foregroundStyle(ARCTheme.arcRed)
            if !eventName.isEmpty {
                Text(eventName)
                    .font(.system(
                        size: stage ? 48 : 24,
                        weight: .medium
                    ))
                    .foregroundStyle(ARCTheme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }
}

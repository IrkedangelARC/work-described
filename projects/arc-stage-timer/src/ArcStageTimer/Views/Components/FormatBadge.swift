//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI

struct FormatBadge: View {
    let format: CueFormat

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: format.icon)
                .font(.system(size: 10))
            Text(format.label)
                .font(ARCTheme.caption)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(ARCTheme.surfaceLight)
        .foregroundStyle(ARCTheme.textSecondary)
        .clipShape(Capsule())
    }
}

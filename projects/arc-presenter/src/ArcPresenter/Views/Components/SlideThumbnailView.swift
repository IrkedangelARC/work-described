//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI

struct SlideThumbnailView: View {
    let image: NSImage?
    let pageNumber: Int

    var body: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ZStack {
                ARCTheme.surface
                VStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Slide \(pageNumber)")
                        .font(ARCTheme.caption)
                        .foregroundStyle(ARCTheme.textTertiary)
                }
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
        }
    }
}

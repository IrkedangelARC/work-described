//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI

struct SlidePreview: View {
    let engine: SlideEngine
    let cache: PageCache

    var body: some View {
        ZStack {
            Color.black
            if engine.isBlack {
                Text("BLACK")
                    .font(.system(size: 32, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
            } else if let img = cache.imageFor(page: engine.currentIndex) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else if engine.isLoaded {
                ProgressView(value: cache.progress)
                    .progressViewStyle(.linear)
                    .frame(width: 240)
                    .tint(.accentColor)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 48))
                        .foregroundStyle(.white.opacity(0.25))
                    Text("No deck loaded")
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }
}

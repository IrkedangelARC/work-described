//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI

struct NextSlidePreview: View {
    let engine: SlideEngine
    let cache: PageCache

    private var nextIndex: Int? {
        guard engine.isLoaded, engine.hasNext else { return nil }
        return engine.currentIndex + 1
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Text("NEXT")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55))
                if let n = nextIndex {
                    Text("\(n + 1) / \(engine.pageCount)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                }
                Spacer()
            }
            ZStack {
                Color.black
                if let n = nextIndex, let img = cache.imageFor(page: n) {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else if engine.isLoaded && engine.hasNext {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                        .tint(.white.opacity(0.4))
                } else {
                    Text(engine.isLoaded ? "END" : "—")
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.3))
                }
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .help("Preview of the slide that will appear when you advance")
    }
}

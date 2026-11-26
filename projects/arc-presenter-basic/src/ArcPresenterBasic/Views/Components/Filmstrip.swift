//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI

struct Filmstrip: View {
    let engine: SlideEngine
    let cache: PageCache

    private let thumbHeight: CGFloat = 72
    private let thumbSpacing: CGFloat = 6

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: true) {
                LazyHStack(spacing: thumbSpacing) {
                    ForEach(0..<engine.pageCount, id: \.self) { index in
                        thumb(index: index)
                            .id(index)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .frame(height: thumbHeight + 32)
            .background(Color.black.opacity(0.45))
            .onChange(of: engine.currentIndex) { _, newIndex in
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(newIndex, anchor: .center)
                }
            }
            .onAppear {
                if engine.isLoaded {
                    proxy.scrollTo(engine.currentIndex, anchor: .center)
                }
            }
            .onChange(of: engine.fileName) { _, _ in
                if engine.isLoaded {
                    DispatchQueue.main.async {
                        proxy.scrollTo(engine.currentIndex, anchor: .center)
                    }
                }
            }
        }
    }

    private func thumb(index: Int) -> some View {
        let isCurrent = index == engine.currentIndex
        let page = index + 1

        return Button {
            engine.jumpTo(page: page)
        } label: {
            VStack(spacing: 2) {
                Group {
                    if let image = cache.imageFor(page: index) {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } else {
                        Color.white.opacity(0.06)
                    }
                }
                .frame(width: thumbHeight * 16.0 / 9.0, height: thumbHeight)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(isCurrent ? Color.accentColor : Color.clear, lineWidth: 2)
                )

                Text("\(page)")
                    .font(.system(size: 11, weight: isCurrent ? .bold : .medium, design: .monospaced))
                    .foregroundStyle(isCurrent ? Color.accentColor : .white.opacity(0.6))
            }
        }
        .buttonStyle(.plain)
        .help("Jump to slide \(page)")
    }
}

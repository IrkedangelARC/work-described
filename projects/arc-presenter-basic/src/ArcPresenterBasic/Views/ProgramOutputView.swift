//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI

/// Renders the live deck on the program output. Reads pre-rendered images
/// from `liveCache` for instant page swaps — no PDFView animation, no scroll
/// transitions. Fast advances flip cleanly even at click-spam rate.
struct ProgramOutputView: View {
    @Environment(DeckSession.self) private var session

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if !session.liveEngine.isBlack,
               session.liveEngine.isLoaded,
               let img = session.liveCache.imageFor(page: session.liveEngine.currentIndex) {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .ignoresSafeArea()
            }
        }
        .ignoresSafeArea()
    }
}

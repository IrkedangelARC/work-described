//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI

/// The PLAIN program picture for Zoom to share (Engine/ShareOutput.swift):
/// ProgramOutputView's deck path, plus the captured external picture only when
/// it is not a Zoom window. While a Zoom participant is on program the deck
/// page stays up here, un-veiled, so the remote keeps the slides.
struct ShareOutputView: View {
    @Environment(SlideEngine.self) private var engine
    @Environment(SwitchEngine.self) private var switcher
    @Environment(WindowCapture.self) private var capture
    @Environment(WindowSource.self) private var windowSource
    @State private var pages = PageRenderCache()

    private var showsExternal: Bool {
        ShareOutput.showsExternal(switcher.external, windowBundleID: windowSource.pick?.bundleID)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if engine.isBlack {
                // Black output
            } else if engine.isArcDeck {
                if engine.isLoaded, let doc = engine.pdfDocument {
                    RenderedPageView(document: doc, pageIndex: engine.currentIndex, cache: pages)
                }
                if let still = engine.stateStill {
                    Image(nsImage: still).resizable().aspectRatio(contentMode: .fit)
                }
                AVPlayerRepresentable(player: engine.currentPlayer, nextPlayer: engine.nextPlayer)
                    .allowsHitTesting(false)
            } else if engine.currentPageIsVideo, let player = engine.currentPlayer {
                AVPlayerRepresentable(player: player)
                    .allowsHitTesting(false)
            } else if engine.isLoaded, let doc = engine.pdfDocument {
                RenderedPageView(document: doc, pageIndex: engine.currentIndex, cache: pages)
            }

            if showsExternal {
                Color.black
                    .opacity(switcher.veil)
                    .allowsHitTesting(false)
                MirroredCaptureView(capture: capture)
                    .opacity(switcher.reveal)
                    .allowsHitTesting(false)
            }
        }
        .ignoresSafeArea()
    }
}

/// A second view of the capture's frames (an NSView has one superview).
private struct MirroredCaptureView: NSViewRepresentable {
    let capture: WindowCapture
    func makeNSView(context: Context) -> CaptureLayerView { capture.makeMirror() }
    func updateNSView(_ view: CaptureLayerView, context: Context) {}
}

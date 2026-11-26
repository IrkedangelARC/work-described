//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI
import AVFoundation
import PDFKit

struct ProgramOutputView: View {
    @Environment(SlideEngine.self) private var engine
    @Environment(SwitchEngine.self) private var switcher
    @Environment(WindowCapture.self) private var capture
    @State private var pages = PageRenderCache()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if engine.isBlack {
                // Black output
            } else if engine.isArcDeck {
                // Page still underneath, ONE persistent player view on top for
                // the whole deck. The player view double-buffers clips and
                // paints no background, so a click shows the still or the
                // previous frame while the next clip readies, never black.
                if engine.isLoaded, let doc = engine.pdfDocument {
                    RenderedPageView(document: doc, pageIndex: engine.currentIndex, cache: pages)
                }
                // A build state (version 3) sits between the page and the clip.
                if let still = engine.stateStill {
                    Image(nsImage: still).resizable().aspectRatio(contentMode: .fit)
                }
                AVPlayerRepresentable(player: engine.currentPlayer, nextPlayer: engine.nextPlayer, logName: "PGM")
                    .allowsHitTesting(false)
            } else if engine.currentPageIsVideo, let player = engine.currentPlayer {
                AVPlayerRepresentable(player: player)
                    .allowsHitTesting(false)
            } else if engine.isLoaded, let doc = engine.pdfDocument {
                RenderedPageView(document: doc, pageIndex: engine.currentIndex, cache: pages)
            }

            // V4 switch: the deck fades to black under the veil, then either the
            // captured PowerPoint picture fades up here (composite, the window
            // stays opaque) or the window itself fades out (transparent).
            Color.black
                .opacity(switcher.veil)
                .allowsHitTesting(false)
            CapturedWindowView(capture: capture)
                .opacity(switcher.reveal)
                .allowsHitTesting(false)
        }
        .ignoresSafeArea()
    }
}

/// Hosts WindowCapture's layer view: the live PowerPoint picture.
private struct CapturedWindowView: NSViewRepresentable {
    let capture: WindowCapture
    func makeNSView(context: Context) -> CaptureLayerView { capture.view }
    func updateNSView(_ view: CaptureLayerView, context: Context) {}
}

// PDFPageView (PDFKit PDFView, synchronous draw per slide) was replaced by
// RenderedPageView + PageRenderCache (Engine/PageRenderer.swift) on 2026-09-16.

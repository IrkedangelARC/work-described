//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI

/// Done, in the PTZ console language: RESULT and OUTPUT modules, the captured
/// filmstrip with type badges, warnings, and two actions.
struct CaptureCompleteView: View {
    @Bindable var session: CaptureSession
    private let thumbH: CGFloat = 72

    var body: some View {
        VStack(spacing: 0) {
            CaptureHeader(screen: "DONE", subject: session.sourceFile?.deletingPathExtension().lastPathComponent, state: .complete,
                          stateDetail: session.report.map { String(format: "%.0f s", $0.wallSeconds) })
            ARCTheme.divider.frame(height: 1)
            VStack(spacing: ARCTheme.paddingSmall) {
                HStack(alignment: .top, spacing: ARCTheme.paddingSmall) {
                    VStack(alignment: .leading, spacing: 4) {
                        row("slides", "\(session.slideCount)" + (session.expectedTotalSlides > 0 ? " of \(session.expectedTotalSlides)" : ""))
                        row("images", "\(session.staticSlideCount)")
                        row("clips", "\(session.videoSlideCount)")
                        row("transitions", "\(session.slides.filter(\.transition).count)")
                        row("loops", "\(session.slides.filter(\.loop).count)")
                        row("wall time", session.report.map { String(format: "%.0f s", $0.wallSeconds) } ?? "—")
                    }
                    .frame(width: 300)
                    .arcModule(title: "RESULT", tint: ARCTheme.secGreen)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(session.outputURL?.path ?? "—").font(ARCTheme.mono(12, .regular)).foregroundStyle(ARCTheme.textPrimary)
                            .lineLimit(2).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                        let warns = session.report?.warnings ?? []
                        if warns.isEmpty {
                            Text("no warnings").font(ARCTheme.mono(11, .regular)).foregroundStyle(ARCTheme.textTertiary)
                        } else {
                            ForEach(Array(warns.prefix(5).enumerated()), id: \.offset) { _, w in
                                Text(w).font(ARCTheme.mono(11, .regular)).foregroundStyle(ARCTheme.warn).fixedSize(horizontal: false, vertical: true)
                            }
                            if warns.count > 5 { Text("+ \(warns.count - 5) more in the report").font(ARCTheme.mono(11, .regular)).foregroundStyle(ARCTheme.textTertiary) }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .arcModule(title: "OUTPUT", tint: ARCTheme.secCrimson,
                               badge: (session.report?.warnings.isEmpty ?? true) ? ARCBandBadge(text: "VERIFIED", fill: ARCTheme.readyGreen) : ARCBandBadge(text: "\(session.report?.warnings.count ?? 0) WARNINGS", fill: ARCTheme.warn))
                }
                .fixedSize(horizontal: false, vertical: true)
                ScrollView(.vertical) {
                    let cols = [GridItem(.adaptive(minimum: thumbH * 16 / 9, maximum: thumbH * 16 / 9), spacing: 6)]
                    LazyVGrid(columns: cols, spacing: 8) {
                        ForEach(session.slides) { s in
                            VStack(spacing: 2) {
                                Image(nsImage: s.thumbnail).resizable().aspectRatio(contentMode: .fit)
                                    .frame(width: thumbH * 16 / 9, height: thumbH)
                                    .clipShape(RoundedRectangle(cornerRadius: 3))
                                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(badgeColor(s), lineWidth: 1))
                                HStack(spacing: 4) {
                                    Text("\(s.pptxSlide ?? s.id)").font(ARCTheme.mono(11, .heavy)).foregroundStyle(ARCTheme.textSecondary)
                                    Text(badge(s)).font(ARCTheme.mono(9, .heavy)).foregroundStyle(badgeColor(s))
                                }
                            }
                        }
                    }
                    .padding(2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .arcModule(title: "CAPTURED", tint: ARCTheme.secCrimson, badge: ARCBandBadge(text: "\(session.slides.count) PAGES", fill: ARCTheme.ink))
            }
            .padding(.horizontal, ARCTheme.paddingMedium).padding(.vertical, ARCTheme.paddingSmall)
            .frame(maxHeight: .infinity)
            CaptureFooter {
                FooterRow {
                    ARCActionButton("OPEN IN PRESENTER", fill: ARCTheme.secGreen) { if let url = session.outputURL { openInPresenter(url) } }
                        .help("Load the deck into ARC Presenter as a new tab, not live")
                    ARCChip("REVEAL IN FINDER", tint: ARCTheme.secBlue) { if let url = session.outputURL { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
                    ARCActionButton("NEW CAPTURE") { session.reset() }
                }
                .arcModule(title: "ACTION", tint: ARCTheme.secOrange, hugging: true)
                Text("The deck is written next to the source file. OPEN IN PRESENTER loads it there as a new tab (not live); NEW CAPTURE starts over.")
                    .font(ARCTheme.mono(11, .regular)).foregroundStyle(ARCTheme.textSecondary).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .arcModule(title: "WHAT NEXT", tint: ARCTheme.line)
            }
        }
        .frame(minWidth: 720, minHeight: 460)
        .background(ARCTheme.background)
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack { Text(k.uppercased()).font(ARCTheme.mono(11, .heavy)).foregroundStyle(ARCTheme.textSecondary); Spacer(); Text(v).font(ARCTheme.mono(13, .heavy)).foregroundStyle(ARCTheme.textPrimary).monospacedDigit() }
    }
    private func badge(_ s: CaptureResult) -> String { s.loop ? "LOOP" : (s.transition ? "TRN" : (s.isVideo ? "VID" : "IMG")) }
    private func badgeColor(_ s: CaptureResult) -> Color { s.loop ? ARCTheme.warn : (s.transition ? ARCTheme.arcRed : (s.isVideo ? ARCTheme.secCrimson : ARCTheme.line)) }
}

private func openInPresenter(_ deck: URL) {
    // Presenter running: its control API; otherwise launch it with the deck.
    var req = URLRequest(url: URL(string: "http://localhost:8760/open?path=" + (deck.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? deck.path))!)
    req.httpMethod = "POST"; req.timeoutInterval = 20
    URLSession.shared.dataTask(with: req) { _, resp, err in
        if err != nil || (resp as? HTTPURLResponse)?.statusCode != 200 {
            DispatchQueue.main.async {
                if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.example.arc.ArcPresenter") {
                    NSWorkspace.shared.open([deck], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
                }
            }
        }
    }.resume()
}

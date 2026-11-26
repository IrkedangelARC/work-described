//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI

struct FilmstripView: View {
    @Environment(SlideEngine.self) private var engine
    @Environment(PageCache.self) private var cache
    @Environment(DeckManager.self) private var deckManager

    private let thumbHeight: CGFloat = 60   // 90 until 2026-09-23: the strip's height is the picture's
    private let thumbSpacing: CGFloat = 6

    /// Grab bar state: which page the strip is centred on (0-based).
    @State private var barPage: Double = 0
    @State private var dragging = false
    /// The thumbnail under the pointer: its contents read out in the title row, at once (the system tooltip takes over a second).
    @State private var hovered: Int?

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                titleRow
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: thumbSpacing) {
                        ForEach(0..<engine.pageCount, id: \.self) { index in
                            filmstripThumbnail(index: index)
                                .id(index)
                        }
                    }
                    .padding(.horizontal, ARCTheme.paddingSmall)
                }
                .frame(height: thumbHeight + 20)
                // A NEW scroll view per preview deck. Switching from a long deck to a short one left the
                // old content offset (page 47 of 367 is ~7,800 pt in) pointing past the end of the new
                // content, the lazy stack had nothing in view and drew nothing, and a scrollTo into the
                // shorter content did not clamp it (reproduced on the office workstation 2026-09-17, both with and
                // without the re-anchor below). A fresh identity starts at offset 0 and onAppear anchors.
                .id(deckManager.previewDeckID)
                // Grab bar: a mouse without side scroll cannot move the strip
                // (2026-09-12). Dragging the thumb scrolls the strip to
                // the matching page; the thumb follows the live page otherwise.
                grabBar(proxy: proxy)
            }
            .background(ARCTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: ARCTheme.cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: ARCTheme.cornerRadius).strokeBorder(ARCTheme.text2, lineWidth: 1.5))
            .padding(.horizontal, ARCTheme.paddingSmall).padding(.vertical, 3)   // a module ON the ground, like the rail's
            .onChange(of: engine.currentIndex) { _, newIndex in
                guard !dragging else { return }
                barPage = Double(newIndex)
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(newIndex, anchor: .center)
                }
            }
            .onAppear {
                barPage = Double(engine.currentIndex)
                proxy.scrollTo(engine.currentIndex, anchor: .center)
            }
            // The strip came up EMPTY on a cold launch with a deck (2026-09-17: "there is no
            // filmstrip"): the session restore and the opened deck arrive after this view's first
            // appearance, the pages change under a lazy stack that had anchored itself with nothing to
            // show, and it drew nothing until a page change scrolled it. Re-anchor whenever the pages or
            // the deck change, one turn later so the new pages are laid out.
            .onChange(of: engine.pageCount) { _, _ in
                DispatchQueue.main.async { proxy.scrollTo(engine.currentIndex, anchor: .center) }
            }
            .onChange(of: deckManager.previewDeckID) { _, _ in
                barPage = Double(engine.currentIndex)
                DispatchQueue.main.async { proxy.scrollTo(engine.currentIndex, anchor: .center) }
            }
        }
    }

    /// "FILMSTRIP", or what the hovered slide holds. One fixed-height row, so
    /// nothing moves and nothing floats over a live console.
    private var titleRow: some View {
        Group {
            if let i = hovered, let deck = deckManager.liveDeck {
                (Text("SLIDE \(i + 1)").font(ARCTheme.mono(12, .heavy)) + Text("   " + deck.slideInfo(page: i).joined(separator: "   \u{00B7}   ")).font(ARCTheme.mono(12, .bold)))
                    .foregroundStyle(ARCTheme.text0)
            } else {
                Text("FILMSTRIP").font(ARCTheme.mono(11, .heavy)).tracking(1.4).foregroundStyle(ARCTheme.text0)
            }
        }
        .lineLimit(1).truncationMode(.tail)
        .padding(.horizontal, ARCTheme.paddingSmall)
        .frame(maxWidth: .infinity).frame(height: ARCTheme.moduleHeaderH)
        .background(ARCTheme.text2)   // the neutral section band, as arcModule draws it
    }

    private func grabBar(proxy: ScrollViewProxy) -> some View {
        GeometryReader { geo in
            let pages = max(1, engine.pageCount)
            let trackW = geo.size.width - 2 * ARCTheme.paddingSmall
            // Thumb width mirrors the visible share of the strip, never under 44 pt.
            let thumbW = max(44, min(trackW, trackW * min(1, geo.size.width / (CGFloat(pages) * (thumbHeight * 16 / 9 + thumbSpacing)))))
            let travel = max(1, trackW - thumbW)
            let frac = pages > 1 ? CGFloat(barPage) / CGFloat(pages - 1) : 0
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).fill(ARCTheme.moduleBg).frame(height: 8)
                RoundedRectangle(cornerRadius: 3)
                    .fill(dragging ? ARCTheme.arcRed : ARCTheme.appGrey)
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(ARCTheme.line, lineWidth: 1))
                    .frame(width: thumbW, height: 10)
                    .offset(x: frac * travel)
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            dragging = true
                            let f = min(1, max(0, (g.location.x - thumbW / 2) / travel))
                            let page = Int((f * CGFloat(pages - 1)).rounded())
                            if page != Int(barPage) {
                                barPage = Double(page)
                                proxy.scrollTo(page, anchor: .center)
                            }
                        }
                        .onEnded { _ in dragging = false })
            }
            .padding(.horizontal, ARCTheme.paddingSmall)
        }
        .frame(height: 14)
        .padding(.bottom, 2)
    }

    private func filmstripThumbnail(index: Int) -> some View {
        let isCurrent = index == engine.currentIndex
        let page = index + 1
        let cue = deckManager.liveDeck?.cueFor(page: page)
        let isTransition = deckManager.liveDeck?.isTransitionAt(page: index) ?? false
        let firing = deckManager.liveFiring
        let firingEntry = firing.page == index && firing.entry
        let firingPage = firing.page == index && !firing.entry

        return HStack(spacing: thumbSpacing) {
            if isTransition {
                // A transition clip is not a slide of its own: a thin ARC-red
                // separator marks "the way in" between the two thumbnails
                // (2026-09-12).
                // Drawn as a thin outlined box, not a hairline, so it reads
                // at a glance ("more prominent thin boxes", 2026-09-12).
                ZStack {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(ARCTheme.arcRed.opacity(0.22))
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(firingEntry ? ARCTheme.readyGreen : ARCTheme.arcRed, lineWidth: firingEntry ? 3 : 2)
                    Text("TRN")
                        .font(ARCTheme.mono(9, .bold))
                        .foregroundStyle(ARCTheme.arcRed)
                        .rotationEffect(.degrees(-90))
                        .fixedSize()
                }
                .frame(width: 16, height: thumbHeight)
                .padding(.bottom, 16)
                .help("Slide \(page) enters with a transition clip")
            }
            thumbnailButton(index: index, page: page, isCurrent: isCurrent, firing: firingPage, cue: cue)
        }
    }

    private func thumbnailButton(index: Int, page: Int, isCurrent: Bool, firing: Bool, cue: TimerCue?) -> some View {
        Button {
            engine.jumpTo(page: page)
        } label: {
            VStack(spacing: 2) {
                Group {
                    // A slide with builds shows FINISHED here: its page in slides.pdf is the bare slide it opens as.
                    if let image = deckManager.liveDeck?.finishedImage(page: index) ?? cache.imageFor(page: index) {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } else {
                        ARCTheme.surfaceLight
                    }
                }
                .frame(width: thumbHeight * 16.0 / 9.0, height: thumbHeight)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .overlay(alignment: .topTrailing) { buildBadge(index: index) }
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        // Green = firing on the program output now; red = the
                        // current page (its entry clip may be what is firing).
                        .strokeBorder(firing ? ARCTheme.readyGreen : (isCurrent ? ARCTheme.accent : Color.clear), lineWidth: firing ? 3 : 2)
                )

                HStack(spacing: 3) {
                    if cue != nil {
                        Image(systemName: "bell.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(cue?.action == .stop ? ARCTheme.liveRed : ARCTheme.accent)
                    }
                    Text("\(page)")
                        .font(.system(size: 12, weight: isCurrent ? .bold : .medium, design: .monospaced))
                        .foregroundStyle(isCurrent ? ARCTheme.accent : ARCTheme.textSecondary)
                    buildPips(index: index)
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { hovered = index } else if hovered == index { hovered = nil }
        }
        .help("Jump to slide \(page)\n" + (deckManager.liveDeck?.slideInfo(page: index) ?? []).joined(separator: "\n"))
    }

    // MARK: Builds in the timeline (2026-09-17: "there should be a
    // distinction in the timeline to identify these slides that have builds")

    /// How many builds a page has, and how many have played (live page only;
    /// a page left part-built remembers it).
    private func builds(index: Int) -> (count: Int, done: Int) {
        guard let deck = deckManager.liveDeck, deck.isArcDeck else { return (0, 0) }
        let k = deck.timelineBuildCount(page: index)
        guard k > 0 else { return (0, 0) }
        if deck.buildCount(page: index) > 0 { return (k, min(deck.buildStates[index] ?? 0, k)) }
        // A continuous-clip deck: the marks it has walked on the live page.
        return (k, index == deckManager.liveEngine.currentIndex ? min(max(0, deckManager.liveSegment - deck.ownClickCount(page: index)), k) : 0)
    }

    /// "10 B" on the thumbnail: this slide stops for clicks before it moves on.
    @ViewBuilder private func buildBadge(index: Int) -> some View {
        let b = builds(index: index)
        if deckManager.liveDeck?.isLogoPage(index) == true {
            Text("LOGO")
                .font(ARCTheme.mono(9, .heavy))
                .foregroundStyle(ARCTheme.textPrimary)
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 2).fill(ARCTheme.appGrey))
                .padding(3)
        } else if b.count > 0 {
            Text("\(b.count) B")
                .font(ARCTheme.mono(9, .heavy))
                .foregroundStyle(ARCTheme.ink)
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 2).fill(ARCTheme.warn))
                .padding(3)
                .help("\(b.count) build\(b.count == 1 ? "" : "s"): each click plays one and waits; back undoes one")
        }
    }

    /// One pip per build, filled as they play and emptied by a back-step. Past
    /// eight they would not fit under a thumbnail: a count instead.
    @ViewBuilder private func buildPips(index: Int) -> some View {
        let b = builds(index: index)
        if b.count > 0 {
            let live = index == deckManager.liveEngine.currentIndex
            if b.count <= 8 {
                HStack(spacing: 2) {
                    ForEach(0..<b.count, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(i < b.done ? (live ? ARCTheme.readyGreen : ARCTheme.warn) : ARCTheme.line)
                            .frame(width: 6, height: 6)
                    }
                }
            } else {
                Text("\(b.done)/\(b.count)")
                    .font(ARCTheme.mono(10, .bold))
                    .foregroundStyle(b.done > 0 ? (live ? ARCTheme.readyGreen : ARCTheme.warn) : ARCTheme.textSecondary)
            }
        }
    }
}

//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI
import AVFoundation
import PDFKit

/// The presenter's monitor on stage, in ARC Style (2026-09-17 rework: a dedicated
/// notes area with font size adjustments, and the rest of the elements brought
/// into the ARC design theme).
///
/// Four modules on the grey ground, placed by ConfidenceLayout.solve in one of
/// two layouts the operator picks (MONITOR section, menu, POST /monitor/layout).
/// SLIDES: CURRENT at the slide's exact aspect with the TIMER as a strip under
/// it, NEXT at the same aspect with NOTES, tall, under it (PowerPoint's
/// Presenter View put notes there, so presenters look there). NOTES: CURRENT,
/// NEXT and TIMER in a short row on top, the notes the full width under it.
/// NOTES is always there, so nothing jumps when a slide has none. The chrome is
/// the console's (`arcModule`), scaled for a display read from metres away.
struct ConfidenceMonitorView: View {
    @State private var pages = PageRenderCache()
    @Environment(SlideEngine.self) private var engine          // the LIVE engine
    @Environment(PageCache.self) private var cache
    @Environment(TimerEngine.self) private var timer
    @Environment(MessageEngine.self) private var messages
    @Environment(CueTimer.self) private var cue
    @Environment(UserPreferences.self) private var prefs
    @Environment(DeckManager.self) private var deckManager

    /// The divider being dragged tracks from where the drag started.
    @State private var dragStart: Double?
    /// Measured in the view, at the paged size: the whole note, one line, two lines.
    @State private var notesHeight: CGFloat = 0
    @State private var oneLineH: CGFloat = 0
    @State private var twoLinesH: CGFloat = 0

    var body: some View {
        ZStack {
            ARCTheme.background.ignoresSafeArea()
            GeometryReader { geo in
                // Read through the version so a Preferences edit, a key or a drag re-lays the monitor out at once.
                let _ = prefs.confidenceLayoutVersion
                let L = prefs.solveConfidenceLayout(size: geo.size, aspect: slideAspect)
                // A module that is off has a zero frame: it is not placed at all.
                ZStack(alignment: .topLeading) {
                    place(currentModule(L), L.current)
                    if L.shows(.next) { place(nextModule(L), L.next) }
                    if L.shows(.timer) { place(timerModule(L), L.timer) }
                    if L.shows(.notes) { place(notesModule(L), L.notes) }
                    ForEach(L.grips, id: \.quantity) { g in place(grip(g, L), g.rect) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(L.gap)

                // The message lives in the TIMER strip (2026-09-19); only a monitor without one floats it.
                if messages.isShowingMessage, !L.shows(.timer) { messageOverlay(L) }
            }
        }
        .ignoresSafeArea()
    }

    /// The live page's aspect (a 4:3 deck gets a 4:3 box); 16:9 before a deck is up.
    private var slideAspect: Double {
        guard let b = engine.pdfDocument?.page(at: engine.currentIndex)?.bounds(for: .mediaBox), b.height > 0 else { return 16.0 / 9.0 }
        return Double(b.width / b.height)
    }

    private func place<V: View>(_ view: V, _ r: CGRect) -> some View {
        view.frame(width: r.width, height: r.height).offset(x: r.minX, y: r.minY)
    }

    /// The gaps are the grab areas: between the columns it trades slide size for notes (SLIDES), under the
    /// row it trades thumbnails for text (NOTES); under CURRENT and under NEXT it sizes the timer and the
    /// notes themselves (2026-09-19). A drag starts from the value the solution shows, AUTO or not.
    private func grip(_ g: ConfidenceLayout.Grip, _ L: ConfidenceLayout.Frames) -> some View {
        Rectangle().fill(Color.clear).contentShape(Rectangle())
            .onHover { inside in if inside { (g.sideways ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push() } else { NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    if dragStart == nil { dragStart = L.value(of: g.quantity) }
                    guard let start = dragStart, L.content.width > 0, L.content.height > 0 else { return }
                    // The slide's share is of the width less the gap; the others of the content box. Notes grow upward: the boundary moves the other way.
                    let sign: Double = g.quantity == .notes ? -1 : 1
                    let delta = g.sideways ? Double(value.translation.width / (g.quantity == .slide ? L.content.width - L.gap : L.content.width))
                                           : Double(value.translation.height / L.content.height)
                    // The timer grows when its boundary moves UP (under the slide) or LEFT (beside the thumbnails): minus both ways.
                    let timerSign: Double = g.quantity == .timer ? -1 : 1
                    prefs.dragQuantity(g.quantity, start + sign * timerSign * delta)
                }
                .onEnded { _ in dragStart = nil })
    }

    private func mono(_ size: CGFloat, _ L: ConfidenceLayout.Frames, _ weight: Font.Weight = .bold) -> Font {
        .system(size: (size * L.scale).rounded(), weight: weight, design: .monospaced)
    }

    // MARK: - CURRENT

    private func currentModule(_ L: ConfidenceLayout.Frames) -> some View {
        let builds = deckManager.liveBuildCount, build = deckManager.liveBuild
        // A thumbnail's band is narrow: the short form.
        let short = L.mode == .notes && L.current.width < 520 * L.scale
        var text = engine.isLoaded ? (short ? "\(engine.currentPage)/\(engine.pageCount)" : "SLIDE \(engine.currentPage) / \(engine.pageCount)") : "NO DECK"
        if builds > 0 { text += short ? "  B \(build)/\(builds)" : "    BUILD \(build) / \(builds)" }
        let badge = ARCBandBadge(text: engine.isBlack ? "BLACK" : text,
                                 fill: engine.isBlack ? ARCTheme.arcRed : (builds > 0 && build < builds ? ARCTheme.warn : ARCTheme.text0))
        return ZStack {
            Color.black
            if engine.isBlack {
                VStack(spacing: 12 * L.scale) {
                    Image(systemName: "rectangle.slash").font(.system(size: 60 * L.scale))
                    Text("BLACK").font(mono(40, L, .heavy))
                }
                .foregroundStyle(ARCTheme.liveRed)
            } else if engine.isLoaded {
                if let doc = engine.pdfDocument { RenderedPageView(document: doc, pageIndex: engine.currentIndex, cache: pages) }
                // The build state the room is looking at, then the clip over it: what the program output draws.
                if let still = engine.stateStill { Image(nsImage: still).resizable().aspectRatio(contentMode: .fit) }
                if engine.currentPageIsVideo, let player = engine.currentPlayer {
                    AVPlayerRepresentable(player: player, nextPlayer: engine.nextPlayer).allowsHitTesting(false)
                }
            }
        }
        // Time left, only for MEDIA: a transition or a build is a clip too, and it read "-0:00 PAUSED" on every such slide.
        .overlay(alignment: .topTrailing) {
            if !engine.isBlack, deckManager.liveDeck?.hasMedia(page: engine.currentIndex) == true, let player = engine.currentPlayer {
                VideoRemainingView(player: player).scaleEffect(min(L.scale, 1.6), anchor: .topTrailing).padding(8 * L.scale)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // "CURRENT" and its badge collide in a thumbnail's band: NOW / NEXT, as a rundown says it.
        .arcModule(title: short ? "Now" : "Current", tint: ARCTheme.secCrimson, badge: badge, scale: L.scale)
    }

    // MARK: - NEXT (the next CLICK: a build of this slide, or the next slide)

    private func nextModule(_ L: ConfidenceLayout.Frames) -> some View {
        let deck = deckManager.liveDeck
        let builds = deckManager.liveBuildCount, build = deckManager.liveBuild
        let nextBuild: NSImage? = (engine.isArcDeck && build < builds) ? deck?.stateImage(page: engine.currentIndex, state: build + 1) : nil
        // The next SLIDE as it will first appear: its state 0 when it has builds, else its page.
        let nextPage = engine.currentIndex + 1
        let nextSlide: NSImage? = engine.hasNext ? ((deck?.buildCount(page: nextPage) ?? 0) > 0 ? deck?.stateImage(page: nextPage, state: 0) : nil) ?? cache.imageFor(page: nextPage) : nil
        var label = "END OF DECK"
        if engine.isBlack { label = "BLACK" }
        else if nextBuild != nil { label = "BUILD \(build + 1) / \(builds)" }
        else if engine.hasNext { label = deck?.isLogoPage(nextPage) == true ? "LOGO" : "SLIDE \(engine.currentPage + 1)" }
        return ZStack {
            Color.black
            if engine.isBlack {
                Text("BLACK").font(mono(22, L, .heavy)).foregroundStyle(ARCTheme.liveRed)
            } else if let image = nextBuild ?? nextSlide {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                Text(engine.isLoaded ? "END OF DECK" : "").font(mono(18, L)).foregroundStyle(ARCTheme.text1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .arcModule(title: "Next", tint: ARCTheme.secBlue, badge: ARCBandBadge(text: label, fill: nextBuild != nil ? ARCTheme.warn : ARCTheme.text0), scale: L.scale)
    }

    // MARK: - NOTES (dedicated: always there, sized by the presenter, never scrolled by them)

    private func notesText(_ note: String, _ size: Double) -> some View {
        Text(note)
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(ARCTheme.text0)
            .lineSpacing((size * 0.12).rounded())
            .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// Notes too long even at the smallest size: PAGES, turned by the operator
    /// (Cmd Shift Down / Up, POST /notes/page). Never a scroll view: the
    /// presenter cannot scroll a stage monitor, and text cut off with nothing
    /// to say so is a trap (3.03 slide 3: 1,706 characters, 2026-09-17).
    private func pagedNotes(_ note: String, size: Double, _ L: ConfidenceLayout.Frames) -> some View {
        GeometryReader { geo in
            // The line advance is MEASURED in this view, from an invisible one-line
            // and two-line text in the same font: an estimate, and then AppKit's
            // line height, both left half a line at the bottom of page 1 and the
            // top of page 2. Whole lines only; the page marker has a strip of its
            // own; one line is kept from the page before so the eye finds its place.
            let first = max(1, oneLineH), advance = max(1, twoLinesH - oneLineH)
            let markerH = (16 * L.scale).rounded()
            let visible = max(1, floor((geo.size.height - markerH - first) / advance) + 1)
            let shownH = first + (visible - 1) * advance
            let perPage = max(1, visible - 1) * advance
            let pages = max(1, Int(ceil(max(1, notesHeight - first) / perPage)))
            let page = min(max(0, deckManager.notesPage), pages - 1)
            VStack(spacing: 0) {
                notesText(note, size)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(GeometryReader { g in Color.clear.preference(key: NotesHeightKey.self, value: g.size.height) })
                    .offset(y: -CGFloat(page) * perPage)
                    .frame(width: geo.size.width, height: shownH, alignment: .topLeading)
                    .clipped()
                Spacer(minLength: 0)
                Text("PAGE \(page + 1) / \(pages)" + (page + 1 < pages ? "  \u{25BC}" : ""))
                    .font(mono(10, L, .heavy)).foregroundStyle(ARCTheme.ink)
                    .padding(.horizontal, 7 * L.scale)
                    .frame(height: markerH)
                    .background(RoundedRectangle(cornerRadius: 3 * L.scale).fill(ARCTheme.warn))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .onPreferenceChange(NotesHeightKey.self) { notesHeight = $0 }
            .background(alignment: .topLeading) {
                ZStack {
                    notesText("Xg", size).fixedSize().background(GeometryReader { g in Color.clear.preference(key: OneLineKey.self, value: g.size.height) })
                    notesText("Xg\nXg", size).fixedSize().background(GeometryReader { g in Color.clear.preference(key: TwoLinesKey.self, value: g.size.height) })
                }
                .hidden()
                .onPreferenceChange(OneLineKey.self) { oneLineH = $0 }
                .onPreferenceChange(TwoLinesKey.self) { twoLinesH = $0 }
            }
        }
    }

    private func notesModule(_ L: ConfidenceLayout.Frames) -> some View {
        let chosen = prefs.confidenceNotesFontSize
        let sizes = ConfidenceLayout.notesFitSizes(chosen: chosen)
        return Group {
            if let note = engine.currentNote, !engine.isBlack {
                // Largest size that fits the area; only a note too long even at the smallest scrolls.
                ViewThatFits(in: .vertical) {
                    notesText(note, sizes[0]); notesText(note, sizes[1]); notesText(note, sizes[2]); notesText(note, sizes[3]); notesText(note, sizes[4])
                    pagedNotes(note, size: sizes[4], L)
                }
            } else {
                Text(engine.isLoaded ? "NO NOTES FOR THIS SLIDE" : "").font(mono(14, L)).foregroundStyle(ARCTheme.text2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .arcModule(title: "Notes", tint: ARCTheme.line, scale: L.scale)   // STRUCTURE: notes have no signal role, neutral band
        // A- 36 PT A+ in the band: the operator sets it from here, the menu (Cmd Shift - / =) or POST /notes/font.
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 4 * L.scale) {
                notesSizeButton("A\u{2212}", L) { prefs.stepNotesFont(-1) }
                Text("\(Int(chosen)) PT").font(mono(10, L, .heavy)).foregroundStyle(ARCTheme.ink).frame(minWidth: 44 * L.scale)
                notesSizeButton("A+", L) { prefs.stepNotesFont(1) }
            }
            .frame(height: (ARCTheme.moduleHeaderH * L.scale).rounded())
            .padding(.trailing, 6 * L.scale)
        }
    }

    private func notesSizeButton(_ label: String, _ L: ConfidenceLayout.Frames, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(mono(10, L, .heavy)).foregroundStyle(ARCTheme.text0)
                .padding(.horizontal, 7 * L.scale).padding(.vertical, 1 * L.scale)
                .background(RoundedRectangle(cornerRadius: 3 * L.scale).fill(ARCTheme.ink))
        }
        .buttonStyle(.plain)
    }

    // MARK: - TIMER (with the time of day in its band)

    /// A wide, short strip: what the digits mean on the left, the digits, the logo on the
    /// right. The readouts the operator turned on use the strip's negative space, not the
    /// label's column (2026-09-19): NOW runs the full width along the top, NEXT /
    /// ENDS / ELAPSED sit in a row along the bottom, and the digits are sized to what is
    /// left between them. A message from the booth takes the left column on ARC red, the
    /// band goes red, the digits give way.
    private func timerModule(_ L: ConfidenceLayout.Frames) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            GeometryReader { geo in
                let message = messages.isShowingMessage
                let lines = ConfidenceLayout.timerLines(info: prefs.confidenceTimerInfo, cueTitle: cue.now?.title, cueSpeakers: cue.now?.speakers,
                                                        nextTitle: cue.next?.title, endsAt: timer.endsAt, elapsed: timer.elapsedString,
                                                        countingDown: timer.mode == .countDown, now: context.date)
                // The titles run the width, one per row; the two short readouts sit under the label, where the column has room.
                let top = lines.filter { $0.label == "NOW" }, bottom = lines.filter { $0.label == "NEXT" }
                let under = lines.filter { $0.label == "ENDS" || $0.label == "ELAPSED" }
                // Each row that is present takes a share of the height; the digits get the rest.
                let rowH = (geo.size.height * 0.20).rounded()
                let middleH = geo.size.height - rowH * CGFloat((top.isEmpty ? 0 : 1) + (bottom.isEmpty ? 0 : 1))
                let digits = min(middleH * 0.92, geo.size.width * (message ? 0.13 : 0.17))
                // The label column widens for the tiles under it (ELAPSED wrapped and "8:5…" truncated at 22 %).
                let leftW = geo.size.width * (message ? 0.42 : (under.isEmpty ? 0.22 : 0.30))
                VStack(spacing: 0) {
                    if !top.isEmpty { readoutRow(top, rowH: rowH, L) }
                    HStack(spacing: 16 * L.scale) {
                        if message {
                            Text(messages.currentMessage)
                                .font(.system(size: digits * 0.55, weight: .heavy, design: .monospaced))
                                .foregroundStyle(.white)
                                .multilineTextAlignment(.leading)
                                .minimumScaleFactor(0.4)
                                .lineLimit(3)
                                .padding(.horizontal, 12 * L.scale).padding(.vertical, 6 * L.scale)
                                .frame(width: leftW, height: middleH - 8 * L.scale, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 4 * L.scale).fill(ARCTheme.arcRed))
                        } else {
                            VStack(alignment: .leading, spacing: 6 * L.scale) {
                                Text(timer.isOvertime ? "OVER" : (timer.mode == .countUp ? "ELAPSED" : "REMAINING"))   // a state, not a tally (2026-09-18)
                                    .font(.system(size: max(digits * 0.2, 12 * L.scale), weight: .heavy, design: .monospaced))
                                    .foregroundStyle(timer.isOvertime ? ARCTheme.liveRed : ARCTheme.text1)
                                ForEach(Array(under.enumerated()), id: \.offset) { _, line in
                                    readout(line, label: max(digits * 0.12, 10 * L.scale), value: max(digits * 0.18, 12 * L.scale), L)
                                        .frame(width: leftW, alignment: .leading)
                                }
                            }
                            .frame(width: leftW, alignment: .leading)
                        }
                        Text(timer.displayString)
                            .font(.system(size: digits, weight: .bold, design: .monospaced))
                            .foregroundStyle(timer.isOvertime ? ARCTheme.liveRed : ARCTheme.text0)
                            .lineLimit(1).minimumScaleFactor(0.5)
                            .frame(maxWidth: .infinity)
                        if prefs.confidenceTimerLogo {
                            Group {
                                if let logo = prefs.customLogoImage { Image(nsImage: logo).resizable().aspectRatio(contentMode: .fit) }
                                // The stock logo is red on its own black box; screened, the box takes the module's ground.
                                else { Image("ARCLogo").resizable().aspectRatio(contentMode: .fit).blendMode(.screen) }
                            }
                            .frame(width: geo.size.width * (message ? 0.16 : 0.22), height: middleH, alignment: .trailing)
                            .allowsHitTesting(false)
                        }
                    }
                    .frame(width: geo.size.width, height: middleH)
                    if !bottom.isEmpty { readoutRow(bottom, rowH: rowH, L) }
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .arcModule(title: messages.isShowingMessage ? "Message from the booth" : "Timer",
                       tint: messages.isShowingMessage || timer.isOvertime ? ARCTheme.arcRed : ARCTheme.secGreen,
                       badge: prefs.confidenceTimerClock ? ARCBandBadge(text: context.date.formatted(date: .omitted, time: .shortened), fill: ARCTheme.text0) : nil, scale: L.scale)
        }
    }

    /// One row across the strip: a title's tile, the width of the strip. Three readouts in one row
    /// filled it and NEXT truncated after two words (2026-09-19); so one title per row.
    private func readoutRow(_ lines: [(label: String, value: String)], rowH: CGFloat, _ L: ConfidenceLayout.Frames) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                readout(line, label: (rowH * 0.32).rounded(), value: (rowH * 0.46).rounded(), L)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(height: rowH, alignment: .center)
    }

    /// LABEL value in a subtle box (2026-09-19: boxes give the elements
    /// some separation and clarity). The label sits in a column as wide as the widest label and the
    /// digits are monospaced, so nothing moves as the seconds tick (before, all of the bottom text moved as
    /// the numbers changed).
    private func readout(_ line: (label: String, value: String), label: CGFloat, value: CGFloat, _ L: ConfidenceLayout.Frames) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10 * L.scale) {
            Text(line.label).font(.system(size: label, weight: .heavy, design: .monospaced)).foregroundStyle(ARCTheme.text2)
                .lineLimit(1).fixedSize()
                .frame(width: (label * 0.74 * 7).rounded(), alignment: .leading)   // seven cells of heavy mono (0.74 em each, measured: 0.62 wrapped it): "ELAPSED", the widest
            Text(line.value).font(.system(size: value, weight: .bold)).monospacedDigit().foregroundStyle(ARCTheme.text0)
                .lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10 * L.scale).padding(.vertical, 4 * L.scale)
        .background(RoundedRectangle(cornerRadius: 4 * L.scale).fill(ARCTheme.panel))
        .overlay(RoundedRectangle(cornerRadius: 4 * L.scale).strokeBorder(ARCTheme.line, lineWidth: 1))
    }

    // MARK: - Message from the booth (floating: only when the TIMER strip is off the monitor)

    private func messageOverlay(_ L: ConfidenceLayout.Frames) -> some View {
        VStack {
            Spacer()
            Text(messages.currentMessage)
                .font(mono(44, L, .heavy))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.4)
                .lineLimit(3)
                .padding(.horizontal, 32 * L.scale).padding(.vertical, 16 * L.scale)
                .frame(maxWidth: .infinity)
                .arcModule(title: "Message from the booth", tint: ARCTheme.arcRed, scale: L.scale)
                .padding(.horizontal, L.gap)
            Spacer().frame(height: 80 * L.scale)
        }
    }
}

private struct OneLineKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
private struct TwoLinesKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
private struct NotesHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

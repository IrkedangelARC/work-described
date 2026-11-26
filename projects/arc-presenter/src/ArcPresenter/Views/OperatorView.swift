//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI
import ARCShowFormat
import AVFoundation
import UniformTypeIdentifiers

struct OperatorView: View {
    @Environment(SlideEngine.self) private var engine
    @Environment(PageCache.self) private var cache
    @Environment(DisplayManager.self) private var displayManager
    @Environment(RecentFiles.self) private var recentFiles
    @Environment(TimerEngine.self) private var timer
    @Environment(MessageEngine.self) private var messages
    @Environment(DeckManager.self) private var deckManager
    @Environment(UserPreferences.self) private var prefs
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    private static let videoTypes: [UTType] = [.movie, .mpeg4Movie, .quickTimeMovie, .avi]
    private static let arcdeckType = UTType("com.example.arc.arcdeck") ?? .folder
    private static let allDropTypes: [UTType] = [.pdf, .movie, .mpeg4Movie, .quickTimeMovie, .avi, .folder, .zip, .fileURL]

    @State private var showKeyboardHelp = false
    @State private var headerW: CGFloat = 2000
    @State private var isDragOver = false

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                // The header keeps its own height. Without this, on macOS 27.2 the header's two row
                // OUTPUTS layout (a Grid, chosen under about 1580 pt of window) made the whole console
                // report a small maximum height: the window showed it as a band across the middle, no
                // picture, the rail cut off (found 2026-11-25, 5.5.4 and 5.6.1 alike).
                headerBar
                    .fixedSize(horizontal: false, vertical: true)

                ARCTheme.divider.frame(height: 1)

                // Fixed rail, flexible picture (ARC layout law, 2026-09-12). The operator layout of
                // 2026-09-23: OUTPUTS and STATUS in the header, ONE control row under the picture
                // column, and the rail from the header to the window's bottom, so NEXT, TIMER, MESSAGE and
                // MUSIC fit unscrolled on a 1512x945 MacBook Pro.
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        banners   // over the picture only
                        currentSlidePanel
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        ARCTheme.divider.frame(height: 1)
                        FilmstripView()   // draws its own title row: it becomes the hovered slide's readout
                        ARCTheme.divider.frame(height: 1)
                        footerBar
                    }

                    ARCTheme.divider
                        .frame(width: 1)

                    nextSlidePanel
                        .frame(width: ARCTheme.railW)
                }
            }

            if showKeyboardHelp {
                KeyboardHelpOverlay(isVisible: $showKeyboardHelp)
            }

            windowRoutes
        }
        .background(ARCTheme.background)
        .overlay(
            RoundedRectangle(cornerRadius: ARCTheme.cornerRadius)
                .strokeBorder(isDragOver ? ARCTheme.accent : Color.clear, lineWidth: 3)
                .padding(4)
                .allowsHitTesting(false)
        )
        .onDrop(of: Self.allDropTypes, isTargeted: $isDragOver) { providers in
            handleDrop(providers)
        }
        .navigationTitle("\(engine.fileName) \u{2014} Slide \(engine.displayLabel)")
        .onReceive(NotificationCenter.default.publisher(for: .openProgramOutput)) { _ in
            openOutput(.program)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openConfidenceMonitor)) { _ in
            openOutput(.confidence)
        }
        // .openProgramWindowOnly and .openOutputWindow are answered by ContentView (present on the load screen too).
        .onReceive(NotificationCenter.default.publisher(for: .openAllOutputs)) { _ in
            openAllOutputs()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openPDFFile)) { notification in
            if let url = notification.object as? URL {
                loadFile(url: url)
            } else {
                openFileDialog()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleKeyboardHelp)) { _ in
            showKeyboardHelp.toggle()
        }
        .onChange(of: engine.currentIndex) { _, _ in
            deckManager.syncNavigationToLiveIfNeeded()
        }
        .onChange(of: engine.isBlack) { _, _ in
            deckManager.syncNavigationToLiveIfNeeded()
        }
    }

    /// PREVIEW, the display manager's warning, and a deck's load error or progress: over the picture column.
    @ViewBuilder
    private var banners: some View {
        if deckManager.isPreviewingOffline {
            HStack(spacing: 8) {
                Circle()
                    .fill(ARCTheme.accent)
                    .frame(width: 10, height: 10)
                Text("PREVIEW")
                    .font(ARCTheme.mono(16, .heavy))
                    .foregroundStyle(ARCTheme.accent)
                Text("Navigating offline. Press TAKE to push to live output.")
                    .font(ARCTheme.caption)
                    .foregroundStyle(ARCTheme.textPrimary)
                Spacer()
                Text("LIVE: \(deckManager.liveDeckName)")
                    .font(ARCTheme.mono(16, .bold))
                    .foregroundStyle(ARCTheme.liveRed)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(ARCTheme.accent.opacity(0.1))
        }

        if let message = displayManager.statusMessage {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text(message)
                    .font(ARCTheme.caption)
                    .foregroundStyle(ARCTheme.textPrimary)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 12)
            .background(ARCTheme.surfaceLight)
        }

        if let errorDeck = deckManager.decks.first(where: { $0.loadError != nil }) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(.red)
                Text(errorDeck.loadError ?? "Unknown error")
                    .font(ARCTheme.mono(16, .medium))
                    .foregroundStyle(.red)
                Spacer()
                Button("Dismiss") {
                    errorDeck.loadError = nil
                }
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(ARCTheme.textSecondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.red.opacity(0.1))
        } else if let loadingDeck = deckManager.decks.first(where: { $0.isLoading }) {
            VStack(spacing: 4) {
                HStack {
                    Image(systemName: "doc.text.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(ARCTheme.accent)
                    Text("Loading \(loadingDeck.fileName)")
                        .font(ARCTheme.mono(16, .medium))
                        .foregroundStyle(ARCTheme.textPrimary)
                        .lineLimit(1)
                    Spacer()
                    Text("\(Int(loadingDeck.progress * Double(loadingDeck.pageCount))) of \(loadingDeck.pageCount) slides")
                        .font(ARCTheme.mono(16, .bold))
                        .foregroundStyle(ARCTheme.accent)
                    Text("(\(Int(loadingDeck.progress * 100))%)")
                        .font(ARCTheme.mono(16, .medium))
                        .foregroundStyle(ARCTheme.textSecondary)
                }
                ProgressView(value: loadingDeck.progress)
                    .tint(ARCTheme.accent)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(ARCTheme.surface)
        }
    }

    /// The control windows behind the expand glyphs and the menu, opened (or toggled) by notification.
    /// A view of its own: on the operator view's chain they pushed the type checker past its limit.
    private var windowRoutes: some View {
        Color.clear.frame(width: 0, height: 0)
            .onReceive(NotificationCenter.default.publisher(for: .openSourcesWindow)) { _ in
            openWindow(id: "sources")
        }
            .onReceive(NotificationCenter.default.publisher(for: .openRundownWindow)) { _ in
            openWindow(id: "rundown")   // the band double-click and the menu: open, never close
        }
        // The menu items and their keys toggle like the glyphs do (2026-09-19: a second click closes).
            .onReceive(NotificationCenter.default.publisher(for: .openMonitorLayoutPanel)) { _ in
            ControlWindow.toggle(id: "monitor-layout", title: "Monitor Layout", open: openWindow, dismiss: dismissWindow)
        }
            .onReceive(NotificationCenter.default.publisher(for: .openMessageWindow)) { _ in
            ControlWindow.toggle(id: "message", title: "Message to Presenter", open: openWindow, dismiss: dismissWindow)
        }
            .onReceive(NotificationCenter.default.publisher(for: .openMusicWindow)) { _ in
            ControlWindow.toggle(id: "music", title: "Music", open: openWindow, dismiss: dismissWindow)
        }
            .onReceive(NotificationCenter.default.publisher(for: .openStatusWindow)) { _ in
            ControlWindow.toggle(id: "status", title: "Status", open: openWindow, dismiss: dismissWindow)
        }
    }

    // MARK: - Header

    /// Logo, deck tabs, OUTPUTS, STATUS, clock. Short of width, the tabs give way first (they scroll,
    /// down to one tab's width), then the clock steps down; the output chips go two by two before any
    /// chip would narrow past its label. Outputs are never dropped.
    private var headerBar: some View {
        HStack(spacing: 10) {
            Image("ARCLogo")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: 36)

            DeckTabStripView()

            headerGroup(tint: ARCTheme.secGreen) {
                OutputAssignmentView()
                ARCExpandButton(tip: "Sources: program output, the parked PowerPoint, any app's window (OPEN / TAKE / RETURN); click again to close", on: ControlWindow.isOpen(title: "Sources"), band: true) {
                    ControlWindow.toggle(id: "sources", title: "Sources", open: openWindow, dismiss: dismissWindow)
                }
            }

            headerGroup(tint: ARCTheme.secOrange) {
                HealthStripView()
                ARCExpandButton(tip: "Status window: every check with its line, the last error and what it means, the log (Cmd+Opt+Shift+H); click again to close", on: ControlWindow.isOpen(title: "Status"), band: true) {
                    ControlWindow.toggle(id: "status", title: "Status", open: openWindow, dismiss: dismissWindow)
                }
            }
            .fixedSize()

            // No layoutPriority anywhere in this row: with priorities on OUTPUTS and the clock the window grew
            // itself past any width it was given (1512 came back 1672; the "w=1512 left ~1919" report).
            // The clock steps down by the header's own width, not by a ViewThatFits: offered an even share
            // of the row it kept its full size and the deck tabs had ~180 pt for three tabs (2026-09-23).
            ClockView(compact: headerW < ARCTheme.fullClockHeaderW)
                .help("Current system time")
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { headerW = $0 }
        .padding(.horizontal, ARCTheme.paddingMedium)
        .padding(.vertical, 6)
        .background(ARCTheme.surface)
    }

    /// A header section: a hairline box with its colour on the leading rule, like a module without a band.
    private func headerGroup<Content: View>(tint: Color, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 6) { content() }
            .padding(.leading, ARCTheme.leftRule + 6)
            .padding(.trailing, 4)
            .padding(.vertical, 4)
            .background(ARCTheme.moduleBg)
            .overlay(alignment: .leading) { Rectangle().fill(tint).frame(width: ARCTheme.leftRule) }
            .overlay(RoundedRectangle(cornerRadius: ARCTheme.cornerRadius).strokeBorder(ARCTheme.line, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: ARCTheme.cornerRadius))
    }

    // MARK: - Slide Panels

    /// The page in this pane holds a movie, a sound or an animated image. A
    /// page whose clip is only its way in, or a build slide, does not: they
    /// got a VIDEO transport and a "-0:04 PAUSED" badge, and lost their NEXT
    /// thumbnail to it (2026-09-17).
    private var pageHoldsMedia: Bool {
        engine.currentPageIsVideo && (deckManager.previewDeck?.hasMedia(page: engine.currentIndex) ?? false)
    }

    /// This pane is the live page of the live deck, and that page has builds.
    private var mirrorsLiveBuilds: Bool {
        deckManager.previewDeckID == deckManager.liveDeckID && deckManager.liveBuildCount > 0
            && engine.currentIndex == deckManager.liveEngine.currentIndex
    }

    private var currentSlidePanel: some View {
        ZStack {
            ARCTheme.background

            if mirrorsLiveBuilds {
                // The LIVE page has builds and is the page in this pane: show
                // what the room sees (the state, and the build clip over it),
                // not this page's own clip parked at frame 0, which is the way
                // in and so a picture of the PREVIOUS slide (seen 2026-09-17).
                ZStack {
                    if let still = deckManager.liveEngine.stateStill {
                        Image(nsImage: still).resizable().aspectRatio(contentMode: .fit)
                    } else {
                        SlideThumbnailView(image: cache.imageFor(page: engine.currentIndex), pageNumber: engine.currentPage)
                    }
                    if let player = deckManager.liveEngine.currentPlayer {
                        AVPlayerRepresentable(player: player).allowsHitTesting(false)
                    }
                }
                .padding(ARCTheme.paddingSmall)
            } else if engine.currentPageIsVideo, let player = engine.currentPlayer {
                AVPlayerRepresentable(player: player, nextPlayer: engine.nextPlayer)
                    .padding(ARCTheme.paddingSmall)
            } else if let still = engine.stateStill {
                // The build state this page stands in (what a TAKE would show).
                Image(nsImage: still).resizable().aspectRatio(contentMode: .fit).padding(ARCTheme.paddingSmall)
            } else {
                SlideThumbnailView(
                    image: cache.imageFor(page: engine.currentIndex),
                    pageNumber: engine.currentPage
                )
                .padding(ARCTheme.paddingSmall)
            }

            if engine.isBlack {
                Color.black.opacity(0.85)
                VStack(spacing: 8) {
                    Image(systemName: "rectangle.slash")
                        .font(.system(size: 58))
                    Text("BLACK")
                        .font(ARCTheme.mono(38, .heavy))
                }
                .foregroundStyle(ARCTheme.liveRed)
            }
        }
        // Large time-remaining countdown, glanceable on the control surface.
        .overlay(alignment: .topTrailing) {
            if pageHoldsMedia, let player = engine.currentPlayer, !engine.isBlack {
                VideoRemainingView(player: player)
                    .padding(ARCTheme.paddingMedium)
            }
        }
    }

    private var nextSlidePanel: some View {
        // The rail's modules no longer set the window's MINIMUM height: on a
        // display shorter than the stack (Innoview 2048x1152 with MUSIC added,
        // 2026-09-12) the window grew past the screen and the footer was cut
        // off. Now the window can be sized to the screen and the rail scrolls.
        // Tools keep their geometry, the picture flexes: NEXT shrinks (16:9,
        // centred) when the display is short; only if even that cannot fit
        // does the rail scroll. ViewThatFits tests the IDEAL size, so NEXT's
        // ideal is its minimum (it grows to fill in the real layout); with the
        // ideal at 270 a 1080-high display fell into the scroll, where NEXT
        // never shrinks and the last module was clipped (2026-09-16).
        ViewThatFits(in: .vertical) {
            railModules
            ScrollView(.vertical) { railModules }
                .scrollIndicators(.hidden)
        }
        .frame(width: ARCTheme.railW)
        .background(ARCTheme.background)
    }

    private var railModules: some View {
        VStack(spacing: 6) {
            if pageHoldsMedia, let player = engine.currentPlayer,
               let deck = deckManager.previewDeck {
                // Video transport + audio controls: full-video decks AND
                // arcdeck slides that carry a clip. Keyed on the slide index so
                // arcdeck per-slide players rebind (meter/volume re-attach).
                VStack(spacing: 4) {
                    VideoTransportView(player: player, deck: deck)
                        .id(engine.currentIndex)
                }
                .arcModule(title: "VIDEO", tint: ARCTheme.secCrimson)
            } else {
                VStack(spacing: 4) {
                    if engine.hasNext {
                        SlideThumbnailView(
                            image: cache.imageFor(page: engine.currentIndex + 1),
                            pageNumber: engine.currentPage + 1
                        )
                        .frame(maxWidth: ARCTheme.nextThumbW, maxHeight: ARCTheme.nextThumbH)
                        .frame(maxWidth: .infinity, minHeight: ARCTheme.nextThumbMinH, idealHeight: ARCTheme.nextThumbMinH)
                    } else {
                        ZStack {
                            ARCTheme.panel   // not the window ground: the module vanished into it
                            Text("END OF DECK — no further slides")
                                .font(ARCTheme.caption)
                                .foregroundStyle(ARCTheme.textSecondary)
                        }
                        .aspectRatio(16.0 / 9.0, contentMode: .fit)
                        .frame(maxWidth: ARCTheme.nextThumbW, maxHeight: ARCTheme.nextThumbH)
                        .frame(maxWidth: .infinity, minHeight: ARCTheme.nextThumbMinH, idealHeight: ARCTheme.nextThumbMinH)
                    }
                }
                .frame(maxHeight: .infinity)
                .arcModule(title: "NEXT", tint: ARCTheme.secBlue)
            }

            TimerControlView()
                // Double-click the TIMER band for the cue stack (2026-09-18); the band's button too (2026-09-19).
                .arcModule(title: "TIMER", tint: ARCTheme.secGreen,
                           onBandDoubleTap: { NotificationCenter.default.post(name: .openRundownWindow, object: nil) })
                .arcExpandButton("Rundown: the cue stack (or double-click the band); click again to close", on: ControlWindow.isOpen(title: "Rundown")) {
                    ControlWindow.toggle(id: "rundown", title: "Rundown", open: openWindow, dismiss: dismissWindow)
                }

            MessageControlView()
                .arcModule(title: "MESSAGE TO PRESENTER", tint: ARCTheme.secOrange)
                .arcExpandButton("Message window: compose, and the six presets (Cmd+Opt+Shift+M); click again to close", on: ControlWindow.isOpen(title: "Message to Presenter")) {
                    ControlWindow.toggle(id: "message", title: "Message to Presenter", open: openWindow, dismiss: dismissWindow)
                }

            // Walk-in / walk-out / background music from another app, through
            // a process tap (2026-09-12). Sits in the rail's negative space.
            MusicControlView()
                .arcModule(title: "MUSIC", tint: ARCTheme.secBlue)
                .arcExpandButton("Music window: sources, sound files, the chime, output and timing (Cmd+Opt+Shift+A); click again to close", on: ControlWindow.isOpen(title: "Music")) {
                    ControlWindow.toggle(id: "music", title: "Music", open: openWindow, dismiss: dismissWindow)
                }

        }
        .padding(ARCTheme.railPad)
    }

    // MARK: - Footer

    /// ONE control row under the picture column (2026-09-23): NAVIGATE, PROGRAM, MONITOR. When the column
    /// is too narrow, MONITOR's text size and notes paging fold into a menu (TAKE, BLACK and the arrows
    /// never do); below the design floor (~1300 pt windows) the row splits in two.
    private var footerBar: some View {
        ViewThatFits(in: .horizontal) {
            footerRow { navigateGroup; programGroup; monitorGroup(compact: false) }
            footerRow { navigateGroup; programGroup; monitorGroup(compact: true) }
            VStack(spacing: ARCTheme.paddingSmall) {
                footerRow { navigateGroup; programGroup }
                footerRow { monitorGroup(compact: true) }
            }
        }
        .padding(.horizontal, ARCTheme.paddingSmall)
        .padding(.vertical, ARCTheme.paddingSmall)
        .background(ARCTheme.surface)
    }

    private func footerRow<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 8) {
            content()
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)   // one row, whatever is in it
    }

    // Sections (2026-09-16: "natural grouping and separate sections
    // of buttons"): NAVIGATE, PROGRAM, OUTPUTS, MONITOR, STATUS.
    private var navigateGroup: some View {
        footerGroup("NAVIGATE", tint: ARCTheme.secBlue, badge: buildBadge) {
            navButton(icon: "backward.end.fill", tip: "First slide (Cmd+Left)") { engine.goToFirst() }
            navButton(icon: "chevron.left", tip: "Previous slide (Left arrow)") { engine.previous() }

            Text(engine.displayLabel)
                .font(ARCTheme.footerCounter)
                .foregroundStyle(ARCTheme.textPrimary)
                .monospacedDigit()
                .lineLimit(1)
                .frame(width: ARCTheme.counterWidth(pages: engine.pageCount))

            navButton(icon: "chevron.right", tip: "Next slide (Right arrow)") { engine.next() }
            navButton(icon: "forward.end.fill", tip: "Last slide (Cmd+Right)") { engine.goToLast() }

            SlideNumberField(engine: engine)
        }
    }

    private var programGroup: some View {
        footerGroup("PROGRAM", tint: ARCTheme.secCrimson) {
            // Assessment item 7: a frozen Zoom window is said on the PROGRAM group, not only in a chip.
            if ArcPresenterApp.sharedZoom.sourceState == .frozen {
                Button(action: { Task { await ArcPresenterApp.sharedZoom.returnToDeck() } }) {
                    VStack(spacing: 0) {
                        Text("ZOOM FROZEN").font(ARCTheme.mono(11, .heavy))
                        Text("RETURN").font(ARCTheme.mono(15, .heavy))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(ARCTheme.liveRed)
                    .cornerRadius(4)
                }
                .buttonStyle(.plain)
                .fixedSize()
                .help("Zoom's window went off screen and its picture stopped (it collapses on share start). RETURN to the deck, then PICK the dual-monitor second window in SOURCES > ZOOM")
            }
            if deckManager.isPreviewingOffline {
                Button(action: { deckManager.take() }) {
                    Text("TAKE")
                        .font(ARCTheme.mono(17, .heavy))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(ARCTheme.liveRed)
                        .cornerRadius(4)
                }
                .buttonStyle(.plain)
                .fixedSize()
                .help("Push preview deck to live output (Cmd+Shift+Enter)")
            }

            Button(action: { engine.toggleBlack() }) {
                Text("BLACK")
                    .font(ARCTheme.mono(17, .heavy))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(engine.isBlack ? ARCTheme.liveRed : ARCTheme.surfaceLight)
                    .foregroundStyle(engine.isBlack ? .white : ARCTheme.textPrimary)
                    .cornerRadius(4)
            }
            .buttonStyle(.plain)
            .fixedSize()
            .help("Black out all outputs (B key)")
        }
    }

    private func monitorGroup(compact: Bool) -> some View {
        footerGroup("MONITOR", tint: ARCTheme.secBlue, badge: ARCBandBadge(text: "\(Int(prefs.confidenceNotesFontSize)) PT", fill: ARCTheme.text0)) {
            monitorControls(compact: compact)
        }
    }

    /// One footer section: a small mono caption over its controls, in a
    /// hairline panel, so the strip reads as groups instead of one run.
    /// A footer section, built exactly as a rail module is (2026-09-17:
    /// "apply that to this area as well"): the title in a filled band inside
    /// the box, the section's colour on band and border.
    private func footerGroup<Content: View>(_ title: String, tint: Color = ARCTheme.line, badge: ARCBandBadge? = nil, hugging: Bool = true, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) { content() }
            .frame(height: ARCTheme.footerRowH)     // identical construction: one row height for all four
            .arcModule(title: title, tint: tint, hugging: hugging, badge: badge)
    }

    /// The confidence monitor from the operator's seat (2026-09-17: "a
    /// control on the operator page to shift to a notes heavy layout"): which
    /// layout, the notes text size, and the page of a long note.
    private func monitorControls(compact: Bool) -> some View {
        let _ = prefs.confidenceLayoutVersion
        let mode = prefs.confidenceLayoutMode
        return HStack(spacing: 6) {
            HStack(spacing: 0) {
                monitorButton("SLIDES", on: mode == .slides, tip: "Confidence monitor: the slide leads, notes beside it (Cmd+Opt+Shift+N toggles)") { prefs.confidenceLayoutMode = .slides }
                monitorButton("NOTES", on: mode == .notes, tip: "Confidence monitor: the notes lead at full width, CURRENT and NEXT as thumbnails") { prefs.confidenceLayoutMode = .notes }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
            if compact {
                // Folded, never shrunk: the same four actions, full-size, in a menu (keys unchanged).
                Menu {
                    Button("Notes text smaller  (Cmd+Shift+-)") { prefs.stepNotesFont(-1) }
                    Button("Notes text larger  (Cmd+Shift+=)") { prefs.stepNotesFont(1) }
                    Divider()
                    Button("Notes page up  (Cmd+Shift+Up)") { deckManager.notesPage = max(0, deckManager.notesPage - 1) }
                    Button("Notes page down  (Cmd+Shift+Down)") { deckManager.notesPage += 1 }
                } label: {
                    Text("A\u{00B1} \u{25B2}\u{25BC}").font(ARCTheme.mono(13, .heavy)).foregroundStyle(ARCTheme.textPrimary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(ARCTheme.surfaceLight)
                .cornerRadius(4)
                .help("Notes text size and notes paging")
            } else {
                monitorButton("A\u{2212}", on: false, tip: "Notes text smaller (Cmd+Shift+-)") { prefs.stepNotesFont(-1) }
                monitorButton("A+", on: false, tip: "Notes text larger (Cmd+Shift+=)") { prefs.stepNotesFont(1) }
                monitorButton("\u{25B2}", on: false, tip: "Notes page up (Cmd+Shift+Up)") { deckManager.notesPage = max(0, deckManager.notesPage - 1) }
                monitorButton("\u{25BC}", on: false, tip: "Notes page down (Cmd+Shift+Down)") { deckManager.notesPage += 1 }
            }
            // The whole monitor from here (2026-09-19): sizes, and which modules are on it.
            ARCExpandButton(tip: "Monitor layout window: sizes and modules (Cmd+Opt+Shift+L); click again to close", on: ControlWindow.isOpen(title: "Monitor Layout")) {
                ControlWindow.toggle(id: "monitor-layout", title: "Monitor Layout", open: openWindow, dismiss: dismissWindow)
            }
        }
    }

    private func monitorButton(_ label: String, on: Bool, tip: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(ARCTheme.mono(13, .heavy))
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(on ? ARCTheme.secBlue : ARCTheme.surfaceLight)
                .foregroundStyle(on ? ARCTheme.ink : ARCTheme.textPrimary)
                .cornerRadius(on || label.count > 2 ? 0 : 4)
        }
        .buttonStyle(.plain)
        .help(tip)
    }

    /// The live slide's builds, for NAVIGATE's band: yellow while building, green when the next click changes slide.
    private var buildBadge: ARCBandBadge? {
        guard deckManager.liveBuildCount > 0 else { return nil }
        return ARCBandBadge(text: "BUILD \(deckManager.liveBuild)/\(deckManager.liveBuildCount)",
                            fill: deckManager.liveBuild < deckManager.liveBuildCount ? ARCTheme.warn : ARCTheme.readyGreen)
    }

    private func navButton(icon: String, tip: String = "", action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .frame(width: 30, height: 32)
                .foregroundStyle(ARCTheme.textPrimary)
        }
        .buttonStyle(.plain)
        .help(tip)
    }

    private func openOutput(_ type: OutputType) {
        openWindow(id: type.rawValue)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            displayManager.openOutput(type)
        }
    }

    private func openAllOutputs() {
        if displayManager.programScreenID != nil {
            openWindow(id: OutputType.program.rawValue)
        }
        if displayManager.confidenceScreenID != nil {
            openWindow(id: OutputType.confidence.rawValue)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            displayManager.openAllAssigned()
        }
    }

    private func openFileDialog() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf, Self.arcdeckType, .zip] + Self.videoTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Select a PDF, video, .arcdeck, or a zipped .arcdeck"

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            loadFile(url: url)
        }
    }

    private func loadFile(url: URL) {
        // A zip or a folder of one deck becomes the bundle first (DeckArchive);
        // unpacking a 300 MB deck takes seconds, so not on the main thread.
        if DeckArchive.isZip(url) || (!DeckArchive.isArcdeck(url) && !isVideoFile(url) && url.pathExtension.lowercased() != "pdf") {
            DispatchQueue.global(qos: .userInitiated).async {
                let resolved = try? DeckArchive.resolve(url)
                DispatchQueue.main.async {
                    guard let resolved else { NSSound.beep(); return }
                    loadFile(url: resolved)
                }
            }
            return
        }
        recentFiles.add(url)
        let targetSize = displayManager.externalScreenSize ?? CGSize(width: 1920, height: 1080)
        let kind: DeckKind = detectKind(url)
        deckManager.addDeck(url: url, targetSize: targetSize, kind: kind)
    }

    private func detectKind(_ url: URL) -> DeckKind {
        if url.pathExtension.lowercased() == "arcdeck" { return .arcdeck }
        if isVideoFile(url) { return .video }
        return .pdf
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        let types = [UTType.pdf.identifier, UTType.zip.identifier, UTType.fileURL.identifier] + Self.videoTypes.map(\.identifier)
        for typeID in types {
            if provider.hasItemConformingToTypeIdentifier(typeID) {
                provider.loadItem(forTypeIdentifier: typeID, options: nil) { data, _ in
                    if let url = data as? URL {
                        DispatchQueue.main.async { loadFile(url: url) }
                    }
                }
                return true
            }
        }
        return false
    }

    private func isVideoFile(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return Self.videoTypes.contains(where: { type.conforms(to: $0) })
    }
}

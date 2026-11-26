//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

struct TimerRunView: View {
    let show: Show
    let displayMode: DisplayMode
    @Environment(TimerEngine.self) private var engine
    @Environment(ExternalDisplayManager.self) private var displayManager
    @Environment(StageDirector.self) private var stageDirector
    @Environment(HTTPRemoteServer.self) private var httpServer
    @Environment(StageDisplayState.self) private var displayState
    @Environment(ConfidenceMonitorState.self) private var confidenceState
    #if os(macOS)
    @Environment(OutputRoutingManager.self) private var routingManager
    @Environment(DeckLinkOutputManager.self) private var deckLinkManager
    #endif
    @State private var showSidebar = true
    @AppStorage(KeyOverlaySetting.defaultsKey) private var keyOverlayOn = false
    /// The operator's chosen layout (RUN | DECK | WIDGET chip), remembered.
    @AppStorage(RunLayout.defaultsKey) private var runLayoutRaw = RunLayout.run.rawValue
    private var runLayout: RunLayout { RunLayout(rawValue: runLayoutRaw) ?? .run }
    /// The control DECK: chosen on the LAYOUT chip, or forced by a Key Overlay run (its controls live there).
    private var isDeck: Bool {
        #if os(macOS)
        displayMode.confidenceMode != nil || runLayout == .deck
        #else
        displayMode.isExtended
        #endif
    }
    @State private var showConfidenceSettings = false
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @State private var showStagePreview = false
    @State private var showStopConfirmation = false

    private var isCompact: Bool { sizeClass == .compact }
    /// The console window's width. The toolbar lays its items out at their ideal widths and pushes whatever
    /// does not fit into an overflow menu, so the items read this and slim down before that happens.
    @State private var consoleWidth: CGFloat = 1600
    private var narrowTitleBar: Bool { consoleWidth < 1240 }
    /// The run order grows a little with the console, so titles keep more of their words.
    private var sidebarWidth: CGFloat { min(max(consoleWidth * 0.19, ARCTheme.sidebarWidth), 340) }

    /// "CUE 1 / 3" for the CUE module's band.
    private var cueCountLabel: String {
        let total = engine.cues.count
        guard total > 0 else { return "NO CUES" }
        return "CUE \(min(engine.currentCueIndex + 1, total)) / \(total)"
    }

    var body: some View {
        @Bindable var engine = engine

        ZStack {
            // The console sits on the ARC grey ground; the stage colours live inside the TIMER module.
            (isCompact ? displayState.colorScheme.stageBackground : ARCTheme.background).ignoresSafeArea()

            if isCompact {
                if isDeck {
                    compactControlLayout
                } else {
                    compactLayout
                }
            } else if isDeck {
                controlPanelLayout
            } else {
                regularLayout
            }

            // The floating ARC mark belongs to what the ROOM sees. On the control-panel layout it sat on top of
            // the OUTPUTS section and clipped it (seen in the review, 2026-09-17), so the console does without.
            if isCompact && !isDeck {
                GeometryReader { geo in
                    VStack {
                        HStack {
                            Spacer()
                            arcLogoBadge(screenHeight: geo.size.height)
                        }
                        Spacer()
                    }
                    .padding(.top, 4)
                    .padding(.trailing, 12)
                }
                .allowsHitTesting(false)
            }
        }
        .onAppear {
            // Run Timer > With Confidence Monitor is an explicit choice of the DECK; the other entries leave
            // the operator's LAYOUT chip alone.
            #if os(macOS)
            if displayMode == .extended { runLayoutRaw = RunLayout.deck.rawValue }
            #endif
            engine.loadShow(show)
            stageDirector.holdEventName = show.name
            confidenceState.loadFrom(show)

            // Auto-enable confidence if launched in confidence mode
            if let mode = displayMode.confidenceMode {
                confidenceState.config.mode = mode
                confidenceState.config.isEnabled = true
            }
        }
        .onChange(of: engine.state) { _, newState in
            // Auto-snap back to timer when playback starts
            if newState == .running && stageDirector.stageMode != .timer {
                stageDirector.setMode(.timer)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { consoleWidth = $0 }
        .environment(\.displayColorScheme, displayState.colorScheme)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            #if os(iOS)
            ToolbarItem(placement: .topBarLeading) {
                closeButton
            }
            ToolbarItem(placement: .principal) {
                headerBar
            }
            ToolbarItem(placement: .topBarTrailing) {
                trailingToolbarContent
            }
            #else
            ToolbarItem(placement: .navigation) {
                closeButton
            }
            ToolbarItem(placement: .principal) {
                headerBar
            }
            ToolbarItem(placement: .primaryAction) {
                trailingToolbarContent
            }
            #endif
        }
        #if os(iOS)
        .toolbarBackground(ARCTheme.surface, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .fullScreenCover(isPresented: $showStagePreview) {
            ZStack(alignment: .topTrailing) {
                StageDisplayView()
                    .environment(displayState)
                Button {
                    showStagePreview = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title)
                        .foregroundStyle(.white.opacity(0.7))
                        .padding()
                }
            }
        }
        #else
        .sheet(isPresented: $showStagePreview) {
            StageDisplayView()
                .environment(displayState)
                .frame(minWidth: 800, minHeight: 450)
        }
        #endif
        .alert("Stop Show?", isPresented: $showStopConfirmation) {
            Button("Stop & Exit", role: .destructive) {
                engine.stop()
                #if os(macOS)
                routingManager.restorePresentationOptions()
                #endif
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Timer is active. Stopping will reset all progress.")
        }
    }

    // MARK: - Toolbar Components

    private var closeButton: some View {
        Button {
            if engine.state == .running || engine.state == .overtime || engine.state == .paused {
                showStopConfirmation = true
            } else {
                engine.stop()
                #if os(macOS)
                routingManager.restorePresentationOptions()
                #endif
                dismiss()
            }
        } label: {
            Image(systemName: "xmark")
                .foregroundStyle(ARCTheme.textSecondary)
        }
        .help("Exit Show — stop the timer and return to the show list")
    }

    private var trailingToolbarContent: some View {
        HStack(spacing: 12) {
            #if os(macOS)
            layoutChip
            #endif
            if !isCompact {
                Button {
                    withAnimation { showSidebar.toggle() }
                } label: {
                    Image(systemName: "sidebar.left")
                        .foregroundStyle(ARCTheme.textSecondary)
                }
                .help("Toggle Sidebar — show or hide the cue list panel")
            }
            Menu {
                Toggle("Auto-Advance", isOn: Bindable(engine).autoAdvance)

                Divider()

                Menu("Display Theme") {
                    ForEach(DisplayColorScheme.allCases) { scheme in
                        Button {
                            displayState.colorScheme = scheme
                        } label: {
                            if displayState.colorScheme == scheme {
                                Label {
                                    Text(scheme.displayName)
                                    Text(scheme.description)
                                } icon: {
                                    Image(systemName: "checkmark")
                                }
                            } else {
                                VStack(alignment: .leading) {
                                    Text(scheme.displayName)
                                    Text(scheme.description)
                                        .font(.caption2)
                                }
                            }
                        }
                    }
                }

                Menu("Monitor Layout") {
                    ForEach(StageLayout.allCases) { layout in
                        Button {
                            displayState.stageLayout = layout
                        } label: {
                            if displayState.stageLayout == layout {
                                Label {
                                    Text(layout.displayName)
                                    Text(layout.description)
                                } icon: {
                                    Image(systemName: "checkmark")
                                }
                            } else {
                                VStack(alignment: .leading) {
                                    Text(layout.displayName)
                                    Text(layout.description)
                                        .font(.caption2)
                                }
                            }
                        }
                    }
                }

                Menu("Stage Mode") {
                    ForEach(StageMode.allCases, id: \.self) { mode in
                        Button {
                            stageDirector.setMode(mode)
                        } label: {
                            Label(mode.label, systemImage: mode.icon)
                        }
                    }
                }

                Toggle("HTTP Remote", isOn: Binding(
                    get: { httpServer.isRunning },
                    set: { $0 ? httpServer.start() : httpServer.stop() }
                ))

                Divider()

                Button("Export Session Log") {
                    exportSessionLog()
                }
                .disabled(engine.sessionLog.isEmpty)

                Divider()

                Button("Reset Cue") { engine.reset() }
                Button("Stop Show") { engine.stop() }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(ARCTheme.textSecondary)
            }
            .help("Show Menu — display theme, monitor layout, stage mode, HTTP remote, session log export, and more")
        }
    }

    // MARK: - Floating ARC Logo Badge

    private func arcLogoBadge(screenHeight: CGFloat) -> some View {
        let sch = displayState.colorScheme
        // 15 % of the height put the mark on top of the cue subtitle, which ran under it ("...while you watch",
        // seen in the review 2026-09-17). It is a badge, not a headline: smaller, and the text is inset from it.
        let logoH = min(screenHeight * 0.075, 64)
        return Image("ARCLogo")
            .renderingMode(.template)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(height: logoH)
            .foregroundStyle(ARCTheme.arcRed)
            .shadow(color: Color.white.opacity(0.9), radius: 1, x: 0, y: 0)
            .shadow(color: Color.white.opacity(0.6), radius: 4, x: 0, y: 0)
            .shadow(color: Color.black.opacity(0.5), radius: 6, x: 0, y: 2)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(Color.black.opacity(sch.isLightBackground ? 0.06 : 0.4))
            )
    }

    // MARK: - Header

    /// The show in the title bar. It lives in the toolbar's principal slot, which AppKit sizes to the item's
    /// IDEAL width, so the item must stay modest or it spills out of its capsule and pushes the LAYOUT switch
    /// into the overflow menu (2026-09-25: the top text exceeded the space available). The name
    /// truncates, the ARC number and the offset never do, and the clock goes first when room runs out.
    private var headerBar: some View {
        Group {
            if narrowTitleBar { headerRow(clock: false) } else { headerRow(clock: true) }
        }
        .frame(maxWidth: narrowTitleBar ? 300 : 560)
    }

    private func headerRow(clock: Bool) -> some View {
        HStack(spacing: 10) {
            if let arcNum = show.arcNumber, !arcNum.isEmpty {
                Text(arcNum)
                    .font(ARCTheme.mono(15, .heavy))
                    .foregroundStyle(ARCTheme.accent)
                    .lineLimit(1).fixedSize()
            }
            Text(show.name)
                .font(ARCTheme.mono(15, .heavy))
                .foregroundStyle(ARCTheme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: narrowTitleBar ? 180 : 300, alignment: .leading)
                .layoutPriority(-1)
                .help(show.name)

            if engine.isScheduledShow && engine.showStartedAt != nil {
                HStack(spacing: 6) {
                    Text(engine.showOffsetDisplay)
                        .font(ARCTheme.mono(13, .heavy))
                    Text(engine.offsetStatus.label)
                        .font(ARCTheme.mono(10, .heavy))
                        .tracking(1)
                }
                .foregroundStyle(engine.offsetStatus.color)
                .lineLimit(1).fixedSize()
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(engine.offsetStatus.color.opacity(0.18), in: Capsule())
            }

            if clock {
                Text(Date.now, style: .time)
                    .font(ARCTheme.mono(15, .bold))
                    .foregroundStyle(ARCTheme.textSecondary)
                    .monospacedDigit()
                    .lineLimit(1).fixedSize()
            }
        }
        .padding(.horizontal, 6)
    }

    // MARK: - Stage Mode Controls

    private var stageModeControls: some View { stageModeModule(hugging: true) }

    /// On the control deck a module FILLS its column, so it must not hug its chips.
    private func stageModeModule(hugging: Bool) -> some View {
        HStack(spacing: 6) {
            ForEach(StageMode.allCases, id: \.self) { mode in
                let on = stageDirector.stageMode == mode
                ARCChip(tint: ARCTheme.secOrange, on: on) { stageDirector.setMode(mode) } label: {
                    HStack(spacing: 5) {
                        Image(systemName: mode.icon).font(.system(size: 11))
                        Text(mode.label.uppercased())
                    }
                }
                .help(stageModeHelp(for: mode))
            }
        }
        .deckFill(hugging)
        .arcModule(title: "Stage Mode", tint: ARCTheme.secOrange, hugging: hugging)
    }

    private func stageModeHelp(for mode: StageMode) -> String {
        switch mode {
        case .timer: "Timer Mode — show the countdown timer on the confidence monitor"
        case .clock: "Clock Mode — show the current time of day on the confidence monitor"
        case .hold: "Hold Mode — show a holding screen with the event name on the confidence monitor"
        }
    }

    // MARK: - Operator Mode Content

    @ViewBuilder
    private var operatorModeContent: some View {
        switch stageDirector.stageMode {
        case .timer:
            EmptyView() // Timer content handled by existing layout
        case .clock:
            ClockDisplayView(stage: false)
                .frame(maxWidth: .infinity, minHeight: 200, maxHeight: 300)
                .clipShape(RoundedRectangle(cornerRadius: ARCTheme.cornerRadius))
                .padding(.horizontal, ARCTheme.paddingMedium)
        case .hold:
            HoldDisplayView(
                eventName: stageDirector.holdEventName,
                stage: false
            )
            .frame(maxWidth: .infinity, minHeight: 200, maxHeight: 300)
            .clipShape(RoundedRectangle(cornerRadius: ARCTheme.cornerRadius))
            .padding(.horizontal, ARCTheme.paddingMedium)
        }
    }

    // MARK: - Control Panel Layout (HDMI connected)

    /// The operator's console, filling the window (2026-09-17 review: large swaths of negative space,
    /// elements too small, the area badly used). It was a
    /// ScrollView, so every part sat at its ideal size and the middle of a 1900 pt window was empty black.
    /// Now: a fixed strip of sections at the top, a fixed row of them at the bottom, and the CUE module takes
    /// everything in between, so the number is as big as the glass allows.
    private var controlPanelLayout: some View {
        HStack(spacing: 0) {
            if showSidebar {
                CueListSidebar(
                    engine: engine,
                    onSelect: { engine.goToCue(at: $0) },
                    width: sidebarWidth
                )
                Divider()
                    .background(ARCTheme.divider)
            }

            // The console column is laid out INTO its width, not out of its contents. The deck's columns are
            // computed from that width, and a view whose ideal width follows the window is a LOOP: the
            // window's content size grew, which widened the deck, which grew the content size, until AppKit
            // gave up ("more Update Constraints in Window passes than there are views", 2026-09-17).
            GeometryReader { geo in
            // PROGRAM: the operator's run panel at laptop size. The cue list beside it is the programming
            // surface; the timer is big enough to read at arm's length and no bigger (2026-09-17: the
            // operator does not need a big timer display). Taller than the window, it scrolls.
            // The TIMER takes whatever height the deck leaves (2026-09-25: the elements must not
            // break when the control monitor resolution changes): a 128 pt floor on a laptop, bigger on a tall
            // display instead of an empty band under the deck. Only a window too short for the floor scrolls.
            let column = VStack(spacing: 8) {
                operatorAlertBand
                if stageDirector.stageMode == .timer {
                    CueInfoPanel(
                        currentCue: engine.currentCue,
                        nextCue: engine.nextCue,
                        compact: true
                    )
                    .frame(maxWidth: .infinity)
                    .arcModule(title: "Now", tint: ARCTheme.secOrange,   // OPERATE: the cue under the operator's hands (brand roles, 2026-09-18)
                               badge: ARCBandBadge(text: cueCountLabel, fill: ARCTheme.text0))

                    VStack(spacing: 8) {
                        CountdownDisplay(
                            displayTime: engine.displayTime,
                            colorState: engine.colorState,
                            isOvertime: engine.isOvertime
                        )
                        .frame(minHeight: 128, maxHeight: .infinity)
                        progressBarWithThresholds
                            .frame(height: 10)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .arcModule(title: "Timer", tint: engine.isOvertime ? ARCTheme.arcRed : ARCTheme.secGreen)
                } else {
                    operatorModeContent
                        .frame(maxWidth: .infinity)
                        .frame(height: 260)
                }

                controlDeck(width: max(0, geo.size.width - 20))
            }
            .padding(10)
            .frame(width: geo.size.width, alignment: .top)

            ViewThatFits(in: .vertical) {
                column
                ScrollView(.vertical) { column }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
            .background(stageDirector.stageMode == .timer
                        ? engine.colorState.backgroundColor(for: displayState.colorScheme)
                        : Color.clear)
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    #if os(iOS)
                    if displayManager.hasExternalScreen {
                        displayManager.openOnExternalScreen()
                    } else {
                        openWindow.output("stage-display")
                    }
                    #else
                    // Every output that has a display (remembered across launches, by display identity)
                    // opens on it. One not set stays closed until the operator gives it a display.
                    openAssignedOutputs()
                    #endif
                }
            }
            .onChange(of: engine.colorState) { oldState, newState in
                stageDirector.handleColorStateChange(from: oldState, to: newState)
            }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Control Deck

    /// EVERY control, below the glass, on ONE grid (2026-09-17: all of the control modules fit below
    /// the main screen, each one uniform in size or half of the largest).
    ///
    /// The strip that sat ABOVE the cue is now the deck's first row, so the timer owns the whole upper
    /// console. And no module is sized by its own contents any more: the deck is four columns wide, a module
    /// is either a WHOLE unit (two columns, half the console) or HALF of one (a single column), so the
    /// sections line up down the console instead of each one ending wherever its buttons ran out.
    ///
    ///     STAGE DISPLAY ½ | WEB STAGE  1  | STAGE MODE ½
    ///     TRANSPORT     1  | STAGE FLASH 1
    ///     STAGE MESSAGES 1  | OUTPUTS   ½
    ///
    /// TRANSPORT and STAGE FLASH are the two that cannot shrink (fixed 76 pt colour keys, eight transport
    /// keys), and they are what the unit is measured from: a whole unit is always wide enough for them.
    private func controlDeck(width: CGFloat) -> some View {
        // Four columns when the console is wide; on HALF a display, two, so a whole unit is the column's
        // full width and TRANSPORT still fits. Same rule either way: a module is a unit or half of one.
        let wide = deckUnit(in: width, columns: 4) != nil
        let unit = deckUnit(in: width, columns: wide ? 4 : 2)
        return VStack(spacing: deckGap) {
            if wide {
                // Every row full, no module a big empty box (2026-09-25): the four small status modules share
                // one row, the two instruments the next, and MESSAGES has the whole width for its keys.
                deckRow {
                    transportModule.deckCell(unit, 2)
                    FlashControlPanel(hugging: false).deckCell(unit, 2)
                }
                deckRow {
                    MessageControlPanel().deckCell(unit, 4)
                }
                deckRow {
                    stageDisplayModule.deckCell(unit, 1)
                    webStageModule.deckCell(unit, 1)
                    stageModeModule(hugging: false).deckCell(unit, 1)
                    #if os(macOS)
                    outputsModule.deckCell(unit, 1)
                    #else
                    Color.clear.deckCell(unit, 1)
                    #endif
                }
            } else {
                deckRow { transportModule.deckCell(unit, 2) }
                deckRow { FlashControlPanel(hugging: false).deckCell(unit, 2) }
                deckRow { MessageControlPanel().deckCell(unit, 2) }
                deckRow {
                    stageDisplayModule.deckCell(unit, 1)
                    webStageModule.deckCell(unit, 1)
                }
                deckRow {
                    stageModeModule(hugging: false).deckCell(unit, 1)
                    #if os(macOS)
                    outputsModule.deckCell(unit, 1)
                    #endif
                }
            }
        }
        .frame(width: width, alignment: .leading)
        #if os(macOS)
        .sheet(isPresented: $showConfidenceSettings) {
            confidenceSettingsSheet
        }
        #endif
    }

    private var deckGap: CGFloat { 8 }

    /// One row of the deck. Its height is the tallest module in it, and every module in it takes that
    /// height, so a row reads as one band rather than three boxes of different depths.
    private func deckRow<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: deckGap) {
            content()
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// One column of the four-column deck, or nil when the console is too narrow for the grid to hold the
    /// modules that cannot shrink: below that the modules take their natural widths, as they did.
    private func deckUnit(in width: CGFloat, columns: Int) -> CGFloat? {
        let unit = (width - deckGap * CGFloat(columns - 1)) / CGFloat(columns)
        // TRANSPORT's eight keys and STAGE FLASH's four colour keys are fixed widths and cannot shrink. A
        // console too narrow to hold them in a whole unit gets the old content-sized modules instead.
        guard width > 0, unit * 2 + deckGap >= 640 else { return nil }
        return unit
    }

    private var transportModule: some View {
        TransportControls(engine: engine)
            .deckFill()
            .arcModule(title: "Transport", tint: ARCTheme.secOrange)   // OPERATE, not IN
    }

    /// What the show is going OUT on, in the console's sections (2026-09-17: the ARC style applied).
    /// It was a row of cyan capsules whose labels ran out of room and clipped ("SEND TO DIS…", "CONF…").
    private var stageDisplayModule: some View {
        HStack(spacing: 6) {
                ARCChip(tint: ARCTheme.readyGreen, on: displayManager.isConnected) {
                    #if os(iOS)
                    if displayManager.hasExternalScreen { displayManager.openOnExternalScreen() } else { openWindow.output("stage-display") }
                    #else
                    openWindow.output("stage-display"); displayManager.openOnExternalScreen()
                    #endif
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: displayManager.isConnected ? "tv.fill" : "rectangle.on.rectangle").font(.system(size: 11))
                        Text(displayManager.isConnected ? "LIVE" : displayManager.hasExternalScreen ? "SEND" : "OPEN")
                    }
                }
                .help("Confidence Monitor: open or reconnect the confidence monitor output on its display (HDMI or AirPlay)")

                ARCChip("Preview", tint: ARCTheme.secBlue) { showStagePreview = true }
                    .help("Preview: see exactly what the audience sees on the confidence monitor")
            }
        .deckFill()
        .arcModule(title: "Confidence Monitor", tint: ARCTheme.secGreen,
                   badge: displayManager.isConnected ? ARCBandBadge(text: "ON AIR", fill: ARCTheme.ink) : nil)
    }

    private var webStageModule: some View {
        HStack(spacing: 6) {
                ARCChip(tint: ARCTheme.readyGreen, on: httpServer.isRunning) {
                    if httpServer.isRunning { httpServer.stop() } else { httpServer.start() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "network").font(.system(size: 11))
                        Text(verbatim: httpServer.isRunning ? "ON :\(String(httpServer.port))" : "OFF")
                    }
                }
                .help("HTTP Remote: start or stop the web server so any browser on the network can view the confidence monitor")

                if httpServer.isRunning, let ip = HTTPRemoteServer.localIPAddress() {
                    Text(verbatim: "http://\(ip):\(String(httpServer.port))/stage")
                        .font(ARCTheme.mono(11, .regular))
                        .foregroundStyle(ARCTheme.textSecondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
        .deckFill()
        .arcModule(title: "Web Stage", tint: ARCTheme.secBlue)
    }

    #if os(macOS)
    private var outputsModule: some View {
        HStack(spacing: 6) {
            ARCChip("Assign", tint: ARCTheme.secBlue) { OutputsPanelController.shared.isOpen = true }
                .help("OUTPUTS panel: which display each output goes to (the header chips do it in one click)")
            // The KEY OVERLAY and its layout settings exist only while it is enabled in Settings.
            if keyOverlayOn { confidenceMonitorCapsule }
        }
        .deckFill()
        .arcModule(title: "Outputs", tint: ARCTheme.secCrimson)
    }
    #endif

    #if os(macOS)
    /// Open every room output that has a connected display, each on its own display, one after the other so
    /// they do not all flash up on the console first. Unassigned and unplugged outputs stay closed.
    private func openAssignedOutputs() {
        let placement = ArcStageTimerApp.sharedPlacement
        let due = StageWindow.roomOutputs.filter { placement.state($0).display != nil }
        for (i, w) in due.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 1.2) {
                openWindow.output(w.sceneID)
                placement.placeWhenOpen(w)
                if w == .stage { displayManager.isConnected = true }
                if w == .confidence { displayManager.isConfidenceActive = true }
            }
        }
    }
    #endif

    // MARK: - Confidence Monitor Controls

    #if os(macOS)
    @ViewBuilder
    private var confidenceMonitorCapsule: some View {
        @Bindable var cs = confidenceState

        HStack(spacing: 6) {
            ARCChip(tint: displayManager.isConfidenceActive ? ARCTheme.readyGreen : ARCTheme.secBlue,
                    on: displayManager.isConfidenceActive || confidenceState.config.isEnabled) {
                confidenceState.config.isEnabled.toggle()
                if confidenceState.config.isEnabled {
                    openWindow.output("confidence-output")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        displayManager.openConfidenceOnExternalScreen()
                    }
                } else {
                    displayManager.closeConfidenceDisplay()
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: confidenceState.config.isEnabled ? "rectangle.on.rectangle.fill" : "rectangle.on.rectangle")
                        .font(.system(size: 11))
                    Text(displayManager.isConfidenceActive ? "KEY LIVE" : "KEY")
                }
                .fixedSize()    // it read "CONF…" and "CONF (" in every review: the label is never squeezed
            }
            .help("Key Overlay: the timer as a fill + key layer for the ATEM (overlay or PIP)")

            ARCChip(tint: ARCTheme.secBlue) { showConfidenceSettings = true } label: {
                Image(systemName: "gear").font(.system(size: 12))
            }
            .help("Key overlay settings")
        }
    }

    @ViewBuilder
    private var confidenceSettingsSheet: some View {
        @Bindable var cs = confidenceState

        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                Text("KEY OVERLAY")
                    .font(ARCTheme.mono(15, .heavy))
                    .foregroundStyle(ARCTheme.ink)
                    .tracking(1.4)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(ARCTheme.secCrimson)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                Spacer()
                ARCActionButton("Done", size: 13) { showConfidenceSettings = false }
                    .frame(height: 34)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.bottom, 8)

            // Mode picker
            VStack(alignment: .leading, spacing: 6) {
                Text("MODE")
                    .font(ARCTheme.mono(11, .heavy))
                    .foregroundStyle(ARCTheme.secBlue)
                    .tracking(1.4)
                Picker("", selection: $cs.config.mode) {
                    ForEach(ConfidenceMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Text(confidenceState.config.mode.description)
                    .font(.system(size: 11))
                    .foregroundStyle(ARCTheme.textTertiary)
            }

            // Layout picker
            VStack(alignment: .leading, spacing: 6) {
                Text("LAYOUT")
                    .font(ARCTheme.mono(11, .heavy))
                    .foregroundStyle(ARCTheme.secBlue)
                    .tracking(1.4)

                let layouts = ConfidenceLayout.layouts(for: confidenceState.config.mode)
                Picker("", selection: $cs.config.layout) {
                    ForEach(layouts) { layout in
                        Text(layout.displayName).tag(layout)
                    }
                }
                .pickerStyle(.segmented)
            }

            // Element visibility
            VStack(alignment: .leading, spacing: 6) {
                Text("ELEMENTS")
                    .font(ARCTheme.mono(11, .heavy))
                    .foregroundStyle(ARCTheme.secBlue)
                    .tracking(1.4)

                HStack(spacing: 16) {
                    Toggle("Countdown", isOn: $cs.config.showCountdown)
                    Toggle("Cue Info", isOn: $cs.config.showCueInfo)
                    Toggle("Next Cue", isOn: $cs.config.showNextCue)
                }
                HStack(spacing: 16) {
                    Toggle("Progress", isOn: $cs.config.showProgressBar)
                    Toggle("Offset", isOn: $cs.config.showOffset)
                    Toggle("Messages", isOn: $cs.config.showMessage)
                    Toggle("Clock", isOn: $cs.config.showClock)
                }
            }
            .toggleStyle(.checkbox)
            .font(.system(size: 12))

            // Element sizing
            VStack(alignment: .leading, spacing: 6) {
                Text("ELEMENT SIZING")
                    .font(ARCTheme.mono(11, .heavy))
                    .foregroundStyle(ARCTheme.secBlue)
                    .tracking(1.4)

                HStack(spacing: 16) {
                    labeledSlider("Countdown", value: $cs.config.countdownScale, range: 0.5...2.0, labelWidth: 80)
                    labeledSlider("Cue Info", value: $cs.config.cueInfoScale, range: 0.5...2.0, labelWidth: 80)
                }
                HStack(spacing: 16) {
                    labeledSlider("Progress", value: $cs.config.progressBarScale, range: 0.5...2.0, labelWidth: 80)
                    labeledSlider("Messages", value: $cs.config.messageScale, range: 0.5...2.0, labelWidth: 80)
                }
                HStack(spacing: 16) {
                    labeledSlider("Offset", value: $cs.config.offsetScale, range: 0.5...2.0, labelWidth: 80)
                    labeledSlider("Margins", value: $cs.config.elementMargin, range: 0.3...2.0, labelWidth: 80)
                }

                if confidenceState.config.mode == .overlay {
                    HStack(spacing: 16) {
                        labeledSlider("Inset", value: $cs.config.overlayInset, range: 0...0.3, labelWidth: 80)
                        Spacer()
                    }
                }
            }

            // Accent bar
            VStack(alignment: .leading, spacing: 6) {
                Text("ACCENT BAR")
                    .font(ARCTheme.mono(11, .heavy))
                    .foregroundStyle(ARCTheme.secBlue)
                    .tracking(1.4)

                HStack(spacing: 16) {
                    Picker("Position", selection: $cs.config.accentBarPosition) {
                        ForEach(AccentBarPosition.allCases) { pos in
                            Text(pos.rawValue.capitalized).tag(pos)
                        }
                    }
                    .frame(maxWidth: 200)

                    HStack(spacing: 8) {
                        Text("Size")
                            .font(.system(size: 12))
                            .foregroundStyle(ARCTheme.textSecondary)
                        Slider(value: $cs.config.accentBarSize, in: 0...12, step: 1)
                            .frame(maxWidth: 120)
                        Text("\(Int(confidenceState.config.accentBarSize))px")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(ARCTheme.textTertiary)
                    }
                }
            }

            // PIP zone controls (only in PIP mode)
            if confidenceState.config.mode == .pip {
                VStack(alignment: .leading, spacing: 6) {
                    Text("PIP ZONE")
                        .font(ARCTheme.mono(11, .heavy))
                        .foregroundStyle(ARCTheme.secBlue)
                        .tracking(1.4)

                    HStack(spacing: 16) {
                        labeledSlider("X", value: $cs.config.pipZoneX, range: 0...0.5)
                        labeledSlider("Y", value: $cs.config.pipZoneY, range: 0...0.5)
                    }
                    HStack(spacing: 16) {
                        labeledSlider("W", value: $cs.config.pipZoneWidth, range: 0.2...1.0)
                        labeledSlider("H", value: $cs.config.pipZoneHeight, range: 0.2...1.0)
                    }
                }
            }

            // Output controls
            VStack(alignment: .leading, spacing: 6) {
                Text("OUTPUT")
                    .font(ARCTheme.mono(11, .heavy))
                    .foregroundStyle(ARCTheme.secBlue)
                    .tracking(1.4)

                HStack(spacing: 6) {
                    // On the KEY OVERLAY's assigned display (header chip / OUTPUTS panel), never simply the first external.
                    StripButton(title: "OPEN OUTPUT", tint: ARCTheme.secCrimson) {
                        openWindow.output("confidence-output")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            displayManager.openConfidenceOnExternalScreen()
                        }
                    }
                    StripButton(title: "CLOSE") {
                        displayManager.closeConfidenceDisplay()
                        confidenceState.config.isEnabled = false
                    }
                    Text(confidenceTargetText)
                        .font(ARCTheme.mono(12, .bold))
                        .foregroundStyle(ArcStageTimerApp.sharedPlacement.state(.confidence) == .notSet ? ARCTheme.warn : ARCTheme.text0)
                        .lineLimit(1).truncationMode(.middle)
                }
            }

            Spacer()
        }
        .padding(24)
        .frame(width: 600, height: 700)
        .font(ARCTheme.mono(12, .regular))
        .background(ARCTheme.moduleBg)
    }

    private var confidenceTargetText: String {
        switch ArcStageTimerApp.sharedPlacement.state(.confidence) {
        case .notSet: return "NO DISPLAY SET: first free display"
        case .unplugged(let s): return "UNPLUGGED \(s.name)"
        case .onDisplay(let d): return "→ \(d.index) \(d.name) \(d.resolution)"
        }
    }

    private func labeledSlider(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, labelWidth: CGFloat = 16) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(ARCTheme.textTertiary)
                .frame(width: labelWidth, alignment: .leading)
            Slider(value: value, in: range, step: 0.01)
            Text(String(format: "%.0f%%", value.wrappedValue * 100))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(ARCTheme.textTertiary)
                .frame(width: 40)
        }
    }
    #endif

    // MARK: - iPad Layout (Regular)

    private var regularLayout: some View {
        HStack(spacing: 0) {
            if showSidebar {
                CueListSidebar(
                    engine: engine,
                    onSelect: { engine.goToCue(at: $0) },
                    width: sidebarWidth
                )
                Divider()
                    .background(ARCTheme.divider)
            }

            mainTimerPanel
        }
    }

    // MARK: - iPhone Layout (Compact)

    private var compactLayout: some View {
        VStack(spacing: 0) {
            mainTimerPanelCompact
        }
    }

    // MARK: - iPhone + External Display (Compact Control)

    private var compactControlLayout: some View {
        ScrollView {
            VStack(spacing: 0) {
                // HDMI/HTTP status
                compactStatusBar

                // Stage mode selector
                stageModeControls
                    .padding(.top, 8)

                operatorAlertBand
                if stageDirector.stageMode == .timer {
                    CueInfoPanel(
                        currentCue: engine.currentCue,
                        nextCue: engine.nextCue,
                        compact: true
                    )
                    .padding(.top, ARCTheme.paddingSmall)

                    CountdownDisplayCompact(
                        displayTime: engine.displayTime,
                        colorState: engine.colorState,
                        isOvertime: engine.isOvertime
                    )
                    .frame(maxWidth: .infinity, minHeight: 180, maxHeight: 240)
                    .padding(.horizontal, ARCTheme.paddingMedium)

                    progressBarWithThresholds
                        .padding(.horizontal, 24)
                } else {
                    operatorModeContent
                        .padding(.top, ARCTheme.paddingSmall)
                }

                TransportControls(engine: engine)
                    .padding(.vertical, ARCTheme.paddingSmall)

                Divider()
                    .background(ARCTheme.divider)
                    .padding(.horizontal, 16)

                MessageControlPanel()
                    .padding(.horizontal, 16)
                    .padding(.top, 12)

                FlashControlPanel()
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 16)
            }
        }
        .frame(maxWidth: .infinity)
        .background(
            ZStack {
                displayState.colorScheme.stageBackground
                stageDirector.stageMode == .timer
                    ? engine.colorState.backgroundColor(for: displayState.colorScheme)
                    : Color.clear
            }
        )
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                #if os(iOS)
                if displayManager.hasExternalScreen {
                    displayManager.openOnExternalScreen()
                } else {
                    openWindow.output("stage-display")
                }
                #else
                openWindow.output("stage-display")
                displayManager.openOnExternalScreen()
                #endif
            }
        }
        .onChange(of: engine.colorState) { oldState, newState in
            stageDirector.handleColorStateChange(from: oldState, to: newState)
        }
    }

    private var compactStatusBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: displayManager.isConnected ? "tv.fill" : "rectangle.on.rectangle")
                Text(displayManager.isConnected ? "LIVE" : "DISPLAY")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(displayManager.isConnected ? Color.green : ARCTheme.accent, in: Capsule())

            HStack(spacing: 4) {
                Image(systemName: "network")
                Text(httpServer.isRunning ? ":\(httpServer.port)" : "OFF")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(httpServer.isRunning ? Color.green : ARCTheme.textTertiary, in: Capsule())

            Spacer()

            Button {
                showStagePreview = true
            } label: {
                Image(systemName: "eye.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(ARCTheme.accent)
            }
            .help("Preview — see exactly what the audience sees on the confidence monitor")
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 12)
        .background(ARCTheme.surface)
    }

    // MARK: - Main Timer Panel (iPad)

    /// The standalone run panel in modules (2026-09-24): NOW, TIMER (all the height left), TRANSPORT. The TIMER
    /// module's interior carries the state colour, as the whole panel used to.
    private var mainTimerPanel: some View {
        let sch = displayState.colorScheme
        return GeometryReader { geo in
            let h = geo.size.height, w = geo.size.width
            // ONE chain (2026-09-25: the elements must not break when the control monitor
            // resolution changes). NOW gets a clamped share, TRANSPORT and the talent row keep their natural
            // height, the TIMER takes what is left. Only when even the TIMER's floor does not fit does the
            // column scroll. It used to size NOW from the height alone and pin FLASH at 380 pt, so a small
            // window squeezed the countdown to nothing and a narrow one pushed the column off the right edge.
            let nowH = min(max(118, h * 0.2), 240)
            let compactNow = h < 860 || w < 900
            let talentSideBySide = w >= 1040
            let column = VStack(spacing: ARCTheme.paddingSmall) {
                operatorAlertBand
                CueInfoPanel(
                    currentCue: engine.currentCue,
                    nextCue: engine.nextCue,
                    compact: compactNow
                )
                .frame(maxWidth: .infinity)
                .frame(height: nowH)
                .arcModule(title: "Now", tint: ARCTheme.secOrange,
                           badge: ARCBandBadge(text: cueCountLabel, fill: ARCTheme.text0))

                VStack(spacing: 10) {
                    CountdownDisplay(
                        displayTime: engine.displayTime,
                        colorState: engine.colorState,
                        isOvertime: engine.isOvertime
                    )
                    .frame(maxHeight: .infinity)
                    .padding(.horizontal, ARCTheme.paddingLarge)
                    progressBarWithThresholds
                        .frame(height: 12)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 8)
                }
                .frame(maxWidth: .infinity, minHeight: 120, maxHeight: .infinity)
                .background(ZStack { sch.stageBackground; engine.colorState.backgroundColor(for: sch) })
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .arcModule(title: "Timer", tint: engine.isOvertime ? ARCTheme.arcRed : ARCTheme.secGreen)

                TransportControls(engine: engine)
                    .frame(maxWidth: .infinity)
                    .arcModule(title: "Transport", tint: ARCTheme.secOrange)

                // MESSAGE | FLASH (2026-09-24): the talent's controls, in the view the operator runs. Side by side when the
                // column holds both at full size, else FLASH goes under MESSAGE at the full width.
                if talentSideBySide {
                    HStack(alignment: .top, spacing: ARCTheme.paddingSmall) {
                        runMessageModule
                        runFlashModule.frame(width: min(380, w * 0.34))
                    }
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(spacing: ARCTheme.paddingSmall) {
                        runMessageModule
                        runFlashModule
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(ARCTheme.paddingSmall)
            .frame(width: w)

            // The fit test must see the column's OWN height: framed to the window first, it always "fit" and
            // then overflowed up under the header (seen at 960 x 600, 2026-09-25).
            ViewThatFits(in: .vertical) {
                column
                ScrollView(.vertical) { column }
            }
            .frame(width: w, height: h, alignment: .top)
        }
        .background(ARCTheme.background)
    }

    private var runMessageModule: some View {
        RunMessageModule()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .arcModule(title: "Message", tint: ARCTheme.secOrange,
                       badge: stageDirector.alert != nil ? ARCBandBadge(text: "ALERT UP", fill: ARCTheme.arcRed)
                            : (stageDirector.message != nil ? ARCBandBadge(text: "ON MONITOR", fill: ARCTheme.ink) : nil))
    }

    private var runFlashModule: some View {
        RunFlashModule()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .arcModule(title: "Flash", tint: ARCTheme.secCrimson,
                       badge: stageDirector.isFlashingForAttention ? ARCBandBadge(text: "FLASHING", fill: ARCTheme.ink) : nil)
    }

    /// The TEXT ALERT the presenter is reading, shown to the operator in the same red, above NOW.
    @ViewBuilder
    private var operatorAlertBand: some View {
        if let alert = stageDirector.alert {
            HStack(spacing: 8) {
                AlertBannerView(text: alert, fontSize: 18)
                Button { stageDirector.clearAlert() } label: {
                    Text("CLEAR").font(ARCTheme.mono(12, .heavy)).foregroundStyle(ARCTheme.ink)
                        .padding(.horizontal, 12).padding(.vertical, 10).background(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .help("Clear the ALERT from the confidence monitor")
            }
        }
    }

    #if os(macOS)
    /// LAYOUT: one labelled switch for how the run screen is laid out (2026-09-24: different layouts
    /// or options must be clear to the operator). The current one is lit; each says what it gives.
    private var layoutChip: some View {
        HStack(spacing: 6) {
            if !narrowTitleBar {
                Text("LAYOUT").font(ARCTheme.mono(10, .heavy)).foregroundStyle(ARCTheme.text1).fixedSize()
            }
            HStack(spacing: ARCTheme.bankGap) {
                ForEach(RunLayout.allCases, id: \.self) { layout in
                    let on = layout == (isDeck ? .deck : .run) && layout != .widget
                    Button {
                        if layout == .widget { ConsoleModeController.shared.set(.operate) }
                        else { runLayoutRaw = layout.rawValue }
                    } label: {
                        Text(layout.label)
                            .font(ARCTheme.mono(11, .heavy))
                            .foregroundStyle(on ? ARCTheme.ink : ARCTheme.text0)
                            .lineLimit(1).fixedSize()
                            .padding(.horizontal, narrowTitleBar ? 7 : 10).padding(.vertical, 5)
                            .background(on ? ARCTheme.secBlue : ARCTheme.surfaceLight)
                            .clipShape(UnevenRoundedRectangle(
                                topLeadingRadius: layout == .run ? ARCTheme.bankRadius : 0,
                                bottomLeadingRadius: layout == .run ? ARCTheme.bankRadius : 0,
                                bottomTrailingRadius: layout == .widget ? ARCTheme.bankRadius : 0,
                                topTrailingRadius: layout == .widget ? ARCTheme.bankRadius : 0))
                    }
                    .buttonStyle(.plain)
                    .disabled(layout == .run && displayMode.confidenceMode != nil)
                    .help(layout.tip)
                }
            }
        }
    }
    #endif

    // MARK: - Main Timer Panel (iPhone)

    @State private var showCompactMessages = false
    @State private var showCompactFlash = false

    private var mainTimerPanelCompact: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Stage mode selector
                stageModeControls
                    .padding(.top, 6)

                operatorAlertBand
                if stageDirector.stageMode == .timer {
                    CueInfoPanel(
                        currentCue: engine.currentCue,
                        nextCue: engine.nextCue,
                        compact: true
                    )
                    .padding(.top, ARCTheme.paddingSmall)

                    CountdownDisplayCompact(
                        displayTime: engine.displayTime,
                        colorState: engine.colorState,
                        isOvertime: engine.isOvertime
                    )
                    .frame(maxWidth: .infinity, minHeight: 140, maxHeight: 200)
                    .padding(.horizontal, ARCTheme.paddingMedium)

                    progressBarWithThresholds
                        .padding(.horizontal, 24)
                } else {
                    operatorModeContent
                        .padding(.top, ARCTheme.paddingSmall)
                }

                TransportControls(engine: engine)
                    .padding(.vertical, ARCTheme.paddingSmall)

                miniCueList

                // Collapsible messages
                compactSectionToggle(
                    title: "MESSAGES",
                    icon: "text.bubble",
                    isExpanded: $showCompactMessages
                )
                if showCompactMessages {
                    MessageControlPanel()
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                }

                // Collapsible flash
                compactSectionToggle(
                    title: "FLASH",
                    icon: "bolt.fill",
                    isExpanded: $showCompactFlash
                )
                if showCompactFlash {
                    FlashControlPanel()
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                }

                // HTTP status indicator
                compactHTTPIndicator
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
            }
        }
        .frame(maxWidth: .infinity)
        .background(
            ZStack {
                displayState.colorScheme.stageBackground
                engine.colorState.backgroundColor(for: displayState.colorScheme)
            }
        )
    }

    private func compactSectionToggle(title: String, icon: String, isExpanded: Binding<Bool>) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                isExpanded.wrappedValue.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                Text(title)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .tracking(1)
                Spacer()
                Image(systemName: isExpanded.wrappedValue ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10))
            }
            .foregroundStyle(ARCTheme.textTertiary)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private var compactHTTPIndicator: some View {
        Button {
            if httpServer.isRunning {
                httpServer.stop()
            } else {
                httpServer.start()
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "network")
                    .font(.system(size: 11))
                Text(httpServer.isRunning
                     ? "HTTP :\(httpServer.port)"
                     : "HTTP OFF")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(httpServer.isRunning ? Color.green : ARCTheme.textTertiary, in: Capsule())
        }
    }

    private var progressBarWithThresholds: some View {
        let cue = engine.currentCue
        let duration = Double(cue?.durationSeconds ?? 1)
        let warnFrac = duration > 0 ? Double(cue?.warningThreshold ?? 0) / duration : 0
        let dangerFrac = duration > 0 ? Double(cue?.dangerThreshold ?? 0) / duration : 0

        return ProgressBar(
            progress: engine.progress,
            colorState: engine.colorState,
            warningThreshold: warnFrac,
            dangerThreshold: dangerFrac
        )
    }

    private var miniCueList: some View {
        VStack(spacing: 4) {
            // Compact offset indicator for iPhone
            if engine.isScheduledShow && engine.showStartedAt != nil {
                HStack(spacing: 6) {
                    Text(engine.showOffsetDisplay)
                        .font(.system(size: 18, weight: .heavy, design: .monospaced))
                    Text(engine.offsetStatus.label)
                        .font(.system(size: 12, weight: .bold))
                        .tracking(1)
                }
                .foregroundStyle(engine.offsetStatus.color)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(engine.offsetStatus.color.opacity(0.18), in: Capsule())
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(engine.cues.enumerated()), id: \.element.id) { index, cue in
                        Button {
                            engine.goToCue(at: index)
                        } label: {
                            Text(cue.title)
                                .font(.system(size: 12, weight: index == engine.currentCueIndex ? .bold : .regular))
                                .foregroundStyle(index == engine.currentCueIndex ? ARCTheme.accent : ARCTheme.textTertiary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    index == engine.currentCueIndex ? ARCTheme.surface : .clear,
                                    in: Capsule()
                                )
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
        }
    }

    // MARK: - Session Log Export

    private func exportSessionLog() {
        guard let data = engine.exportSessionLog() else { return }
        #if os(macOS)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        let showName = show.name.replacingOccurrences(of: " ", with: "_")
        panel.nameFieldStringValue = "\(showName)_session_log.csv"
        if panel.runModal() == .OK, let url = panel.url {
            try? data.write(to: url)
        }
        #endif
    }
}

// MARK: - Control Deck Grid

private extension View {
    /// One cell of the control deck: `columns` columns wide, and as tall as the row it is in. A nil unit
    /// means the console is too narrow for the grid, so the module keeps its natural width.
    func deckCell(_ unit: CGFloat?, _ columns: Int, gap: CGFloat = 8) -> some View {
        let width = unit.map { $0 * CGFloat(columns) + gap * CGFloat(columns - 1) }
        return self.frame(width: width).frame(maxHeight: .infinity, alignment: .top)
    }

    /// A module's CONTENT fills its box top-left, so the box grows to the row's height rather than floating,
    /// content-sized, in the middle of a taller cell (OUTPUTS beside STAGE MESSAGES, 2026-09-17). Applied
    /// BEFORE `arcModule`. A hugging module (the older layouts) is left content-sized.
    func deckFill(_ hugging: Bool = false) -> some View {
        self.frame(maxHeight: hugging ? nil : .infinity, alignment: .topLeading)
    }
}

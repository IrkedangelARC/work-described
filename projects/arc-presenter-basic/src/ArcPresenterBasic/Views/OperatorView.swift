//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI
import AppKit

struct OperatorView: View {
    @Environment(DeckSession.self) private var session
    @Environment(DisplayManager.self) private var display
    @Environment(\.openWindow) private var openWindow
    @State private var jumpText: String = ""
    @FocusState private var jumpFocused: Bool

    private var activeEngine: SlideEngine { session.activeEngine }
    private var activeCache: PageCache { session.activeCache }
    private var inBrowse: Bool { session.mode == .browse }

    var body: some View {
        VStack(spacing: 0) {
            modeBar
            Divider()
            previewArea
            counterRow
            Divider()
            filmstripArea
            Divider()
            navRow
            Divider()
            deckRow
            Divider()
            outputRow
            statusBar
        }
        .frame(minWidth: 1100, minHeight: 820)
        .background(Color(white: 0.08))
        .preferredColorScheme(.dark)
        .onAppear {
            display.requestProgramWindow = { openWindow(id: "program-output") }
            session.liveCache.currentPageIndex = session.liveEngine.currentIndex
        }
        .onChange(of: session.liveEngine.currentIndex) { _, newValue in
            session.liveCache.currentPageIndex = newValue
        }
        .onChange(of: session.browseEngine?.currentIndex ?? -1) { _, newValue in
            if newValue >= 0 { session.browseCache?.currentPageIndex = newValue }
        }
    }

    @ViewBuilder
    private var previewArea: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("CURRENT")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55))
                SlidePreview(engine: activeEngine, cache: activeCache)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 12) {
                NextSlidePreview(engine: activeEngine, cache: activeCache)
                ClockView()
                Spacer(minLength: 0)
            }
            .frame(maxWidth: 520)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private var filmstripArea: some View {
        if activeEngine.isLoaded && activeEngine.pageCount > 1 {
            Filmstrip(engine: activeEngine, cache: activeCache)
        } else {
            EmptyView()
        }
    }

    // MARK: - Mode Tabs (LIVE / BROWSE)

    @ViewBuilder
    private var modeBar: some View {
        HStack(spacing: 8) {
            tabButton(label: "LIVE", isActive: session.mode == .live, action: { session.switchToLive() })
                .help("View and control the deck on the program output  ( Tab )")

            if session.hasBrowseDeck {
                tabButton(label: "BROWSE", isActive: session.mode == .browse, action: { session.switchToBrowse() })
                    .help("Preview a different PDF without changing the program output  ( Tab )")
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func tabButton(label: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(isActive ? Color.accentColor.opacity(0.85) : Color.white.opacity(0.08))
                .foregroundStyle(isActive ? Color.black : Color.white.opacity(0.85))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Counter

    @ViewBuilder
    private var counterRow: some View {
        HStack {
            Text(activeEngine.isLoaded ? activeEngine.displayLabel : "—")
                .font(.system(size: 16, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
            Text(activeEngine.fileName)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Nav Row

    @ViewBuilder
    private var navRow: some View {
        HStack(spacing: 8) {
            navButton("⏮ First", action: { activeEngine.goToFirst() })
                .keyboardShortcut(.leftArrow, modifiers: .command)
                .help("Jump to first slide  ( ⌘← )")
                .disabled(!activeEngine.isLoaded)

            navButton("◀ Prev", action: { activeEngine.previous() })
                .help("Go back one slide  ( ← )")
                .disabled(!activeEngine.hasPrevious)

            navButton("Next ▶", action: { activeEngine.next() })
                .help("Advance one slide  ( → )")
                .disabled(!activeEngine.hasNext)

            navButton("Last ⏭", action: { activeEngine.goToLast() })
                .keyboardShortcut(.rightArrow, modifiers: .command)
                .help("Jump to last slide  ( ⌘→ )")
                .disabled(!activeEngine.isLoaded)

            Divider().frame(height: 24)

            blackButton

            Divider().frame(height: 24)

            jumpField
            Button("Go") {
                applyJump()
            }
            .help("Jump to the page number entered in the field")
            .disabled(!activeEngine.isLoaded || jumpText.isEmpty)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func navButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .frame(minWidth: 76)
        }
    }

    @ViewBuilder
    private var blackButton: some View {
        Button(action: { activeEngine.toggleBlack() }) {
            Text(activeEngine.isBlack ? "■ UNBLACK" : "■ Black")
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(activeEngine.isBlack ? Color.black : Color.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(activeEngine.isBlack ? Color.accentColor : Color.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .keyboardShortcut("b", modifiers: [])
        .help(inBrowse
              ? "Toggle black screen on output  ( B ).  Disabled in Browse mode — switch to LIVE to use."
              : "Toggle black screen on output  ( B )")
        .disabled(inBrowse || !session.liveEngine.isLoaded)
    }

    @ViewBuilder
    private var jumpField: some View {
        TextField("Page #", text: $jumpText)
            .textFieldStyle(.roundedBorder)
            .frame(width: 80)
            .focused($jumpFocused)
            .help("Type a page number and press Enter to jump")
            .disabled(!activeEngine.isLoaded)
            .onSubmit { applyJump() }
    }

    private func applyJump() {
        guard let page = Int(jumpText) else {
            jumpText = ""
            return
        }
        activeEngine.jumpTo(page: page)
        jumpText = ""
        jumpFocused = false
    }

    // MARK: - Deck Row (Open / Send / Close Browse)

    @ViewBuilder
    private var deckRow: some View {
        HStack(spacing: 8) {
            Button("Open PDF…") {
                presentOpenPanel()
            }
            .keyboardShortcut("o", modifiers: .command)
            .help("Open a PDF file. If a live deck is already loaded, it opens in BROWSE; otherwise it goes straight to LIVE.  ( ⌘O )")

            if session.hasBrowseDeck && session.mode == .browse {
                Button("Send to Output ▸") {
                    session.sendBrowseToOutput()
                }
                .keyboardShortcut(.return, modifiers: .command)
                .help("Replace the live deck with the browse deck. Output will jump to page 1.  ( ⌘↩ )")
                .disabled(!(session.browseEngine?.isLoaded ?? false))

                Button("× Close Browse") {
                    session.closeBrowse()
                }
                .help("Discard the browse deck and return to LIVE view")
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Output Row (Display picker + Start/Stop)

    @ViewBuilder
    private var outputRow: some View {
        HStack(spacing: 8) {
            Text("Display:")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.white.opacity(0.65))

            Picker("Display", selection: displayBinding) {
                Text("— None —").tag(CGDirectDisplayID?.none)
                ForEach(display.availableScreens) { screen in
                    Text(screenLabel(screen)).tag(Optional(screen.id))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 320)
            .help("Pick which connected display the fullscreen output goes to")

            if display.isProgramConnected {
                Button("■ Stop Output") {
                    display.closeOutput()
                }
                .keyboardShortcut(.escape, modifiers: [])
                .help("Close the program output. The operator window stays open.  ( Esc )")
            } else {
                Button("▶ Start Output") {
                    if display.programScreenID == nil {
                        display.autoAssignFirstExternal()
                    }
                    display.openOutput()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .help("Open the fullscreen program window on the selected display  ( ⌘⇧O )")
                .disabled(display.programScreenID == nil && display.externalScreens.isEmpty)
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var displayBinding: Binding<CGDirectDisplayID?> {
        Binding(
            get: { display.programScreenID },
            set: { newValue in
                if let id = newValue, let screen = display.availableScreens.first(where: { $0.id == id }) {
                    display.assign(screen)
                } else {
                    display.unassign()
                }
            }
        )
    }

    private func screenLabel(_ s: ScreenIdentity) -> String {
        let tag = s.isBuiltIn ? "Built-in" : "External"
        return "[\(s.index + 1)] \(s.localizedName) — \(s.resolution) (\(tag))"
    }

    // MARK: - Status Bar

    @ViewBuilder
    private var statusBar: some View {
        HStack(spacing: 16) {
            statusPill(label: "LIVE", value: session.liveEngine.isLoaded ? session.liveEngine.fileName : "—")
            if session.hasBrowseDeck {
                statusPill(label: "BROWSE", value: session.browseEngine?.fileName ?? "—")
            }
            Spacer()
            statusPill(label: "OUTPUT", value: outputStatusText, accent: outputStatusColor)
            if let msg = display.statusMessage {
                Text(msg)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.yellow.opacity(0.8))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.4))
    }

    private var outputStatusText: String {
        if display.isProgramConnected { return "ON" }
        if !display.externalScreens.isEmpty && display.programScreenID == nil { return "OFF" }
        if display.externalScreens.isEmpty { return "DISCONNECTED" }
        return "OFF"
    }

    private var outputStatusColor: Color {
        if display.isProgramConnected { return .green }
        if display.externalScreens.isEmpty { return .red }
        return .secondary
    }

    private func statusPill(label: String, value: String, accent: Color = .secondary) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(accent)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    // MARK: - Open Panel

    private func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if panel.runModal() == .OK, let url = panel.url {
            session.renderTargetSize = display.renderTargetSize ?? PageCache.maxRenderSize
            _ = session.openPDF(url: url)
        }
    }
}

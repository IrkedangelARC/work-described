//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI
import AppKit
import QuickLookThumbnailing

/// ONE chrome for every Capture screen (docs/PLAN_capture_gui.md, phase 1): the tab strip, the header
/// strip, the footer row of hugging groups, and the STATUS tiles. Built once, used by CAPTURE (setup,
/// monitor, complete) and SHOW, so alignment comes from identical construction, not matched numbers.
extension ARCTheme {
    /// The footer's one row height, shared by every group (Presenter uses the same figure).
    static let footerRowH: CGFloat = 52
    static let tabStripH: CGFloat = 30
    /// The window never goes below this, one minimum for every tab so a tab switch never clips. It fits a
    /// MacBook Pro at its default 1512 x 982 with the Dock showing (2026-09-23, the operator: "real, robust resizing
    /// adjustments for different resolutions"): 900 pt of content made a 932 pt window, taller than that
    /// screen's visible frame. Below `roomyH` / `roomyW` the screens go compact (shorter log and ACTIVITY,
    /// narrower SHOW and REVIEW columns, a scrolling left column) instead of clipping.
    static let windowMinW: CGFloat = 1200
    static let windowMinH: CGFloat = 720
    /// Content height from which the screens lay out at full size.
    static let roomyH: CGFloat = 900
    /// Content width from which the SHOW and REVIEW side columns take their full widths.
    static let roomyW: CGFloat = 1440
    /// The rail width on the monitor and setup screens (fixed tools; the picture flexes).
    static let railW: CGFloat = 380
}

/// The screen's state, worded for the header chip.
enum CaptureScreenState {
    case idle, ready, capturing, complete, error, working

    var word: String {
        switch self {
        case .idle: "IDLE"
        case .ready: "READY"
        case .capturing: "CAPTURING"
        case .complete: "COMPLETE"
        case .error: "ERROR"
        case .working: "WORKING"
        }
    }
    var color: Color {
        switch self {
        case .idle: ARCTheme.textTertiary
        case .ready: ARCTheme.readyGreen
        case .capturing: ARCTheme.liveRed
        case .complete: ARCTheme.readyGreen
        case .error: ARCTheme.liveRed
        case .working: ARCTheme.warn
        }
    }
}

// MARK: - Tab strip

/// CAPTURE | SHOW, a 30 pt band on the surface below the title bar (it used to sit half under it).
struct CaptureTabStrip: View {
    @Binding var tab: Int
    /// Rows to decide, shown on the REVIEW tab's title.
    var reviewOpen: Int = 0
    static let titles = ["CAPTURE", "SHOW", "REVIEW"]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(Self.titles.enumerated()), id: \.offset) { i, t in
                Button(action: { tab = i }) {
                    HStack(spacing: 6) {
                        Text(t).font(ARCTheme.mono(12, .heavy))
                        if i == 2, reviewOpen > 0 {
                            Text("\(reviewOpen)").font(ARCTheme.mono(10, .heavy)).foregroundStyle(ARCTheme.ink)
                                .padding(.horizontal, 5).padding(.vertical, 1).background(ARCTheme.warn).cornerRadius(3)
                        }
                    }
                    .foregroundStyle(tab == i ? .white : ARCTheme.textSecondary)
                    .padding(.horizontal, 18)
                    .frame(height: ARCTheme.tabStripH)
                    .background(tab == i ? ARCTheme.arcRed : Color.clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .frame(height: ARCTheme.tabStripH)
        .background(ARCTheme.surface)
    }
}

// MARK: - Header strip

/// The ARC mark, the screen's name, its subject, and the STATE chip; a clock while a run is on.
struct CaptureHeader<Trailing: View>: View {
    let screen: String
    let subject: String?
    let state: CaptureScreenState
    var stateDetail: String? = nil
    @ViewBuilder var trailing: Trailing

    init(screen: String, subject: String?, state: CaptureScreenState, stateDetail: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.screen = screen; self.subject = subject; self.state = state; self.stateDetail = stateDetail; self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 12) {
            Image("ARCLogo").resizable().aspectRatio(contentMode: .fit).frame(height: 22)
            Text("CAPTURE").font(ARCTheme.mono(14, .heavy)).foregroundStyle(ARCTheme.textSecondary).tracking(1.2)
            Text(screen).font(ARCTheme.mono(14, .heavy)).foregroundStyle(ARCTheme.textPrimary)
            if let subject, !subject.isEmpty {
                Text(subject).font(ARCTheme.mono(14, .heavy)).foregroundStyle(ARCTheme.arcRed).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 10)
            trailing
            HStack(spacing: 6) {
                Circle().fill(state.color).frame(width: 9, height: 9)
                Text(stateDetail.map { "\(state.word)  \($0)" } ?? state.word).font(ARCTheme.mono(12, .heavy)).foregroundStyle(ARCTheme.textPrimary).lineLimit(1)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(ARCTheme.surfaceLight).cornerRadius(ARCTheme.cornerRadius)
        }
        .padding(.horizontal, ARCTheme.paddingMedium).padding(.vertical, 8)
        .background(ARCTheme.surface)
    }
}

extension CaptureHeader where Trailing == EmptyView {
    init(screen: String, subject: String?, state: CaptureScreenState, stateDetail: String? = nil) {
        self.init(screen: screen, subject: subject, state: state, stateDetail: stateDetail) { EmptyView() }
    }
}

// MARK: - Footer row

/// Hugging groups of ONE row height, side by side on the ground, like Presenter's footer.
struct CaptureFooter<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: ARCTheme.paddingSmall) { content }
            .frame(height: ARCTheme.footerRowH + ARCTheme.moduleChromeH(scale: 1))
            .padding(.horizontal, ARCTheme.paddingMedium).padding(.bottom, ARCTheme.paddingMedium)
    }
}

/// A footer group's body row: its controls, one row high, so every group is the same height.
struct FooterRow<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        HStack(spacing: 6) { content }.frame(height: ARCTheme.footerRowH - 2 * ARCTheme.modulePad)
    }
}

// MARK: - STATUS tiles

/// The readiness checks as fixed-width tiles (a name over a state), the whole story behind the glyph.
struct ReadinessTiles: View {
    @Bindable var readiness: Readiness

    /// Short names and the widest state each tile can show, so the group never changes width.
    static let tiles: [(id: String, name: String, widest: String)] = [
        ("screen", "SCREEN", "DENIED"), ("ax", "ACCESS", "DENIED"), ("automation", "CONTROL", "REFUSED"), ("display", "DISPLAY", "PGM ON IT"),
        ("ppt", "POWERPOINT", "MISSING"), ("key", "KEYNOTE", "MISSING"), ("chrome", "CHROME", "MISSING"),
        ("profile", "PROFILE", "SIGN IN"), ("presenter", "PRESENTER", "NOT RUNNING"),
    ]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Self.tiles, id: \.id) { t in
                let check = t.id == "automation" ? readiness.automation : readiness.checks.first { $0.id == t.id }
                ARCStatusTile(name: t.name, state: Self.state(t.id, check), level: Self.level(check), widest: (t.name, t.widest))
                    .help(check?.hint ?? "")
            }
        }
    }

    static func state(_ id: String, _ c: Readiness.Check?) -> String {
        guard let c else { return "…" }
        switch id {
        case "screen", "ax": return c.ok ? "GRANTED" : "DENIED"
        case "automation": return c.ok ? "GRANTED" : (c.hint.hasSuffix("REFUSED") ? "REFUSED" : "ASK")
        case "display": return c.ok ? "TWO" : (c.hint.contains("Presenter") ? "PGM ON IT" : "ONE ONLY")
        case "ppt", "key", "chrome": return c.ok ? "INSTALLED" : "MISSING"
        case "profile": return c.ok ? "SIGNED IN" : "SIGN IN"
        case "presenter": return c.ok ? "RUNNING" : "NOT RUNNING"
        default: return c.ok ? "OK" : "NO"
        }
    }

    static func level(_ c: Readiness.Check?) -> ARCStatusLevel {
        guard let c else { return .off }
        return c.ok ? .ok : (c.required ? .bad : .warn)
    }
}

// MARK: - Launch

/// What a GUI launch was asked for on the command line (`--deck PATH [--begin]`), taken once by the
/// setup screen when it appears (an App struct is made more than once at launch, so the session touched
/// in `init` is not always the one the scene shows), and the ONE readiness every screen reads.
@MainActor enum CaptureLaunch {
    static var deck: URL?
    static var begin = false
    static func take() -> (URL, Bool)? { guard let d = deck else { return nil }; deck = nil; return (d, begin) }
    /// Checked every few seconds; the setup screen's STATUS tiles and the READINESS window read it.
    static let readiness = Readiness()
}

// MARK: - Window sizing

/// The window never sits below the content's minimum: SwiftUI's own propagation lost the SHOW tab's
/// minimum through the tab switch (the page overflowed the title bar at 900 pt, 2026-09-19).
@MainActor
enum CaptureWindowSizing {
    /// `--window X,Y,W,H` (top-left origin in global screen points): applied once, at launch.
    static var requestedFrame: CGRect?

    /// At launch and on every tab switch: the minimum set, the asked-for frame applied once, and the window
    /// kept inside its screen's visible frame (menu bar and Dock excluded), a restored frame from a bigger
    /// display included.
    static func enforce() {
        guard let window = mainWindow else { return }
        observeScreens()
        let min = CGSize(width: ARCTheme.windowMinW, height: ARCTheme.windowMinH)
        window.contentMinSize = min
        if let r = requestedFrame {
            requestedFrame = nil
            // Global points, top-left origin (as System Events and CGEvent count) to AppKit's bottom-left.
            let screenH = NSScreen.screens.first.map { $0.frame.maxY } ?? 0
            window.setFrame(NSRect(x: r.minX, y: screenH - r.minY - r.height, width: r.width, height: r.height), display: true)
            DebugLog.log("App", "window placed at \(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))x\(Int(r.height)) (asked)")
        }
        let frame = window.frame
        let chrome = CGSize(width: frame.width - window.contentRect(forFrameRect: frame).width,
                            height: frame.height - window.contentRect(forFrameRect: frame).height)
        let minFrame = CGSize(width: min.width + chrome.width, height: min.height + chrome.height)
        guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        let fitted = fit(frame, minimum: minFrame, in: visible)
        if fitted != frame {
            window.setFrame(fitted, display: true, animate: false)
            DebugLog.log("App", "window fitted \(Int(frame.width))x\(Int(frame.height)) -> \(Int(fitted.width))x\(Int(fitted.height)) (visible \(Int(visible.width))x\(Int(visible.height)))")
        }
    }

    /// `frame` (AppKit, bottom-left origin) grown to `minimum`, shrunk to `visible`, then moved inside it. A
    /// screen smaller than the minimum keeps the minimum with the TOP edge on screen, so the title bar and
    /// the tab strip stay reachable. Pure, so it is tested without a window.
    nonisolated static func fit(_ frame: CGRect, minimum: CGSize, in visible: CGRect) -> CGRect {
        var f = frame
        f.size.width = max(minimum.width, min(f.width, visible.width))
        let h = max(minimum.height, min(f.height, visible.height))
        f.origin.y += f.height - h          // keep the top edge where it was
        f.size.height = h
        if f.maxX > visible.maxX { f.origin.x = visible.maxX - f.width }
        if f.minX < visible.minX { f.origin.x = visible.minX }
        if f.minY < visible.minY { f.origin.y = visible.minY }
        if f.maxY > visible.maxY { f.origin.y = visible.maxY - f.height }
        return f.integral
    }

    private static var mainWindow: NSWindow? {
        NSApplication.shared.windows.first(where: { $0.title == "ARC Capture" && $0.isVisible })
            ?? NSApplication.shared.windows.first(where: { $0.contentView != nil && !($0 is NSPanel) && $0.isVisible && !isControlWindow($0) })
    }

    private static func isControlWindow(_ w: NSWindow) -> Bool {
        [CaptureWindows.options.title, CaptureWindows.readiness.title, CaptureWindows.log.title].contains(w.title)
    }

    /// A display unplugged, a resolution changed, the Dock moved: the app's windows are put back inside their
    /// screens' visible frames once the burst of notifications settles.
    private static var screenObserver: NSObjectProtocol?
    private static var pendingRefit: DispatchWorkItem?

    private static func observeScreens() {
        guard screenObserver == nil else { return }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                pendingRefit?.cancel()
                let work = DispatchWorkItem { MainActor.assumeIsolated { refit() } }
                pendingRefit = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
            }
        }
    }

    private static func refit() {
        enforce()
        for w in NSApplication.shared.windows where w.isVisible && isControlWindow(w) {
            guard let v = (w.screen ?? NSScreen.main)?.visibleFrame else { continue }
            let f = fit(w.frame, minimum: .zero, in: v)
            if f != w.frame { w.setFrame(f, display: true, animate: false) }
        }
    }
}

// MARK: - Deck picture

/// The chosen deck as Quick Look draws it: the picture of the DECK module before a run.
struct DeckThumb: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image { Image(nsImage: image).resizable().aspectRatio(contentMode: .fit) }
            else {
                VStack(spacing: 6) {
                    Image(systemName: url.scheme?.hasPrefix("http") == true ? "link" : "doc.richtext").font(.system(size: 40)).foregroundStyle(ARCTheme.textTertiary)
                    Text(url.lastPathComponent).font(ARCTheme.mono(12, .regular)).foregroundStyle(ARCTheme.textTertiary).lineLimit(1)
                }
            }
        }
        .task(id: url) {
            image = nil
            guard url.isFileURL else { return }
            let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 1280, height: 720), scale: 2, representationTypes: .thumbnail)
            image = (try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request))?.nsImage
        }
    }
}

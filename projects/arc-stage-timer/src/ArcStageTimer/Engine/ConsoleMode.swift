//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

#if os(macOS)
import AppKit
import Observation

/// How the operator is using the console (2026-09-17: "as the operator we dont need a big timer display
/// at all... one half of the display area when programming and a floating widget when doing basic operations").
///
/// PROGRAM: the window on half a display, the cue list beside a run panel whose timer is laptop-sized.
/// OPERATE: a floating widget with the timer, transport, flash keys and messages, and the console window
/// ordered out behind it. The mode is not remembered: a launch is PROGRAM unless `--console operate` says so.
enum ConsoleMode: String, CaseIterable, Sendable {
    case program, operate
    var label: String { rawValue.uppercased() }
}

/// Which half of its display the PROGRAM window takes. Remembered.
enum ConsoleHalf: String, Sendable { case left, right }

@MainActor
@Observable
final class ConsoleModeController {
    static let shared = ConsoleModeController()

    private(set) var mode: ConsoleMode = .program
    var half: ConsoleHalf {
        didSet { UserDefaults.standard.set(half.rawValue, forKey: "consoleHalf") }
    }
    /// The console window while the widget is up. MINIATURIZED, not closed and not ordered out: the run screen
    /// keeps its state and comes straight back, the Dock shows the operator a way back, and a minimized window
    /// is restored at the next launch, where an ordered-out one is not (a run killed in OPERATE came back with
    /// no console at all, 2026-09-17). A closed SwiftUI window lingers in the window list and cannot be trusted.
    @ObservationIgnored private weak var hiddenConsole: NSWindow?

    init() {
        half = ConsoleHalf(rawValue: UserDefaults.standard.string(forKey: "consoleHalf") ?? "") ?? .right
        if let v = StageTimerLaunch.value(after: "--console"), let m = ConsoleMode(rawValue: v.lowercased()) { mode = m }
        publish()
    }

    func set(_ new: ConsoleMode) {
        mode = new
        apply()
        publish()
    }

    func toggle() { set(mode == .program ? .operate : .program) }

    /// Put the windows where the mode says. Calling it again converges.
    func apply() {
        switch mode {
        case .operate:
            // The widget is a scene: only a view can open it (ContentView listens).
            NotificationCenter.default.post(name: .openOperateWidget, object: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                MainActor.assumeIsolated {
                    Self.configureWidgetWindow()
                    if let console = DisplayPlacement.windows(for: .control).first {
                        self.hiddenConsole = console
                        console.miniaturize(nil)
                    }
                }
            }
        case .program:
            for w in DisplayPlacement.windows(for: .widget) { w.close() }
            if let console = hiddenConsole {
                console.deminiaturize(nil)
                console.makeKeyAndOrderFront(nil)
                hiddenConsole = nil
            } else if DisplayPlacement.windows(for: .control).isEmpty {
                StageAppDelegate.ensureControlWindow()
            }
            NSApp.activate(ignoringOtherApps: true)
        }
        StageLog.log("console: \(mode.label)")
    }

    /// The widget floats, has no title bar furniture, is dragged by its body, and remembers where it was.
    /// First time out it sits at the top right of the display the console is on.
    static func configureWidgetWindow() {
        for w in DisplayPlacement.windows(for: .widget) {
            w.level = .floating
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            w.styleMask.insert(.fullSizeContentView)     // or the hidden title bar still leaves its empty strip on top
            w.isMovableByWindowBackground = true
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { w.standardWindowButton(b)?.isHidden = true }
            w.isExcludedFromWindowsMenu = false
            // NOT restored at the next launch: a restored widget came up on the primary display, empty, with
            // no console behind it (2026-09-17). A launch is PROGRAM; the widget is asked for.
            w.isRestorable = false
            // On the console's display, always. The primary is never taken by accident (DisplayPlacement).
            let home = DisplayPlacement.windows(for: .control).first?.screen
                ?? NSScreen.screens.first { DisplayPlacement.uuid(of: $0) == ArcStageTimerApp.sharedPlacement.assignments[.control] }
                ?? NSScreen.screens.dropFirst().first
                ?? NSScreen.screens.first
            // The autosave name FIRST: setting it restores the saved frame, so a move made before it was
            // undone and the widget went back to the primary (2026-09-17). Then, if that frame is on the
            // wrong display, the move, which is what gets saved.
            w.setFrameAutosaveName("ARCOperateWidget")
            if let home, w.screen != home {
                let v = home.visibleFrame
                w.setFrameOrigin(NSPoint(x: v.maxX - w.frame.width - 24, y: v.maxY - w.frame.height - 24))
            }
            w.orderFrontRegardless()
        }
    }

    private func publish() { ConsoleSnapshot.shared.set(mode.rawValue, half: half.rawValue) }
}

/// The mode, readable from the HTTP server's queue.
final class ConsoleSnapshot: @unchecked Sendable {
    static let shared = ConsoleSnapshot()
    private let lock = NSLock()
    private var _mode = "program"
    private var _half = "right"
    var mode: String { lock.lock(); defer { lock.unlock() }; return _mode }
    var half: String { lock.lock(); defer { lock.unlock() }; return _half }
    func set(_ mode: String, half: String) { lock.lock(); _mode = mode; _half = half; lock.unlock() }
}

extension Notification.Name {
    /// Asks the scene layer to open the OPERATE widget (the controller cannot call `openWindow` itself).
    static let openOperateWidget = Notification.Name("ARCStageTimerOpenOperateWidget")
}
#endif

//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import AppKit

/// What the program output is showing: Presenter's own deck, or a natively
/// running PowerPoint show parked under the program shield.
/// V4 build plan, docs/V4_SWITCHER.md step 2.
enum LiveSource: String {
    case deck
    case powerpoint
    /// Any other app's window, parked and captured (WindowSource, 2026-09-18).
    case window

    var isExternal: Bool { self != .deck }
}

/// Anything the clicker can drive. DeckManager and PowerPointSource both conform.
@MainActor
protocol LiveNavigable: AnyObject {
    func liveNext()
    func livePrevious()
    func liveGoToFirst()
    func liveGoToLast()
}

extension DeckManager: LiveNavigable {}

/// The one entry point for every "drive the live output" command: the local key
/// monitor, the global clicker tap, the Presentation menu and the control API
/// all call this, never DeckManager directly, so the clicker follows whatever
/// is live.
///
/// Architecture B (2026-09-16): Presenter keeps focus and forwards the
/// clicker to PowerPoint, so the control window stays live on the work monitor.
@MainActor
@Observable
final class SourceRouter {
    /// Set by the V4 switch (build plan item 3). Defaults to the deck, so V3
    /// behaviour is unchanged until something switches.
    var live: LiveSource = .deck

    private let deck: LiveNavigable
    private let powerPoint: LiveNavigable
    private let window: LiveNavigable
    private let deckBlack: () -> Void
    /// Bundle ID of the app whose window is parked, for the double-key gate below.
    private let windowBundleID: () -> String?
    /// Set by SwitchEngine: black while PowerPoint is live is Presenter's own
    /// program window, so it belongs to the switch, not to PowerPoint.
    var powerPointBlack: (() -> Void)?
    private let frontmostBundleID: () -> String?
    /// Does the live window's app take the clicker? False for a Zoom window (PLAN_zoom_source step 2,
    /// 2026-09-20: the remote watches the share of the DECK, so the keys drive the deck while Zoom is
    /// on program). `WindowSource.clickerDrivesWindow` in the app.
    private let windowKeepsKeys: () -> Bool

    init(deck: LiveNavigable,
         powerPoint: LiveNavigable,
         window: LiveNavigable? = nil,
         deckBlack: @escaping () -> Void,
         windowBundleID: @escaping () -> String? = { nil },
         windowKeepsKeys: @escaping () -> Bool = { true },
         frontmostBundleID: @escaping () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }) {
        self.deck = deck
        self.powerPoint = powerPoint
        self.window = window ?? NoSource()
        self.deckBlack = deckBlack
        self.windowBundleID = windowBundleID
        self.windowKeepsKeys = windowKeepsKeys
        self.frontmostBundleID = frontmostBundleID
    }

    /// A live window whose keys go to the deck (a Zoom participant on program).
    private var windowDrivesDeck: Bool { live == .window && !windowKeepsKeys() }

    private var target: LiveNavigable {
        switch live {
        case .deck: return deck
        case .powerpoint: return powerPoint
        case .window: return windowKeepsKeys() ? window : deck
        }
    }

    /// For the show log: where a command actually went.
    private var targetName: String { windowDrivesDeck ? "deck (window on program)" : live.rawValue }

    /// `origin`: who asked (key, tap, api, menu), for the show log.
    func next(origin: String = "key")     { ShowLog.log("next (\(origin)) -> \(targetName)"); SlideTrackRecorder.asking(origin) { target.liveNext() } }
    func previous(origin: String = "key") { ShowLog.log("previous (\(origin)) -> \(targetName)"); SlideTrackRecorder.asking(origin) { target.livePrevious() } }
    func first(origin: String = "key")    { ShowLog.log("first (\(origin)) -> \(targetName)"); SlideTrackRecorder.asking(origin) { target.liveGoToFirst() } }
    func last(origin: String = "key")     { ShowLog.log("last (\(origin)) -> \(targetName)"); SlideTrackRecorder.asking(origin) { target.liveGoToLast() } }

    /// Black follows the live source. Without a switch engine wired, black on an
    /// external source is refused rather than blacking the deck nobody can see.
    @discardableResult
    func toggleBlack() -> Bool {
        guard !live.isExternal else {
            guard let powerPointBlack else {
                NSLog("ARC Presenter: black on a PowerPoint source needs the switch engine")
                return false
            }
            powerPointBlack()
            return true
        }
        deckBlack()
        return true
    }

    /// Commands that only mean something for a deck: goto, shuttle, J/K/L.
    var acceptsDeckOnlyCommands: Bool { live == .deck || windowDrivesDeck }

    /// Show-level CLICKER OFF (PLAN_zoom_source step 1b, drill 2026-09-20 finding 3: the global tap
    /// advanced the live deck four times while the operator typed in Zoom). OFF drops the GLOBAL tap
    /// only; keys pressed with Presenter frontmost, the API and the menu still drive the deck, because
    /// those are the operator's intent. Not persisted: a relaunch is a new show, clicker ON.
    var globalClickerOn = true {
        didSet { if oldValue != globalClickerOn { ShowLog.log("clicker \(globalClickerOn ? "ON" : "OFF") (global tap \(globalClickerOn ? "drives the live source" : "dropped"))"); droppedSinceLog = 0 } }
    }
    private var droppedSinceLog = 0

    /// The global clicker tap only fires when Presenter is NOT frontmost. If the
    /// live source's own app is frontmost it already received the key, so
    /// forwarding it too would advance twice.
    func globalNext()     { guard tapAllowed("next") else { return }; if !liveAppHasKeys { next(origin: "tap") } }
    func globalPrevious() { guard tapAllowed("previous") else { return }; if !liveAppHasKeys { previous(origin: "tap") } }

    private func tapAllowed(_ what: String) -> Bool {
        if globalClickerOn { return true }
        droppedSinceLog += 1
        if droppedSinceLog <= 3 || droppedSinceLog % 50 == 0 { ShowLog.log("\(what) (tap) dropped: clicker OFF (\(droppedSinceLog) so far)") }
        return false
    }

    private var liveAppHasKeys: Bool {
        switch live {
        case .deck: return false
        case .powerpoint: return frontmostBundleID() == PowerPointSource.bundleID
        case .window: return windowKeepsKeys() && frontmostBundleID() != nil && frontmostBundleID() == windowBundleID()
        }
    }
}

/// The router's stand-in when no window source is wired (tests, early boot).
@MainActor
private final class NoSource: LiveNavigable {
    func liveNext() {}
    func livePrevious() {}
    func liveGoToFirst() {}
    func liveGoToLast() {}
}

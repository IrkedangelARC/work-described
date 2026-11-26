//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

#if os(macOS)
import Foundation
import CoreGraphics

/// A connected display as the operator sees it: its number, its name, its pixel resolution, where it sits.
/// Pure data (no AppKit), so the assignment rules below can be tested without a single screen attached.
struct DisplayInfo: Identifiable, Equatable, Codable, Sendable {
    /// The display's UUID: stable across reboots, cable swaps and re-arrangement. Its index is not.
    let id: String
    let name: String
    /// 1-based, in NSScreen order (1 is the menu-bar display).
    let index: Int
    /// Global AppKit frame in points (origin bottom-left), for the arrangement map.
    let frame: CGRect
    let pixelWidth: Int
    let pixelHeight: Int
    let isPrimary: Bool
    let isBuiltIn: Bool

    var resolution: String { "\(pixelWidth)x\(pixelHeight)" }
    var stored: StoredDisplay { StoredDisplay(id: id, name: name, pixelWidth: pixelWidth, pixelHeight: pixelHeight) }
}

/// What is remembered about a display an output was put on, so an UNPLUGGED display can still be named.
struct StoredDisplay: Codable, Equatable, Sendable {
    let id: String
    let name: String
    let pixelWidth: Int
    let pixelHeight: Int
    /// A display carried over from 1.2 (UUID only) and not seen since has no size on record.
    var resolution: String { pixelWidth > 0 ? "\(pixelWidth)x\(pixelHeight)" : "size not known yet" }
}

/// Where an output stands right now.
enum OutputState: Equatable {
    /// No display chosen.
    case notSet
    /// Its display is connected.
    case onDisplay(DisplayInfo)
    /// Its display is not connected. The assignment is KEPT and comes back with the display.
    case unplugged(StoredDisplay)

    var display: DisplayInfo? { if case .onDisplay(let d) = self { return d }; return nil }
}

/// Something about the assignments the operator must know before the show.
enum AssignmentWarning: Equatable, Identifiable {
    /// A room output sits on the display the console is on: it would bury the console (it opens windowed).
    case onControlDisplay(StageWindow, DisplayInfo)
    /// A room output sits on the Mac's own built-in screen.
    case onBuiltIn(StageWindow, DisplayInfo)
    /// Two room outputs share one display: only one of them can be seen.
    case shared(DisplayInfo, [StageWindow])
    /// The display an output was assigned to is not connected.
    case unplugged(StageWindow, StoredDisplay)

    var id: String {
        switch self {
        case .onControlDisplay(let w, _): "control-\(w.rawValue)"
        case .onBuiltIn(let w, _): "builtin-\(w.rawValue)"
        case .shared(let d, _): "shared-\(d.id)"
        case .unplugged(let w, _): "unplugged-\(w.rawValue)"
        }
    }

    /// Plain words, one line.
    var text: String {
        switch self {
        case .onControlDisplay(let w, let d):
            "\(w.outputLabel) is on the control display (\(d.index) \(d.name)): it opens as a window so it cannot cover the console."
        case .onBuiltIn(let w, let d):
            "\(w.outputLabel) is on the built-in screen (\(d.index) \(d.name)), not a room display."
        case .shared(let d, let ws) where Set(ws) == Set(StageWindow.roomOutputs):
            "KEY OVERLAY shares \(d.name) with the CONFIDENCE MONITOR: assign it to the display that feeds your ATEM. GO LIVE leaves it off."
        case .shared(let d, let ws):
            "\(ws.map(\.outputLabel).joined(separator: " and ")) share display \(d.index) \(d.name): only one can be seen."
        case .unplugged(let w, let s):
            "\(w.outputLabel) display \(s.name) (\(s.resolution)) is UNPLUGGED. The assignment is kept and restores when it returns."
        }
    }
}

extension StageWindow {
    /// The operator's word for it, in the chips, the panel and the warnings.
    /// Renamed 2026-09-24: the full timer screen (window id `stage`) is the CONFIDENCE MONITOR; the
    /// ATEM overlay / PIP key layer (window id `confidence`) is the KEY OVERLAY. Ids, saved keys, scene ids and
    /// API values are unchanged.
    var outputLabel: String {
        switch self {
        case .control: "CONTROL"
        case .stage: "CONFIDENCE MONITOR"
        case .confidence: "KEY OVERLAY"
        case .widget: "WIDGET"
        }
    }

    /// The short form, where a chip is short of room.
    var chipLabel: String {
        switch self {
        case .stage: "MONITOR"
        case .confidence: "KEY"
        default: outputLabel
        }
    }

    /// The outputs the room sees: they fill their display and must not share one. The KEY OVERLAY is one only
    /// while it is enabled in Settings (2026-09-24: nearly every show is the console and the confidence monitor): while it
    /// is off, every rule (GO LIVE, CHECKS, the map, conflicts, the launch sweep) simply does not see it.
    static var roomOutputs: [StageWindow] { KeyOverlaySetting.isEnabled ? [.stage, .confidence] : [.stage] }
    /// Everything the OUTPUTS strip and panel assign, in chip order.
    static var assignable: [StageWindow] { roomOutputs + [.control] }
}

/// GO LIVE's decision for the room outputs that are not up yet.
struct GoLivePlan: Equatable {
    /// output -> the display it opens on.
    var targets: [StageWindow: DisplayInfo] = [:]
    /// Outputs that had no assignment and were given the fallback display (recorded, so the chip shows it).
    var fallback: Set<StageWindow> = []
    /// Outputs GO LIVE leaves closed, and why.
    var skipped: [StageWindow: GoLiveSkip] = [:]
    /// Live outputs GO LIVE takes off the air (a KEY OVERLAY on the CONFIDENCE MONITOR's display).
    var takeOff: Set<StageWindow> = []
}

enum GoLiveSkip: Equatable {
    /// No display besides the console's: nothing opens over the console.
    case noOutputDisplay
    /// Its display is unplugged: it comes up when the display returns.
    case unplugged(StoredDisplay)
    /// KEY OVERLAY with no assignment and only one display besides the console's: it waits for one.
    case keyNeedsAssignment
    /// KEY OVERLAY assigned to the CONFIDENCE MONITOR's display: the monitor wins, the key stays off.
    case sharesConfidenceMonitor(DisplayInfo)

    /// For the log.
    var text: String {
        switch self {
        case .noOutputDisplay: "no display besides the console's"
        case .unplugged(let s): "its display \(s.name) is unplugged"
        case .keyNeedsAssignment: "no assignment, one output display"
        case .sharesConfidenceMonitor(let d): "shares \(d.name) with the CONFIDENCE MONITOR"
        }
    }
}

/// `OutputAssignmentBook.restoredWindowAction`.
enum RestoredWindowAction: Equatable {
    case close
    case place(DisplayInfo)
    case park(StoredDisplay)
}

/// The header's GO LIVE button.
enum GoLiveButtonState: Equatable {
    /// Nothing live: GO LIVE (red).
    case off
    /// Some of the expected outputs live: GO LIVE with "n/m LIVE"; a click brings the rest up.
    case partial(Int, Int)
    /// Every room output live: OFF AIR, red-filled; a click takes them all off.
    case live
    /// No display besides the console's: disabled, "NO OUTPUT DISPLAY".
    case noOutputDisplay
}

/// "KEY OVERLAY (ATEM)" in Settings: off by default, for new and existing installs alike (the operator's call). While
/// off, a saved KEY OVERLAY assignment is kept, dormant, and no KEY OVERLAY window stays open.
enum KeyOverlaySetting {
    static let defaultsKey = "keyOverlayEnabled"
    /// Read everywhere the rules need it; tests set it directly.
    nonisolated(unsafe) static var isEnabled: Bool = UserDefaults.standard.bool(forKey: defaultsKey)
    /// A route naming the KEY OVERLAY is refused while it is off (every other window is unaffected).
    static func refuses(_ window: StageWindow?) -> Bool { window == .confidence && !isEnabled }
    /// The API's answer for a key-overlay route while it is off.
    static let disabledError = "Key Overlay is disabled in Settings (ARC Stage Timer > Settings > KEY OVERLAY (ATEM))"
}

/// Which display each window belongs to, remembered by display IDENTITY (UUID, plus name and resolution for
/// display when it is gone), never by index. Persisted as JSON in UserDefaults.
struct OutputAssignmentBook: Codable, Equatable {
    private(set) var entries: [String: StoredDisplay] = [:]

    init() {}

    func stored(_ window: StageWindow) -> StoredDisplay? { entries[window.rawValue] }

    mutating func assign(_ window: StageWindow, to display: DisplayInfo) { entries[window.rawValue] = display.stored }
    mutating func assign(_ window: StageWindow, stored: StoredDisplay) { entries[window.rawValue] = stored }
    mutating func clear(_ window: StageWindow) { entries[window.rawValue] = nil }

    /// The connected display a window belongs to. By UUID first. A display whose UUID changed (some adapters
    /// report a new one per port) is matched by name AND resolution, but only when exactly one connected
    /// display fits: a guess between two identical monitors would put the stage on the wrong one.
    func resolve(_ window: StageWindow, among displays: [DisplayInfo]) -> DisplayInfo? {
        guard let s = stored(window) else { return nil }
        if let exact = displays.first(where: { $0.id == s.id }) { return exact }
        let claimed = Set(entries.values.map(\.id))
        let candidates = displays.filter {
            $0.name == s.name && $0.pixelWidth == s.pixelWidth && $0.pixelHeight == s.pixelHeight && !claimed.contains($0.id)
        }
        return candidates.count == 1 ? candidates[0] : nil
    }

    func state(_ window: StageWindow, among displays: [DisplayInfo]) -> OutputState {
        guard let s = stored(window) else { return .notSet }
        if let d = resolve(window, among: displays) { return .onDisplay(d) }
        return .unplugged(s)
    }

    /// Every warning, in the order the operator should read them. `controlDisplayID` is where the console
    /// actually is (nil when headless: no console to cover).
    func warnings(among displays: [DisplayInfo], controlDisplayID: String?) -> [AssignmentWarning] {
        var out: [AssignmentWarning] = []
        var byDisplay: [String: [StageWindow]] = [:]
        for w in StageWindow.roomOutputs {
            switch state(w, among: displays) {
            case .notSet: continue
            case .unplugged(let s): out.append(.unplugged(w, s))
            case .onDisplay(let d):
                byDisplay[d.id, default: []].append(w)
                if d.id == controlDisplayID { out.append(.onControlDisplay(w, d)) }
                else if d.isBuiltIn { out.append(.onBuiltIn(w, d)) }
            }
        }
        for d in displays {
            if let ws = byDisplay[d.id], ws.count > 1 { out.append(.shared(d, ws)) }
        }
        return out
    }

    /// A display for a room output that has none: the first connected display that is not the console's and
    /// carries no other room output. Nil when there is no such display (then nothing is guessed).
    func suggestion(for window: StageWindow, among displays: [DisplayInfo], controlDisplayID: String?) -> DisplayInfo? {
        let taken = Set(StageWindow.roomOutputs.filter { $0 != window }.compactMap { resolve($0, among: displays)?.id })
        return displays.first { $0.id != controlDisplayID && !taken.contains($0.id) && !$0.isBuiltIn }
            ?? displays.first { $0.id != controlDisplayID && !taken.contains($0.id) }
    }

    // MARK: GO LIVE (2026-09-24: one button that takes the confidence monitor and the stage live)

    /// Where GO LIVE puts each room output that is not live yet. Pure, so every case is tested.
    ///
    /// - No display besides the console's: nothing opens (it would cover the console): `.noOutputDisplay`.
    /// - Assigned and connected: its display (the same as OPEN on its chip).
    /// - Assigned and UNPLUGGED: left alone; the unplug/restore rule brings it up when the display returns.
    /// - CONFIDENCE MONITOR not set: the first display that is not the console's and carries no other room
    ///   output, a room display before a built-in one; with no such choice, the first display that is not the
    ///   console's (shared; the CHECKS say so).
    /// - KEY OVERLAY not set: only when there are TWO or more displays besides the console's, on a free one.
    ///   With one, it is skipped (`.keyNeedsAssignment`): it feeds an ATEM, and on a screen of its own it is
    ///   mostly black (2026-09-24). It then does not count against "fully live".
    /// CONTROL is never part of it.
    func goLivePlan(among displays: [DisplayInfo], controlDisplayID: String?, alreadyLive: Set<StageWindow>) -> GoLivePlan {
        var plan = GoLivePlan()
        let outputDisplays = displays.filter { $0.id != controlDisplayID }
        for w in StageWindow.roomOutputs where !alreadyLive.contains(w) {
            guard !outputDisplays.isEmpty else { plan.skipped[w] = .noOutputDisplay; continue }
            switch state(w, among: displays) {
            case .onDisplay(let d): plan.targets[w] = d
            case .unplugged(let s): plan.skipped[w] = .unplugged(s)
            case .notSet:
                let taken = Set(StageWindow.roomOutputs.filter { $0 != w }
                    .compactMap { plan.targets[$0]?.id ?? resolve($0, among: displays)?.id })
                let free = outputDisplays.filter { !taken.contains($0.id) }
                if w == .confidence {
                    guard outputDisplays.count >= 2, let d = free.first(where: { !$0.isBuiltIn }) ?? free.first else {
                        plan.skipped[w] = .keyNeedsAssignment; continue
                    }
                    plan.targets[w] = d
                    plan.fallback.insert(w)
                } else if let d = free.first(where: { !$0.isBuiltIn }) ?? free.first ?? outputDisplays.first {
                    plan.targets[w] = d
                    plan.fallback.insert(w)
                }
            }
        }
        // NEVER two outputs on one display (the operator's field report, 2026-09-24: the KEY OVERLAY sat on top of the
        // CONFIDENCE MONITOR on one display and hid it). The CONFIDENCE MONITOR wins; the KEY OVERLAY stays off, and a
        // live one is taken off that display. The CHECKS say why.
        let monitorDisplay = plan.targets[.stage]?.id ?? (alreadyLive.contains(.stage) ? resolve(.stage, among: displays)?.id : nil)
        if let monitorDisplay, let key = plan.targets[.confidence] ?? (alreadyLive.contains(.confidence) ? resolve(.confidence, among: displays) : nil),
           key.id == monitorDisplay {
            plan.targets[.confidence] = nil
            plan.fallback.remove(.confidence)
            plan.skipped[.confidence] = .sharesConfidenceMonitor(key)
            if alreadyLive.contains(.confidence) { plan.takeOff.insert(.confidence) }
        }
        return plan
    }

    /// The other room output already assigned to `display`, if any: assigning `window` there would put two
    /// outputs on one display, which the operator is asked to confirm (OUTPUTS chips and panel).
    func conflict(assigning window: StageWindow, to display: DisplayInfo, among displays: [DisplayInfo]) -> StageWindow? {
        guard StageWindow.roomOutputs.contains(window) else { return nil }
        return StageWindow.roomOutputs.first { $0 != window && resolve($0, among: displays)?.id == display.id }
    }

    /// The room outputs GO LIVE is responsible for right now: every one it would open or is waiting on (an
    /// unplugged one counts), plus any already live. A KEY OVERLAY left out for want of an assignment does not.
    func goLiveExpected(among displays: [DisplayInfo], controlDisplayID: String?, live: Set<StageWindow>) -> Set<StageWindow> {
        let plan = goLivePlan(among: displays, controlDisplayID: controlDisplayID, alreadyLive: [])
        var expected = Set(plan.targets.keys).union(live.intersection(StageWindow.roomOutputs))
        for (w, why) in plan.skipped { if case .unplugged = why { expected.insert(w) } }
        return expected
    }

    /// What the GO LIVE button shows. `live`: room outputs up on their displays now; `expected`: see above.
    static func goLiveButton(live: Set<StageWindow>, expected: Set<StageWindow>, hasOutputDisplay: Bool) -> GoLiveButtonState {
        let up = live.intersection(StageWindow.roomOutputs)
        if !expected.isEmpty && expected.isSubset(of: up) { return .live }
        if up.isEmpty { return hasOutputDisplay ? .off : .noOutputDisplay }
        return .partial(up.count, max(expected.union(up).count, up.count))
    }

    // MARK: Windows macOS brings back at launch

    /// What to do with a room-output window that exists at launch (macOS window restoration, or a late
    /// restore): no assignment -> CLOSE it (a stray KEY OVERLAY sat windowed on a display with its chip reading
    /// KEY NOT SET, 2026-09-24); assigned and connected -> PLACE it live there, as before; assigned but
    /// unplugged -> PARK it (off screen) until the display returns.
    func restoredWindowAction(_ window: StageWindow, among displays: [DisplayInfo]) -> RestoredWindowAction {
        switch state(window, among: displays) {
        case .notSet: return .close
        case .onDisplay(let d): return .place(d)
        case .unplugged(let s): return .park(s)
        }
    }

    // MARK: Persistence

    static let defaultsKey = "outputAssignments.v2"
    /// The 1.2 format: window -> UUID only.
    static let legacyKey = "displayPlacement"

    static func load(from defaults: UserDefaults, displays: [DisplayInfo]) -> OutputAssignmentBook {
        if let data = defaults.data(forKey: defaultsKey),
           let book = try? JSONDecoder().decode(OutputAssignmentBook.self, from: data) {
            return book
        }
        if let legacy = defaults.dictionary(forKey: legacyKey) as? [String: String] {
            return migrate(legacy: legacy, displays: displays)
        }
        return OutputAssignmentBook()
    }

    func save(to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }

    /// 1.2 stored the UUID alone. A display that is connected now gets its name back; one that is not keeps
    /// its UUID under a placeholder name, so its assignment still survives until it is plugged in.
    static func migrate(legacy: [String: String], displays: [DisplayInfo]) -> OutputAssignmentBook {
        var book = OutputAssignmentBook()
        for (key, uuid) in legacy {
            guard let w = StageWindow(rawValue: key) else { continue }
            if let d = displays.first(where: { $0.id == uuid }) { book.assign(w, to: d) }
            else { book.assign(w, stored: StoredDisplay(id: uuid, name: "Display \(uuid.prefix(8))", pixelWidth: 0, pixelHeight: 0)) }
        }
        return book
    }
}
#endif

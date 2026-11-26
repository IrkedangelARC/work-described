//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation
import CoreGraphics
import AppKit

/// Display roles for show-control discipline. A LIVE OUT is sacred: the
/// capturer never places windows on it, never changes its resolution, never
/// photographs it. Roles persist by display UUID (stable across reconnects
/// and reboots), set in the Displays section of the side panel.
public enum DisplayRole: String, Codable, CaseIterable {
    case auto = "Auto"          // eligible for capture when safe (default)
    case capture = "Capture"    // explicitly sanctioned capture surface
    case liveOut = "LIVE OUT"   // protected: never touched by anything
}

/// One display as policy sees it. Pure value — the decision logic below is
/// unit-testable without hardware.
public struct DisplaySnapshot: Identifiable, Equatable {
    public var id: CGDirectDisplayID
    public var uuid: String
    public var name: String
    public var bounds: CGRect
    public var isMain: Bool
    public var role: DisplayRole
    public var occupiedBy: String?     // owner of a fullscreen-sized window, if any
    public init(id: CGDirectDisplayID, uuid: String, name: String, bounds: CGRect,
                isMain: Bool, role: DisplayRole, occupiedBy: String? = nil) {
        self.id = id; self.uuid = uuid; self.name = name; self.bounds = bounds
        self.isMain = isMain; self.role = role; self.occupiedBy = occupiedBy
    }
}

public enum DisplayPolicy {

    public static let rolesKey = "displayRoles.v1"

    // MARK: - Decision logic (pure)

    public struct Choice {
        public var display: DisplaySnapshot?
        public var warnings: [String] = []
        public init(display: DisplaySnapshot? = nil, warnings: [String] = []) {
            self.display = display
            self.warnings = warnings
        }
    }

    /// Which display may host a capture. Rules, in order:
    /// - An UNVERIFIED monitor map blocks all windowed routing — the
    ///   operator must Identify + Confirm the current topology first.
    /// - LIVE OUT displays are NEVER eligible, occupied or not.
    /// - The main display is never a capture surface (it's the operator's).
    /// - An explicit .capture display wins — but an occupied one aborts to
    ///   fullscreen with a warning (something is playing there RIGHT NOW).
    /// - Else exactly ONE .auto external, unoccupied → it. Multiple .auto
    ///   externals require an explicit choice (ambiguity = warning, no pick).
    public static func chooseCaptureDisplay(_ displays: [DisplaySnapshot],
                                     mapVerified: Bool) -> Choice {
        var out = Choice()
        guard mapVerified else {
            if displays.contains(where: { !$0.isMain }) {
                out.warnings.append("monitor map UNVERIFIED — run Identify Monitors and Confirm Layout in the Displays panel; capture stays on the main display until the layout is confirmed")
            }
            return out
        }
        let externals = displays.filter { !$0.isMain && $0.role != .liveOut }

        if let explicit = displays.first(where: { $0.role == .capture && !$0.isMain }) {
            if let owner = explicit.occupiedBy {
                out.warnings.append("capture display '\(explicit.name)' is occupied by \(owner) — capture stays on the main display")
                return out
            }
            out.display = explicit
            return out
        }

        let candidates = externals.filter { $0.role == .auto && $0.occupiedBy == nil }
        if candidates.count == 1 {
            out.display = candidates[0]
        } else if candidates.count > 1 {
            out.warnings.append("\(candidates.count) external displays available — mark one as Capture in the Displays panel; capture stays on the main display until then")
        } else if let busy = externals.first(where: { $0.occupiedBy != nil }) {
            out.warnings.append("external display '\(busy.name)' is occupied by \(busy.occupiedBy!) — capture stays on the main display")
        }
        return out
    }

    // MARK: - Hardware enumeration

    public static func snapshot() -> [DisplaySnapshot] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var cnt: UInt32 = 0
        guard CGGetActiveDisplayList(16, &ids, &cnt) == .success else { return [] }
        let roles = storedRoles()
        return ids[0..<Int(cnt)].map { did in
            let uuid = displayUUID(did)
            return DisplaySnapshot(
                id: did, uuid: uuid, name: displayName(did),
                bounds: CGDisplayBounds(did),
                isMain: CGDisplayIsMain(did) != 0,
                role: roles[uuid] ?? .auto,
                occupiedBy: fullscreenOwner(on: CGDisplayBounds(did)))
        }
    }

    /// Roles live in the persistent MonitorInventory (single source of
    /// truth). Legacy UserDefaults roles are migrated on first read.
    public static func storedRoles() -> [String: DisplayRole] {
        var roles = Dictionary(uniqueKeysWithValues:
            MonitorInventory.load().records.map { ($0.uuid, $0.role) })
        if let raw = UserDefaults.standard.dictionary(forKey: rolesKey) as? [String: String] {
            for (uuid, r) in raw where roles[uuid] == nil {
                if let role = DisplayRole(rawValue: r) {
                    roles[uuid] = role
                    MonitorInventory.setRole(role, forUUID: uuid, stamp: MonitorInventory.stamp())
                }
            }
            UserDefaults.standard.removeObject(forKey: rolesKey)
        }
        return roles
    }

    public static func setRole(_ role: DisplayRole, forUUID uuid: String) {
        MonitorInventory.setRole(role, forUUID: uuid, stamp: MonitorInventory.stamp())
    }

    public static func displayUUID(_ did: CGDirectDisplayID) -> String {
        if let cf = CGDisplayCreateUUIDFromDisplayID(did)?.takeRetainedValue() {
            return CFUUIDCreateString(nil, cf) as String
        }
        return "display-\(did)"
    }

    public static func displayName(_ did: CGDirectDisplayID) -> String {
        for screen in NSScreen.screens {
            if let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
               n.uint32Value == did {
                return screen.localizedName
            }
        }
        return "Display \(did)"
    }

    /// Owner of a fullscreen-sized window on this display (a live Presenter
    /// output, a video feed), excluding our own processes and system chrome.
    public static func fullscreenOwner(on bounds: CGRect) -> String? {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        return fullscreenOwner(on: bounds, windows: info)
    }

    /// Pure core of the occupancy check (unit-tested). CONTENT LAYERS ONLY:
    /// layer 0 is a normal app window (a fullscreen video player, a browser
    /// in fullscreen); layer >= 1000 is the screensaver/shielding class (ARC
    /// Presenter's program and confidence outputs, kiosk apps). The 1…999
    /// band is utility chrome that never shows content — status items,
    /// floating panels, and window managers' overlays. Measured 2026-09-04:
    /// Magnet parks a layer-25 window exactly the size of EVERY display, which
    /// made every display read as OCCUPIED and would have blocked windowed
    /// capture on a verified map.
    public static func fullscreenOwner(on bounds: CGRect, windows: [[String: Any]]) -> String? {
        for w in windows {
            guard let owner = w[kCGWindowOwnerName as String] as? String,
                  owner != "Microsoft PowerPoint", owner != "ArcAssimilator",
                  owner != "Window Server", owner != "Dock", owner != "Finder",
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let layer = (w[kCGWindowLayer as String] as? Int) ?? 0
            guard layer == 0 || layer >= 1000 else { continue }
            let r = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0,
                           width: b["Width"] ?? 0, height: b["Height"] ?? 0)
            if abs(r.width - bounds.width) < 4, abs(r.height - bounds.height) < 40,
               r.midX >= bounds.minX, r.midX <= bounds.maxX {
                return owner
            }
        }
        return nil
    }

    // MARK: - Resolution (capture displays only)

    /// Standing rule: capture displays run 1920x1080. ONLY ever applied to
    /// the chosen capture display — a LIVE OUT's mode is never touched (a
    /// mid-show mode switch on a house projector is a fireable offense).
    @discardableResult
    public
    static func ensure1080p(_ display: DisplaySnapshot) -> Bool {
        guard display.role != .liveOut else { return false }
        let did = display.id
        if CGDisplayPixelsWide(did) == 1920 && CGDisplayPixelsHigh(did) == 1080 { return true }
        guard let modes = CGDisplayCopyAllDisplayModes(did, nil) as? [CGDisplayMode],
              let m = modes.first(where: { $0.width == 1920 && $0.height == 1080 })
        else { return false }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return false }
        CGConfigureDisplayWithDisplayMode(config, did, m, nil)
        CGCompleteDisplayConfiguration(config, .permanently)
        return CGDisplayPixelsWide(did) == 1920 && CGDisplayPixelsHigh(did) == 1080
    }

    /// The capture display's current bounds, nil if it vanished (cable pull
    /// mid-walk) — the capturer aborts rather than photographing a ghost.
    public static func currentBounds(ofDisplayUUID uuid: String) -> CGRect? {
        snapshot().first(where: { $0.uuid == uuid }).map { $0.bounds }
    }

    // MARK: - Preflight report

    /// Everything the operator needs to know BEFORE a capture starts — the
    /// display decision and every permission state — so nothing surprises
    /// mid-run and no popup needs hunting. All checks are prompt-free.
    public static func preflightReport() -> [String] {
        var lines: [String] = []
        let snaps = snapshot()
        MonitorInventory.reconcile(snaps, stamp: MonitorInventory.stamp())
        if MonitorInventory.isVerified(snaps) {
            lines.append("monitor map: VERIFIED (confirmed \(MonitorInventory.verifiedAt() ?? "?"))")
        } else {
            lines.append("monitor map: UNVERIFIED — Identify Monitors + Confirm Layout before windowed capture is allowed")
        }
        for d in snaps {
            var bits = ["\(Int(d.bounds.width))×\(Int(d.bounds.height))"]
            if d.isMain { bits.append("main/operator") } else { bits.append(d.role.rawValue) }
            if let o = d.occupiedBy { bits.append("OCCUPIED by \(o)") }
            lines.append("display '\(d.name)': \(bits.joined(separator: ", "))")
        }
        let choice = chooseCaptureDisplay(snaps, mapVerified: MonitorInventory.isVerified(snaps))
        if let cap = choice.display {
            lines.append("capture surface → WINDOWED on '\(cap.name)' (main display stays yours; no Accessibility needed)")
        } else {
            lines.append("capture surface → FULLSCREEN on the main display (takes over the screen; spacebar advance wants Accessibility)")
        }
        lines.append(contentsOf: choice.warnings)

        lines.append("Screen Recording: \(CGPreflightScreenCaptureAccess() ? "granted" : "NOT GRANTED — capture will fail; grant in System Settings > Privacy > Screen Recording")")
        lines.append("Accessibility: \(AXIsProcessTrusted() ? "granted" : "not granted (only needed for fullscreen spacebar advance)")")
        // Automation check without prompting (kAEDoNotPromptUser semantics).
        var addr = AEAddressDesc()
        let bundleID = "com.microsoft.Powerpoint"
        let status: String = bundleID.withCString { cstr in
            if AECreateDesc(typeApplicationBundleID, cstr, strlen(cstr), &addr) == noErr {
                defer { AEDisposeDesc(&addr) }
                switch AEDeterminePermissionToAutomateTarget(&addr, typeWildCard, typeWildCard, false) {
                case noErr: return "granted"
                case OSStatus(procNotFound): return "unknown (PowerPoint not running)"
                case OSStatus(errAEEventNotPermitted): return "DENIED — re-enable in System Settings > Privacy > Automation"
                default: return "will prompt on first use"
                }
            }
            return "unknown"
        }
        lines.append("PowerPoint automation: \(status)")
        return lines
    }
}

//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import AppKit

/// PLAN_zoom_source step 1 (2026-09-20): "the program out of the switcher
/// app [is] a selectable share target in Zoom". Zoom's share picker lists
/// ordinary-level windows only; the program window sits at the shielding level
/// on purpose (it covers the program display's menu bar), so Zoom never lists
/// it (drill finding 13). This is a second, ordinary-level window that draws
/// the PLAIN program picture: the deck, or a live PowerPoint / non-Zoom window,
/// never a Zoom participant (the remote keeps the slides while the room sees
/// Zoom). Zoom shares it by name, wherever PROGRAM happens to be.
///
/// Headless like the DeckLink program window: borderless, 16:9, on the
/// operator's screen behind the operator window, on screen (ScreenCaptureKit
/// needs that; occluded is fine) but out of the way.
@MainActor
@Observable
final class ShareOutput {
    static let title = "ARC Presenter Program"
    static let sceneID = "share-output"
    nonisolated static let zoomBundleID = "us.zoom.xos"
    /// Points; a 2x operator display makes this a 1920x1080 share.
    static let size = NSSize(width: 960, height: 540)

    private(set) var isOpen = false
    private(set) var status: String?
    @ObservationIgnored private var closeObserver: NSObjectProtocol?

    /// Does the share show the live external source? PowerPoint and any
    /// non-Zoom window yes; a Zoom window no (the remote would see the gallery
    /// it is already in). Pure, so it is tested.
    nonisolated static func showsExternal(_ external: LiveSource, windowBundleID: String?) -> Bool {
        switch external {
        case .deck: return false
        case .powerpoint: return true
        case .window: return windowBundleID != Self.zoomBundleID
        }
    }

    /// Open (or re-place) the share window. Returns once the window is on screen
    /// (3 s ceiling).
    @discardableResult
    func open() async -> Bool {
        status = nil
        if let w = existing() { place(w); return true }
        NotificationCenter.default.post(name: .openShareWindow, object: nil)
        for _ in 0..<30 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if let w = existing() { place(w); return true }
        }
        status = "the share window never appeared"
        ShowLog.error("SHARE: \(status!)")
        return false
    }

    func close() {
        guard let w = existing() else { isOpen = false; return }
        w.orderOut(nil)
        isOpen = false
        ShowLog.log("SHARE closed")
    }

    private func existing() -> NSWindow? {
        NSApp.windows.first { $0.title == Self.title && $0.isVisible }
    }

    /// The share window's frame in top-left global space (the window server's), for ZoomSource to
    /// match Zoom's annotation overlay against. nil when the window is not open.
    static func frameTopLeft() -> CGRect? {
        guard let w = NSApp.windows.first(where: { $0.title == Self.title && $0.isVisible }),
              let main = NSScreen.screens.first else { return nil }
        let f = w.frame
        return CGRect(x: f.minX, y: main.frame.maxY - f.maxY, width: f.width, height: f.height)
    }

    private func place(_ window: NSWindow) {
        // Bottom-left of the OPERATOR's screen (the DeckLink headless window takes bottom-right).
        guard HeadlessWindow.place(window, size: Self.size, corner: .bottomLeft) else { return }
        window.title = Self.title   // borderless drops nothing, but Zoom lists by this name: keep it set
        let screen = HeadlessWindow.operatorScreen
        if closeObserver == nil {
            closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.isOpen = false }
            }
        }
        if !isOpen {
            isOpen = true
            ShowLog.log("SHARE open: \"\(Self.title)\" \(Int(Self.size.width))x\(Int(Self.size.height)) pt on \(screen?.localizedName ?? "?")")
        }
    }

    var json: String {
        let st = status.map { "\"\($0.replacingOccurrences(of: "\"", with: "'"))\"" } ?? "null"
        return "{\"open\":\(isOpen),\"title\":\"\(Self.title)\",\"status\":\(st)}"
    }
}

extension Notification.Name {
    static let openShareWindow = Notification.Name("com.example.arc.openShareWindow")
}

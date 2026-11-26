//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import AppKit
import SwiftUI

/// Test-output router: TAKE a generated ARC test card to a chosen display,
/// CLEAR it when done. Switcher discipline — nothing appears on any output
/// except through an explicit TAKE, and LIVE OUT displays are not offered.
@MainActor
public final class TestOutputController: ObservableObject {
    public static let shared = TestOutputController()

    /// display UUID -> the card window currently taken to it
    @Published public private(set) var taken: [String: NSWindow] = [:]

    public func isTaken(_ uuid: String) -> Bool { taken[uuid] != nil }

    /// AppKit frame for a display — NSWindow speaks bottom-left-origin
    /// AppKit coordinates, NOT CG's top-left global space. Feeding CG bounds
    /// straight into setFrame lands windows on the wrong display (field-
    /// diagnosed 2026-07-19: test card appeared on the primary).
    public static func appKitFrame(for display: DisplaySnapshot) -> NSRect? {
        for screen in NSScreen.screens {
            if let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
               n.uint32Value == display.id {
                return screen.frame
            }
        }
        return nil
    }

    private func makeCard<V: View>(frame: NSRect, view: V) -> NSWindow {
        let win = NSWindow(contentRect: frame, styleMask: [.borderless],
                           backing: .buffered, defer: false)
        win.level = .statusBar
        win.isOpaque = true
        win.backgroundColor = .black
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        win.isReleasedWhenClosed = false
        win.contentView = NSHostingView(rootView: view)
        win.setFrame(frame, display: true)
        win.orderFrontRegardless()
        return win
    }

    public func take(_ display: DisplaySnapshot) {
        clear(display.uuid)
        guard let frame = Self.appKitFrame(for: display) else { return }
        taken[display.uuid] = makeCard(frame: frame, view: TestCardView(
            displayName: display.name,
            resolution: "\(Int(display.bounds.width))×\(Int(display.bounds.height))"))
    }

    // MARK: - Identify (monitor ID step)

    private var identifyWindows: [NSWindow] = []
    private var identifyTask: Task<Void, Never>?

    /// Flash an ID slate on EVERY display at once — number, name, resolution,
    /// role — so the operator can visually verify the app's display map
    /// against physical reality before trusting any routing. Auto-clears.
    public func identify(_ displays: [DisplaySnapshot], seconds: TimeInterval = 5) {
        clearIdentify()
        for (i, d) in displays.enumerated() {
            guard let frame = Self.appKitFrame(for: d) else { continue }
            identifyWindows.append(makeCard(frame: frame, view: IdentifyCardView(
                number: i + 1,
                displayName: d.name,
                resolution: "\(Int(d.bounds.width))×\(Int(d.bounds.height))",
                role: d.isMain ? "MAIN / OPERATOR" : d.role.rawValue.uppercased(),
                isMain: d.isMain)))
        }
        identifyTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if !Task.isCancelled { self?.clearIdentify() }
        }
    }

    public func clearIdentify() {
        identifyTask?.cancel()
        identifyTask = nil
        // close(), not orderOut(): hidden windows stay in the window list
        // forever otherwise (measured 2026-09-04: 12 leaked slates after
        // three IDENTIFY presses). isReleasedWhenClosed is false, so close
        // is safe while we still hold the reference.
        identifyWindows.forEach { $0.close() }
        identifyWindows.removeAll()
    }

    public func clear(_ uuid: String) {
        taken[uuid]?.close()
        taken[uuid] = nil
    }

    public func clearAll() {
        taken.keys.forEach { clear($0) }
    }
}

/// Monitor-ID slate: giant number + identity, unmissable from across a room.
public struct IdentifyCardView: View {
    public var number: Int
    public var displayName: String
    public var resolution: String
    public var role: String
    public var isMain: Bool
    public init(number: Int, displayName: String, resolution: String, role: String, isMain: Bool) {
        self.number = number; self.displayName = displayName
        self.resolution = resolution; self.role = role; self.isMain = isMain
    }

    public var body: some View {
        ZStack {
            isMain ? Color(red: 0.05, green: 0.1, blue: 0.25) : Color.black
            VStack(spacing: 12) {
                Text("\(number)")
                    .font(.system(size: 420, weight: .black, design: .monospaced))
                Text(displayName)
                    .font(.system(size: 48, weight: .bold, design: .monospaced))
                Text("\(resolution) · \(role)")
                    .font(.system(size: 30, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.white)
        }
        .ignoresSafeArea()
    }
}

/// ARC test card: grid, crosshair, corner markers, display identity. Black
/// background, industrial — verifies routing, geometry, and edge visibility
/// at a glance.
public struct TestCardView: View {
    public var displayName: String
    public var resolution: String
    public init(displayName: String, resolution: String) {
        self.displayName = displayName; self.resolution = resolution
    }

    public var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                // Grid
                Path { p in
                    let step: CGFloat = 96
                    var x: CGFloat = 0
                    while x <= geo.size.width { p.move(to: .init(x: x, y: 0)); p.addLine(to: .init(x: x, y: geo.size.height)); x += step }
                    var y: CGFloat = 0
                    while y <= geo.size.height { p.move(to: .init(x: 0, y: y)); p.addLine(to: .init(x: geo.size.width, y: y)); y += step }
                }
                .stroke(Color.white.opacity(0.18), lineWidth: 1)
                // Center crosshair
                Path { p in
                    let cx = geo.size.width / 2, cy = geo.size.height / 2
                    p.move(to: .init(x: cx - 80, y: cy)); p.addLine(to: .init(x: cx + 80, y: cy))
                    p.move(to: .init(x: cx, y: cy - 80)); p.addLine(to: .init(x: cx, y: cy + 80))
                }
                .stroke(Color.white.opacity(0.7), lineWidth: 2)
                // Corner edge markers
                ForEach(0..<4, id: \.self) { i in
                    Rectangle()
                        .fill(Color.white)
                        .frame(width: 40, height: 40)
                        .position(x: i % 2 == 0 ? 20 : geo.size.width - 20,
                                  y: i < 2 ? 20 : geo.size.height - 20)
                }
                VStack(spacing: 10) {
                    Text("ARC TEST OUTPUT")
                        .font(.system(size: 64, weight: .heavy, design: .monospaced))
                    Text("\(displayName) · \(resolution)")
                        .font(.system(size: 34, weight: .medium, design: .monospaced))
                    Text("taken from ARC Assimilator — clear from the Displays panel")
                        .font(.system(size: 20, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(.white)
            }
        }
        .ignoresSafeArea()
    }
}

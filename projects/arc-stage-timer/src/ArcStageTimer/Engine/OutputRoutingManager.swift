//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI

#if os(macOS)
import AppKit

/// IDENTIFY and TEST on the physical screens, and taking the outputs off the air.
///
/// WHERE each output goes is not kept here any more: it lives in `DisplayPlacement.book`, by display identity,
/// persisted, and kept through an unplug (2026-09-24). This class used to hold its own routes by
/// CGDirectDisplayID, which changes on a replug, were never saved, and were DROPPED when a display went away.
@MainActor
@Observable
final class OutputRoutingManager {
    /// Something is on the physical screens right now (IDENTIFY or a test card).
    private(set) var identifying = false
    private(set) var testing: StageWindow?

    @ObservationIgnored private var cardWindows: [NSWindow] = []
    @ObservationIgnored private var dismissWork: DispatchWorkItem?

    init() {}

    // MARK: IDENTIFY: every screen shows its number, name, resolution and what is on it

    func identifyAll(_ placement: DisplayPlacement) {
        dismissCards()
        let displays = DisplayPlacement.infos()
        let control = placement.controlDisplayID()
        for d in displays {
            var roles = StageWindow.roomOutputs.filter { placement.state($0).display?.id == d.id }.map(\.outputLabel)
            if d.id == control { roles.append("CONTROL") }
            show(ScreenCardView(kind: .identify, number: d.index, name: d.name, resolution: d.resolution,
                                roles: roles, isPrimary: d.isPrimary, isBuiltIn: d.isBuiltIn) { [weak self] in self?.dismissCards() },
                 on: d)
        }
        identifying = true
        scheduleDismiss(after: 4)
    }

    // MARK: TEST: a test card on the screen one output is assigned to

    func testCard(_ window: StageWindow, _ placement: DisplayPlacement) {
        guard let d = placement.state(window).display else { return }
        dismissCards()
        show(ScreenCardView(kind: .test(window.outputLabel), number: d.index, name: d.name, resolution: d.resolution,
                            roles: [window.outputLabel], isPrimary: d.isPrimary, isBuiltIn: d.isBuiltIn) { [weak self] in self?.dismissCards() },
             on: d)
        testing = window
        scheduleDismiss(after: 4)
    }

    func dismissCards() {
        dismissWork?.cancel(); dismissWork = nil
        for w in cardWindows { w.orderOut(nil) }
        cardWindows.removeAll()
        identifying = false
        testing = nil
    }

    private func scheduleDismiss(after seconds: Double) {
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.dismissCards() } }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func show(_ card: ScreenCardView, on display: DisplayInfo) {
        guard let screen = DisplayPlacement.screen(for: display) else { return }
        // Untitled and borderless: never mistaken for the console or an output by the window matching.
        let window = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black
        window.contentView = NSHostingView(rootView: card)
        window.setFrame(screen.frame, display: true)
        window.orderFrontRegardless()
        cardWindows.append(window)
    }

    // MARK: Off the air

    /// Close every room output and give the menu bar and Dock back.
    func closeAllOutputs() {
        for w in StageWindow.roomOutputs { for win in DisplayPlacement.windows(for: w) { win.close() } }
        restorePresentationOptions()
    }

    func restorePresentationOptions() {
        NSApp.presentationOptions = []
    }
}

/// What IDENTIFY and TEST put on a physical screen: ARC ink ground, the number huge, the name, the resolution
/// and the outputs on it. A test card adds a framing grid and centre cross so the picture's edges can be seen.
struct ScreenCardView: View {
    enum Kind: Equatable { case identify; case test(String) }
    let kind: Kind
    let number: Int
    let name: String
    let resolution: String
    let roles: [String]
    let isPrimary: Bool
    let isBuiltIn: Bool
    let dismiss: () -> Void

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            ZStack {
                ARCTheme.ink
                if case .test = kind { testGrid(geo.size) }
                VStack(spacing: h * 0.02) {
                    if case .test(let label) = kind {
                        Text("TEST")
                            .font(.system(size: h * 0.04, weight: .heavy, design: .monospaced))
                            .tracking(h * 0.008)
                            .foregroundStyle(ARCTheme.ink)
                            .padding(.horizontal, h * 0.02).padding(.vertical, h * 0.006)
                            .background(ARCTheme.secCrimson)
                        Text(label)
                            .font(.system(size: h * 0.2, weight: .heavy, design: .monospaced))
                            .foregroundStyle(ARCTheme.text0)
                            .lineLimit(1).minimumScaleFactor(0.3)
                    } else {
                        Text("\(number)")
                            .font(.system(size: h * 0.36, weight: .heavy, design: .monospaced))
                            .foregroundStyle(ARCTheme.text0)
                    }
                    Text("\(number)  \(name)")
                        .font(.system(size: h * 0.06, weight: .bold, design: .monospaced))
                        .foregroundStyle(ARCTheme.text0)
                        .lineLimit(1).minimumScaleFactor(0.4)
                    Text(resolution + (isPrimary ? "  PRIMARY" : "") + (isBuiltIn ? "  BUILT-IN" : ""))
                        .font(.system(size: h * 0.035, weight: .bold, design: .monospaced))
                        .foregroundStyle(ARCTheme.text1)
                    HStack(spacing: h * 0.015) {
                        if roles.isEmpty {
                            Text("NO OUTPUT")
                                .font(.system(size: h * 0.035, weight: .heavy, design: .monospaced))
                                .foregroundStyle(ARCTheme.text1)
                                .padding(.horizontal, h * 0.015).padding(.vertical, h * 0.005)
                                .overlay(Rectangle().strokeBorder(ARCTheme.text2, lineWidth: 2))
                        }
                        ForEach(roles, id: \.self) { r in
                            Text(r)
                                .font(.system(size: h * 0.035, weight: .heavy, design: .monospaced))
                                .foregroundStyle(ARCTheme.ink)
                                .padding(.horizontal, h * 0.015).padding(.vertical, h * 0.005)
                                .background(r == "CONTROL" ? ARCTheme.secOrange : ARCTheme.secCrimson)
                        }
                    }
                    .padding(.top, h * 0.01)
                }
                .padding(h * 0.06)
            }
            // The bracket, at screen scale: a thick rule down the leading edge in OUT crimson.
            .overlay(alignment: .leading) { Rectangle().fill(ARCTheme.secCrimson).frame(width: max(8, h * 0.012)) }
            .overlay(Rectangle().strokeBorder(ARCTheme.secCrimson, lineWidth: max(3, h * 0.004)))
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture { dismiss() }
    }

    /// Framing grid: tenths and corner marks: the picture's edges and centre, readable on any screen.
    private func testGrid(_ size: CGSize) -> some View {
        Canvas { ctx, sz in
            var grid = Path()
            for i in 1..<10 {
                let x = sz.width * CGFloat(i) / 10, y = sz.height * CGFloat(i) / 10
                grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: sz.height))
                grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: sz.width, y: y))
            }
            ctx.stroke(grid, with: .color(ARCTheme.line), lineWidth: 1)
            let m = sz.height * 0.05
            var corners = Path()
            for (x, y, dx, dy) in [(0.0, 0.0, 1.0, 1.0), (sz.width, 0, -1, 1), (0, sz.height, 1, -1), (sz.width, sz.height, -1, -1)] {
                corners.move(to: CGPoint(x: x + dx * m, y: y)); corners.addLine(to: CGPoint(x: x, y: y)); corners.addLine(to: CGPoint(x: x, y: y + dy * m))
            }
            ctx.stroke(corners, with: .color(ARCTheme.warn), lineWidth: 6)
        }
    }
}
#endif

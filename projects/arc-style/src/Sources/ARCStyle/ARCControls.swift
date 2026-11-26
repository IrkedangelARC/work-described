//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

// MARK: - The expanded-controls glyph

/// The slider glyph that means "this module's full controls are elsewhere" (2026-09-19: "add
/// this to every box that has an expanded control set"). One glyph, one meaning, in every ARC app:
/// Presenter's MONITOR opens its layout panel with it, OUTPUTS the SOURCES window, MUSIC its window;
/// Capture's OPTIONS and STATUS open theirs. `on` while the window it opens is open.
public struct ARCExpandButton: View {
    let tip: String
    var on: Bool = false
    /// `band: true` sits in a module's band (smaller, on the band's colour); false sits in a body row.
    var band: Bool = false
    let action: () -> Void

    public init(tip: String, on: Bool = false, band: Bool = false, action: @escaping () -> Void) {
        self.tip = tip; self.on = on; self.band = band; self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: band ? 11 : 15, weight: .heavy))
                .padding(.horizontal, band ? 7 : 9)
                .padding(.vertical, band ? 2 : 8)
                .background(on ? ARCTheme.secBlue : (band ? ARCTheme.ink : ARCTheme.surfaceLight))
                .foregroundStyle(on ? ARCTheme.ink : (band ? ARCTheme.text0 : ARCTheme.textPrimary))
                .cornerRadius(band ? 3 : 4)
        }
        .buttonStyle(.plain)
        .help(tip)
    }
}

public extension View {
    /// The expand glyph at the trailing end of a module's band. Apply AFTER `arcModule`.
    func arcExpandButton(_ tip: String, on: Bool = false, action: @escaping () -> Void) -> some View {
        overlay(alignment: .topTrailing) {
            ARCExpandButton(tip: tip, on: on, band: true, action: action)
                .frame(height: ARCTheme.moduleHeaderH)
                .padding(.trailing, 6)
        }
    }
}

#if canImport(AppKit)
/// A control window behind an expand glyph: the first click opens it, a second click closes it
/// (2026-09-19: "have a 2nd click on the glyph close the window"), and the glyph is lit while
/// it is open. Found by title, since a SwiftUI Window scene's NSWindow carries its title reliably.
@MainActor
public enum ControlWindow {
    public static func isOpen(title: String) -> Bool {
        NSApplication.shared.windows.contains { $0.title == title && $0.isVisible }
    }
    public static func toggle(id: String, title: String, open: OpenWindowAction, dismiss: DismissWindowAction) {
        if isOpen(title: title) { dismiss(id: id) } else { open(id: id) }
    }
}
#endif

// MARK: - Status tiles

/// A readout's state, coloured on the state and its dot, never on a bare code.
public enum ARCStatusLevel { case ok, warn, bad, off }

/// A footer status tile in plain words: a name over a state with a dot (Presenter's STATUS group,
/// 2026-09-19: "make this section more intuitive and clear"). Give `widest` the longest name
/// and state the tile can ever show and its width never changes, so nothing beside it moves.
public struct ARCStatusTile: View {
    let name: String
    let state: String
    let level: ARCStatusLevel
    let widest: (name: String, state: String)?

    public init(name: String, state: String, level: ARCStatusLevel, widest: (name: String, state: String)? = nil) {
        self.name = name; self.state = state; self.level = level; self.widest = widest
    }

    public var body: some View {
        ZStack {
            if let widest { tile(name: widest.name, state: widest.state, level: .off).hidden() }
            tile(name: name, state: state, level: level)
        }
    }

    private func tile(name: String, state: String, level: ARCStatusLevel) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(name).font(ARCTheme.mono(8, .heavy)).foregroundStyle(ARCTheme.text2).lineLimit(1).fixedSize()
            HStack(spacing: 4) {
                Circle().fill(color(level)).frame(width: 6, height: 6)
                Text(state).font(ARCTheme.mono(11, .heavy))
                    .foregroundStyle(level == .off ? ARCTheme.text1 : (level == .ok ? ARCTheme.textPrimary : color(level)))
                    .lineLimit(1).fixedSize().monospacedDigit()
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ARCTheme.surfaceLight)
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(level == .bad ? ARCTheme.liveRed : ARCTheme.line, lineWidth: 1))
        .cornerRadius(4)
    }

    private func color(_ level: ARCStatusLevel) -> Color {
        switch level {
        case .ok: ARCTheme.readyGreen
        case .warn: ARCTheme.warn
        case .bad: ARCTheme.liveRed
        case .off: ARCTheme.text2
        }
    }
}

// MARK: - The action button

/// THE one action on a screen: a solid ARC red fill, heavy mono. Anything else on the screen is a chip.
/// Disabled it drops to the raised grey with a hairline, so it still reads as the place the action is.
public struct ARCActionButton: View {
    let title: String
    var enabled: Bool = true
    var fill: Color = ARCTheme.arcRed
    var size: CGFloat = 15
    let action: () -> Void

    public init(_ title: String, enabled: Bool = true, fill: Color = ARCTheme.arcRed, size: CGFloat = 15, action: @escaping () -> Void) {
        self.title = title; self.enabled = enabled; self.fill = fill; self.size = size; self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Text(title.uppercased())
                .font(ARCTheme.mono(size, .heavy))
                .foregroundStyle(enabled ? .white : ARCTheme.textSecondary)
                .lineLimit(1)
                .padding(.horizontal, 22).padding(.vertical, 12)
                .frame(maxHeight: .infinity)
                .background(enabled ? fill : ARCTheme.surfaceLight)
                .overlay(RoundedRectangle(cornerRadius: ARCTheme.cornerRadius).strokeBorder(enabled ? fill : ARCTheme.line, lineWidth: 1))
                .cornerRadius(ARCTheme.cornerRadius)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

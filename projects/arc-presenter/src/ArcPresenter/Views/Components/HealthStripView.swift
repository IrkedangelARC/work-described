//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI

/// The health chips on the operator footer (stability plan 3.3): PGM, MON,
/// SDI, PPT, CLK, DISK, plus LAG and ERR only when there is something to say.
/// Same struct as `/state.health`; hover for the reason.
struct HealthStripView: View {
    @Environment(HealthMonitor.self) private var health

    /// Four tiles, always the same four, each as wide as its widest state, so STATUS never
    /// changes width (a LAG chip appearing once pushed MONITOR and its panel 55 pt, 2026-09-19).
    /// Plain words (same day: "make this section more intuitive and clear"): a name over a
    /// state; the colour is on the state and its dot, not on a bare three-letter code.
    private static let order = ["ppt", "clk", "app"]   // DISK lives in APP (DISK LOW / DISK FULL) and in the STATUS window: the footer has no room for a fourth tile
    /// The widest word each tile can show, so its width is fixed. Kept short on purpose: the footer is
    /// the console's widest row and a STATUS 200 pt wider squeezed NAVIGATE's counter and OUTPUTS' chips.
    private static let widest: [String: (String, String)] = [
        "ppt": ("POWERPOINT", "OPENING"), "clk": ("CLICKER", "NO ACCESS"), "app": ("APP", "DISK FULL"),
    ]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Self.order, id: \.self) { id in
                let chip = id == "app" ? health.appChip : health.chips.first { $0.id == id }
                ZStack {
                    let w = Self.widest[id] ?? (id.uppercased(), "NO ACCESS")
                    tile(name: w.0, state: w.1, level: .off).hidden()
                    if let chip {
                        tile(name: chip.name, state: chip.state, level: chip.level)
                            .help(id == "clk" ? "Click: clicker on / off for the show (Cmd Opt Shift K). " + (chip.help.isEmpty ? chip.detail : chip.help) : (chip.help.isEmpty ? chip.detail : chip.help))
                            .contentShape(Rectangle())
                            .onTapGesture {
                                // Step 1b: the CLICKER tile is the switch; OFF drops the global tap only.
                                guard id == "clk" else { return }
                                ArcPresenterApp.sharedSourceRouter.globalClickerOn.toggle()
                                health.refresh()
                            }
                    }
                }
            }
        }
    }

    private func tile(name: String, state: String, level: HealthMonitor.Level) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(name).font(ARCTheme.mono(8, .heavy)).foregroundStyle(ARCTheme.text2).lineLimit(1).fixedSize()
            HStack(spacing: 4) {
                Circle().fill(color(level)).frame(width: 6, height: 6)
                Text(state).font(ARCTheme.mono(11, .heavy)).foregroundStyle(level == .off ? ARCTheme.text1 : (level == .ok ? ARCTheme.textPrimary : color(level)))
                    .lineLimit(1).fixedSize().monospacedDigit()
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ARCTheme.surfaceLight)
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(level == .bad ? ARCTheme.liveRed : ARCTheme.line, lineWidth: 1))
        .cornerRadius(4)
    }

    private func color(_ level: HealthMonitor.Level) -> Color {
        switch level {
        case .ok: ARCTheme.readyGreen
        case .warn: ARCTheme.warn
        case .bad: ARCTheme.liveRed
        case .off: ARCTheme.text2
        }
    }
}

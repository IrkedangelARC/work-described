//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI

#if os(macOS)
/// ARC Stage Timer > Settings (Cmd-,). The KEY OVERLAY is here because it is the exception: 99% of shows run
/// CONTROL and the CONFIDENCE MONITOR only (2026-09-24).
struct AppSettingsView: View {
    @State private var placement = ArcStageTimerApp.sharedPlacement

    var body: some View {
        @Bindable var placement = placement
        VStack(alignment: .leading, spacing: ARCTheme.paddingSmall) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: $placement.keyOverlayEnabled) {
                    Text("ENABLE KEY OVERLAY OUTPUT").font(ARCTheme.mono(13, .heavy)).foregroundStyle(ARCTheme.text0)
                }
                .toggleStyle(.switch)
                ARCModuleCaption("The timer as a fill + key layer for an ATEM downstream keyer or PIP. On: a KEY chip in the OUTPUTS strip, GO LIVE includes it, Run Timer offers Key Overlay (DSK / PIP), and the run view's OUTPUTS module has its layout settings (the gear beside KEY).")
                ARCModuleCaption("Off (the default): CONTROL and the CONFIDENCE MONITOR only. A saved KEY OVERLAY display is kept for when it is turned back on.")
            }
            .arcModule(title: "Key overlay (ATEM)", tint: ARCTheme.secCrimson,
                       badge: ARCBandBadge(text: placement.keyOverlayEnabled ? "ON" : "OFF", fill: ARCTheme.ink))

            // The run screen's layouts, one line each (2026-09-24: layouts "should be clear to the operator").
            VStack(alignment: .leading, spacing: 4) {
                ForEach(RunLayout.allCases, id: \.self) { ARCModuleCaption($0.tip) }
                ARCModuleCaption("Switch with the LAYOUT chip at the top of the run screen, or the Show menu.")
            }
            .arcModule(title: "Run screen layouts", tint: ARCTheme.secBlue)
        }
        .padding(ARCTheme.paddingSmall)
        .frame(width: 520)
        .background(ARCTheme.background)
    }
}
#endif

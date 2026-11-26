//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI

#if os(macOS)
import ARCDeckLink

/// "DeckLink Fill+Key (Thunderbolt/ATEM)" controls — enable toggle, device
/// picker, and live status. Shared by the full output-routing panel and the
/// mid-show routing sheet.
struct DeckLinkOutputSection: View {
    @Environment(DeckLinkOutputManager.self) private var deckLink

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                StripButton(title: deckLink.isRunning ? "SDI LIVE" : (deckLink.isStarting ? "STARTING" : "ENABLE"),
                            on: deckLink.isRunning || deckLink.isStarting,
                            tint: deckLink.isRunning ? ARCTheme.live : ARCTheme.secBlue) { deckLink.toggle() }
                    .help("Send the timer overlay as fill+key to the ATEM's downstream keyer over Thunderbolt")
                Picker("", selection: Binding(
                    get: { deckLink.selectedDeviceID },
                    set: { deckLink.selectedDeviceID = $0 }
                )) {
                    Text("First available").tag(Int64(0))
                    ForEach(deckLink.devices) { device in
                        Text(device.name).tag(device.persistentID)
                    }
                }
                .labelsHidden()
                .frame(minWidth: 160, maxWidth: 240)
                .disabled(deckLink.isEnabled)
                StripButton(title: "RESCAN", enabled: !deckLink.isEnabled) { deckLink.refreshDevices() }
                Spacer(minLength: 0)
            }
            if deckLink.isRunning {
                Text("SENT \(deckLink.sentFrames)   DROP \(deckLink.droppedFrames)")
                    .font(ARCTheme.mono(12, .bold)).foregroundStyle(ARCTheme.text1)
            }
            if let error = deckLink.lastError {
                WarningLine(text: error)
            } else if !deckLink.isDriverInstalled {
                WarningLine(text: "Blackmagic Desktop Video driver not installed: DeckLink output unavailable.")
            } else if deckLink.devices.isEmpty {
                WarningLine(text: "No DeckLink output device. Connect the ATEM over Thunderbolt and RESCAN.")
            } else if deckLink.isRunning {
                ARCModuleCaption("1080p\(DeckLinkOutputManager.outputFPS) key to \(deckLink.selectedDeviceName). ATEM DSK: premultiplied linear key on input Thunderbolt.")
            } else {
                ARCModuleCaption("Keys the timer over program on the ATEM DSK; no HDMI input used.")
            }
        }
    }
}
#endif

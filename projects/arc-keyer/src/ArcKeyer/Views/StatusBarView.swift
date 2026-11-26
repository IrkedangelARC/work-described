//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI

/// The footer under the preview: STATUS (state and the capture counters) and OUTPUTS (how many are live),
/// two modules built like the rails' so their bands line up with them.
struct StatusBarView: View {
	@Environment(KeyEngine.self) private var keyEngine
	@Environment(OutputBus.self) private var outputBus

	var body: some View {
		HStack(alignment: .top, spacing: ARCTheme.paddingSmall) {
			HStack(alignment: .top, spacing: ARCTheme.paddingLarge) {
				ARCReadout(label: "STATE", value: keyEngine.state.rawValue.uppercased(), tint: stateColor)
				ARCReadout(label: "FPS", value: String(format: "%.0f", keyEngine.fps))
				ARCReadout(label: "RES", value: keyEngine.captureWidth > 0 ? "\(keyEngine.captureWidth)x\(keyEngine.captureHeight)" : "--")
				ARCReadout(label: "FRAMES", value: "\(keyEngine.frameCount)")
				ARCReadout(label: "DROPPED", value: "\(keyEngine.droppedFrames)",
				           tint: keyEngine.droppedFrames > 0 ? ARCTheme.arcRed : ARCTheme.text0)
				Spacer(minLength: 0)
			}
			.arcModule(title: "STATUS", tint: ARCTheme.secGreen)

			ARCReadout(label: "ACTIVE", value: "\(outputBus.activeCount) OF \(outputBus.adapters.count)",
			           tint: outputBus.activeCount > 0 ? ARCTheme.live : ARCTheme.text0)
				.arcModule(title: "OUTPUTS", tint: ARCTheme.secCrimson, hugging: true)
		}
	}

	private var stateColor: Color {
		switch keyEngine.state {
		case .idle: ARCTheme.text1
		case .ready: ARCTheme.text0
		case .capturing: ARCTheme.live
		case .reconnecting: ARCTheme.warn
		case .error: ARCTheme.arcRed
		}
	}
}

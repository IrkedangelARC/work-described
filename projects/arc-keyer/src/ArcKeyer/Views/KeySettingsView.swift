//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI

/// The right rail's first two modules. KEY: clip and gain with mono readouts, INVERT as a chip that is
/// filled when on. CAPTURE: the source resolution and the frame rate as a two-way segment of chips.
struct KeySettingsView: View {
	@Environment(KeyEngine.self) private var keyEngine
	@Environment(DisplayManager.self) private var displayManager

	var body: some View {
		VStack(spacing: ARCTheme.paddingSmall) {
			VStack(alignment: .leading, spacing: ARCTheme.paddingMedium) {
				slider("CLIP", value: Bindable(keyEngine.keySettings).threshold)
				slider("GAIN", value: Bindable(keyEngine.keySettings).softness)
				HStack(spacing: ARCTheme.paddingSmall) {
					ARCChip("INVERT", tint: ARCTheme.secOrange, on: keyEngine.keySettings.invert) {
						keyEngine.keySettings.invert.toggle()
					}
					Text("white background")
						.font(ARCTheme.mono(11, .regular))
						.foregroundStyle(ARCTheme.text1)
				}
			}
			.arcModule(title: "KEY", tint: ARCTheme.secOrange)

			VStack(alignment: .leading, spacing: ARCTheme.paddingMedium) {
				HStack(alignment: .top) {
					ARCReadout(label: "SOURCE",
					           value: displayManager.sourceDisplay.map { "\($0.width)x\($0.height)" } ?? "--")
					Spacer(minLength: 0)
					VStack(alignment: .leading, spacing: 1) {
						Text("FRAME RATE")
							.font(ARCTheme.mono(10, .heavy))
							.foregroundStyle(ARCTheme.text2)
							.tracking(1)
						HStack(spacing: 2) {
							ForEach(CaptureSettings.FrameRate.allCases) { fps in
								ARCChip(fps.label, tint: ARCTheme.secBlue, on: keyEngine.captureSettings.frameRate == fps) {
									keyEngine.captureSettings.frameRate = fps
								}
							}
						}
					}
				}
			}
			.arcModule(title: "CAPTURE", tint: ARCTheme.secBlue)
		}
	}

	private func slider(_ label: String, value: Binding<Double>) -> some View {
		VStack(alignment: .leading, spacing: 2) {
			HStack {
				Text(label)
					.font(ARCTheme.mono(10, .heavy))
					.foregroundStyle(ARCTheme.text2)
					.tracking(1)
				Spacer()
				Text(String(format: "%.3f", value.wrappedValue))
					.font(ARCTheme.mono(12, .bold))
					.foregroundStyle(ARCTheme.text0)
			}
			Slider(value: value, in: 0...1.0, step: 0.005)
				.tint(ARCTheme.secOrange)
		}
	}
}

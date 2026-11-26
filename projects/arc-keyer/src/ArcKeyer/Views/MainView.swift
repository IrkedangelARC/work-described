//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI

/// The Keyer console. One given quantity, the window; two fixed rails; the preview takes what is left.
///
///     DISPLAYS      | PREVIEW                          | KEY
///     TEST PATTERN  |   FILL          KEY              | CAPTURE
///     CAPTURE       | STATUS ......  OUTPUTS           | OUTPUTS
struct MainView: View {
	@Environment(KeyEngine.self) private var keyEngine
	@Environment(DisplayManager.self) private var displayManager
	@Environment(OutputBus.self) private var outputBus

	var body: some View {
		HStack(spacing: ARCTheme.paddingSmall) {
			DisplayPickerView()
				.frame(width: ARCTheme.leftRailWidth)

			VStack(spacing: ARCTheme.paddingSmall) {
				PreviewView()
				StatusBarView()
					.fixedSize(horizontal: false, vertical: true)
			}

			VStack(spacing: ARCTheme.paddingSmall) {
				KeySettingsView()
				OutputPanelView()
				Spacer(minLength: 0)
			}
			.frame(width: ARCTheme.rightRailWidth)
		}
		.padding(ARCTheme.paddingSmall)
		.frame(minWidth: ARCTheme.windowMin.width, minHeight: ARCTheme.windowMin.height)
		.background(ARCTheme.appGrey)
	}
}

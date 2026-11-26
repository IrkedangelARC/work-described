//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI
import AppKit

@main
struct ArcKeyerApp: App {
	@NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

	static let sharedCaptureEngine = CaptureEngine()
	static let sharedKeyEngine = KeyEngine()
	static let sharedOutputBus = OutputBus()
	static let sharedDisplayManager = DisplayManager()

	init() {
		UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
		Self.sharedKeyEngine.captureEngine = Self.sharedCaptureEngine
		Self.sharedKeyEngine.outputBus = Self.sharedOutputBus
		Self.sharedKeyEngine.displayManager = Self.sharedDisplayManager

		// Register output adapters
		Self.sharedOutputBus.register(KeyDisplayOutput(displayManager: Self.sharedDisplayManager))
		Self.sharedOutputBus.register(DeckLinkOutput(keyEngine: Self.sharedKeyEngine))
	}

	var body: some Scene {
		WindowGroup {
			MainView()
				.preferredColorScheme(.dark)
				.environment(Self.sharedCaptureEngine)
				.environment(Self.sharedKeyEngine)
				.environment(Self.sharedOutputBus)
				.environment(Self.sharedDisplayManager)
				.onAppear {
					Task { await Self.sharedDisplayManager.refreshDisplays() }
					Self.sharedDisplayManager.startMonitoring()
					// Restore output config after app is fully launched
					DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
						Self.sharedOutputBus.restoreConfiguration()
					}
				}
		}
		.defaultSize(width: ARCTheme.windowMin.width, height: ARCTheme.windowMin.height)
		.windowResizability(.contentMinSize)
		.commands {
			CommandMenu("Capture") {
				Button("Start Capture") {
					Task { await Self.sharedKeyEngine.startCapture() }
				}
				.keyboardShortcut("r")

				Button("Stop Capture") {
					Self.sharedKeyEngine.stopCapture()
				}
				.keyboardShortcut(".", modifiers: .command)
			}
		}
	}
}

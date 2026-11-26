//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
	func applicationDidFinishLaunching(_ notification: Notification) {
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
			for window in NSApplication.shared.windows {
				let title = window.title
				if title == "ARC Keyer Key" {
					window.close()
				}
			}
			self.placeConsole()
		}
	}

	/// What the review launch did, for `tools/review.sh` to print (the unified log hides an unsigned-for-logging app's lines).
	private func note(_ line: String) {
		let url = URL(fileURLWithPath: "/private/tmp/arc-keyer-review/app.log")
		let data = ("\(Date()) \(line)\n").data(using: .utf8)!
		if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(data); h.closeFile() }
		else { try? data.write(to: url) }
	}

	/// Launch flags for `tools/review.sh`, which photographs the console with nobody at the keyboard.
	/// `--display N` (1-based, the menu-bar display is 1): the console on that display, filling it.
	/// `--source N`: that display assigned as the SOURCE. `--start`: capture running.
	/// A launch without flags leaves the window where macOS restores it and touches nothing.
	private func placeConsole() {
		let args = CommandLine.arguments
		func value(_ flag: String) -> Int? {
			guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
			return Int(args[i + 1])
		}
		if let n = value("--display"), n >= 1, n <= NSScreen.screens.count,
		   let window = NSApplication.shared.windows.first(where: { $0.isVisible && $0.title != "ARC Keyer Key" }) {
			window.setFrame(NSScreen.screens[n - 1].visibleFrame, display: true)
			window.makeKeyAndOrderFront(nil)
		}
		let source = value("--source")
		let start = args.contains("--start")
		guard source != nil || start else { return }
		Task { @MainActor in
			let dm = ArcKeyerApp.sharedDisplayManager
			await dm.refreshDisplays()
			if let n = source, n >= 1, n <= NSScreen.screens.count,
			   let id = NSScreen.screens[n - 1].deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
			   let display = dm.connectedDisplays.first(where: { $0.displayID == id }) {
				dm.assignSource(display)
			}
			note("source=\(dm.sourceDisplay?.name ?? "nil") start=\(start)")
			if start {
				await ArcKeyerApp.sharedKeyEngine.startCapture()
				note("state=\(ArcKeyerApp.sharedKeyEngine.state.rawValue) error=\(ArcKeyerApp.sharedKeyEngine.errorMessage ?? "none")")
				try? await Task.sleep(for: .seconds(8))
				note("8s later state=\(ArcKeyerApp.sharedKeyEngine.state.rawValue) frames=\(ArcKeyerApp.sharedKeyEngine.frameCount)")
			}
		}
	}

	func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
		true
	}

	func applicationWillTerminate(_ notification: Notification) {
		// Stop capture cleanly — prevents orphan windows and dangling Metal resources
		ArcKeyerApp.sharedKeyEngine.stopCapture()

		// Disable all active outputs (tears down fullscreen key windows)
		for adapter in ArcKeyerApp.sharedOutputBus.activeAdapters {
			ArcKeyerApp.sharedOutputBus.disable(id: adapter.id)
		}

		// Clean up display manager resources
		ArcKeyerApp.sharedDisplayManager.dismissTestPattern()
		ArcKeyerApp.sharedDisplayManager.stopMonitoring()
	}
}

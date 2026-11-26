//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation
import ScreenCaptureKit
import AppKit
import SwiftUI

@MainActor @Observable
final class DisplayManager {

	// MARK: - Display State

	private(set) var connectedDisplays: [DisplaySource] = []
	private(set) var controlDisplay: DisplaySource?
	var sourceDisplay: DisplaySource? {
		didSet {
			if let id = sourceDisplay?.displayID {
				UserDefaults.standard.set(Int(id), forKey: "display.sourceID")
			} else {
				UserDefaults.standard.removeObject(forKey: "display.sourceID")
			}
		}
	}
	var keyOutputDisplay: DisplaySource? {
		didSet {
			if let id = keyOutputDisplay?.displayID {
				UserDefaults.standard.set(Int(id), forKey: "display.keyOutputID")
			} else {
				UserDefaults.standard.removeObject(forKey: "display.keyOutputID")
			}
		}
	}

	// MARK: - Cached SCWindows for exclusion

	private var cachedAppWindows: [SCWindow] = []

	var appWindows: [SCWindow] { cachedAppWindows }

	// MARK: - Hot-plug Monitoring

	private var screenObserver: NSObjectProtocol?

	// MARK: - Computed

	/// Displays available for source assignment (excludes control display)
	var availableForSource: [DisplaySource] {
		connectedDisplays.filter { $0.displayID != controlDisplay?.displayID }
	}

	/// Displays available for key output assignment (excludes control display)
	var availableForKeyOutput: [DisplaySource] {
		connectedDisplays.filter { $0.displayID != controlDisplay?.displayID }
	}

	// MARK: - Enumeration

	func refreshDisplays() async {
		do {
			let content = try await SCShareableContent.current
			let scDisplays = content.displays
			let screens = NSScreen.screens

			// Cache app windows for SCContentFilter exclusion
			let myBundleID = Bundle.main.bundleIdentifier ?? "com.example.arc.ArcKeyer"
			cachedAppWindows = content.windows.filter {
				$0.owningApplication?.bundleIdentifier == myBundleID
			}

			// Cross-reference SCDisplay with NSScreen for names
			var sources: [DisplaySource] = []
			for scDisplay in scDisplays {
				let displayID = scDisplay.displayID
				let matchingScreen = screens.first { screen in
					guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
						return false
					}
					return screenNumber == displayID
				}

				let name = matchingScreen?.localizedName ?? "Display \(displayID)"
				let width = scDisplay.width
				let height = scDisplay.height
				let isMain = matchingScreen == NSScreen.main

				sources.append(DisplaySource(
					displayID: displayID,
					width: width,
					height: height,
					name: name,
					scDisplay: scDisplay,
					isMain: isMain
				))
			}

			connectedDisplays = sources.sorted { lhs, rhs in
				if lhs.isMain != rhs.isMain { return lhs.isMain }
				return lhs.displayID < rhs.displayID
			}

			// Auto-detect control display
			autoDetectControlDisplay()

			// Restore persisted assignments
			restoreAssignments()

			// Validate current assignments still exist
			validateAssignments()
		} catch {
			NSLog("[DisplayManager] Failed to refresh displays: %@", error.localizedDescription)
		}
	}

	// MARK: - Monitoring

	func startMonitoring() {
		screenObserver = NotificationCenter.default.addObserver(
			forName: NSApplication.didChangeScreenParametersNotification,
			object: nil,
			queue: .main
		) { [weak self] _ in
			Task { await self?.refreshDisplays() }
		}
	}

	func stopMonitoring() {
		if let observer = screenObserver {
			NotificationCenter.default.removeObserver(observer)
			screenObserver = nil
		}
	}

	// MARK: - Role Assignment

	func assignSource(_ display: DisplaySource?) {
		// If assigning same display that's currently key output, clear key output
		if let display, display.displayID == keyOutputDisplay?.displayID {
			keyOutputDisplay = nil
		}
		sourceDisplay = display
	}

	func assignKeyOutput(_ display: DisplaySource?) {
		// If assigning same display that's currently source, clear source
		if let display, display.displayID == sourceDisplay?.displayID {
			sourceDisplay = nil
		}
		keyOutputDisplay = display
	}

	/// Role for a given display
	func role(for display: DisplaySource) -> DisplayRole {
		if display.displayID == controlDisplay?.displayID { return .control }
		if display.displayID == sourceDisplay?.displayID { return .source }
		if display.displayID == keyOutputDisplay?.displayID { return .keyOutput }
		return .none
	}

	// MARK: - Test Pattern

	private var testPatternWindow: NSWindow?
	private(set) var isTestPatternActive = false

	func toggleTestPattern() {
		if isTestPatternActive {
			dismissTestPattern()
		} else {
			showTestPattern()
		}
	}

	private func showTestPattern() {
		guard let source = sourceDisplay else { return }
		guard let screen = NSScreen.screens.first(where: { screen in
			guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return false }
			return id == source.displayID
		}) else { return }

		let baseImage = NSImage(named: "LumaKeyTestPattern") ?? Bundle.main.image(forResource: "LumaKeyTestPattern")

		let window = NSWindow(
			contentRect: NSRect(origin: .zero, size: screen.frame.size),
			styleMask: [.borderless],
			backing: .buffered,
			defer: false
		)
		window.isReleasedWhenClosed = false
		window.isOpaque = true
		window.backgroundColor = .black
		window.level = NSWindow.Level(Int(CGShieldingWindowLevel()))
		window.animationBehavior = .none
		window.ignoresMouseEvents = true  // Pure output — clicks pass through
		window.collectionBehavior = [.stationary, .canJoinAllSpaces, .fullScreenAuxiliary]

		// Animated SwiftUI test pattern — TimelineView(.animation) drives a redraw
		// at the display refresh rate (~60Hz on BMD HDMI), giving SCStream constant
		// motion to deliver. Without animation, static content causes SCStream to
		// throttle delivery and FPS stats become misleading.
		let hostingView = NSHostingView(rootView: AnimatedTestPatternView(baseImage: baseImage))
		hostingView.frame = NSRect(origin: .zero, size: screen.frame.size)
		window.contentView = hostingView
		window.setFrame(screen.frame, display: true)
		window.orderFront(nil)

		testPatternWindow = window
		isTestPatternActive = true
	}

	func dismissTestPattern() {
		testPatternWindow?.orderOut(nil)
		testPatternWindow = nil
		isTestPatternActive = false
	}

	// MARK: - Identify Displays

	private var identifyWindows: [NSWindow] = []
	private var identifyDismissWork: DispatchWorkItem?

	func identifyDisplays() {
		// Remove any existing identify windows
		dismissIdentify()

		for display in connectedDisplays {
			guard let screen = NSScreen.screens.first(where: { screen in
				guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return false }
				return id == display.displayID
			}) else { continue }

			let role = role(for: display)
			let roleName = role == .none ? "" : role.rawValue.uppercased()
			let label = display.name
			let resolution = "\(display.width)x\(display.height)"

			let window = NSWindow(
				contentRect: screen.frame,
				styleMask: [.borderless],
				backing: .buffered,
				defer: false
			)
			window.isReleasedWhenClosed = false
			window.level = NSWindow.Level(Int(CGShieldingWindowLevel()) + 1)
			window.backgroundColor = .clear
			window.isOpaque = false
			window.ignoresMouseEvents = true
			window.animationBehavior = .none
			window.collectionBehavior = [.stationary, .canJoinAllSpaces]
			window.setFrame(screen.frame, display: true)

			let hostingView = NSHostingView(rootView: IdentifyOverlayView(
				displayName: label,
				roleName: roleName,
				resolution: resolution
			))
			hostingView.frame = NSRect(origin: .zero, size: screen.frame.size)
			window.contentView = hostingView
			window.orderFront(nil)

			identifyWindows.append(window)
		}

		// Auto-dismiss after 3 seconds (cancellable — safe for rapid calls)
		identifyDismissWork?.cancel()
		let work = DispatchWorkItem { [weak self] in
			self?.dismissIdentify()
		}
		identifyDismissWork = work
		DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
	}

	private func dismissIdentify() {
		identifyDismissWork?.cancel()
		identifyDismissWork = nil
		for window in identifyWindows {
			window.orderOut(nil)
		}
		identifyWindows.removeAll()
	}

	// MARK: - Private

	private func autoDetectControlDisplay() {
		// Control display = the screen containing the app's key window
		if let mainWindow = NSApp.mainWindow,
		   let windowScreen = mainWindow.screen,
		   let screenID = windowScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
			controlDisplay = connectedDisplays.first { $0.displayID == screenID }
		} else {
			// Fallback: main screen (with menu bar)
			controlDisplay = connectedDisplays.first { $0.isMain }
		}
	}

	private func restoreAssignments() {
		// Only restore if no current assignment
		if sourceDisplay == nil,
		   let savedID = UserDefaults.standard.object(forKey: "display.sourceID") as? Int {
			sourceDisplay = connectedDisplays.first { $0.displayID == CGDirectDisplayID(savedID) }
		}
		if keyOutputDisplay == nil,
		   let savedID = UserDefaults.standard.object(forKey: "display.keyOutputID") as? Int {
			keyOutputDisplay = connectedDisplays.first { $0.displayID == CGDirectDisplayID(savedID) }
		}
	}

	private func validateAssignments() {
		let ids = Set(connectedDisplays.map(\.displayID))
		if let src = sourceDisplay, !ids.contains(src.displayID) {
			sourceDisplay = nil
		}
		if let key = keyOutputDisplay, !ids.contains(key.displayID) {
			keyOutputDisplay = nil
		}
	}
}

// MARK: - Display Role

enum DisplayRole: String {
	case control = "Control"
	case source = "Source"
	case keyOutput = "Key Output"
	case none = "None"
}

// MARK: - Animated Test Pattern

/// Full-screen test pattern that redraws every display frame via TimelineView(.animation).
/// Provides constant motion so SCStream delivers frames at the display refresh rate
/// instead of throttling for static content. Use this to validate the capture/key
/// pipeline at the rig's true frame rate.
///
/// All animated elements are drawn through a single SwiftUI Canvas — Core Graphics
/// renders directly to one layer with no view-tree diffing. An earlier ForEach-based
/// implementation generated SwiftUI diff overhead that starved the capture thread
/// after ~15 seconds; Canvas avoids that entirely.
///
/// Animated elements:
///   - Color-cycling top + bottom bands (every pixel changes every frame)
///   - Sweeping vertical bar traveling left→right at 1 cycle/sec
///   - Black/white flicker square in top-left corner (slow-mo drop detection)
///   - Frame counter / elapsed-time HUD in bottom-right
///   - Underlying calibration chart drawn once as a backdrop
struct AnimatedTestPatternView: View {
	let baseImage: NSImage?

	private let startDate = Date()

	var body: some View {
		TimelineView(.animation) { context in
			let elapsed = context.date.timeIntervalSince(startDate)
			let frameIndex = Int(elapsed * 60)

			Canvas { ctx, size in
				// Black background
				ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))

				// Calibration chart backdrop (centered, fit aspect)
				if let baseImage, let cgImage = baseImage.cgImage(forProposedRect: nil, context: nil, hints: nil) {
					let imgW = CGFloat(cgImage.width)
					let imgH = CGFloat(cgImage.height)
					let scale = min(size.width / imgW, size.height / imgH)
					let drawW = imgW * scale
					let drawH = imgH * scale
					let drawRect = CGRect(
						x: (size.width - drawW) / 2,
						y: (size.height - drawH) / 2,
						width: drawW,
						height: drawH
					)
					ctx.draw(Image(nsImage: baseImage), in: drawRect)
				}

				// Top + bottom color-cycling bands — 32 hue blocks each, cycling per frame
				let bandHeight = size.height * 0.04
				let blockWidth = size.width / 32
				for i in 0..<32 {
					let hueTop = Double((frameIndex + i * 3) % 360) / 360.0
					let hueBot = Double((frameIndex + i * 3 + 119) % 360) / 360.0
					ctx.fill(
						Path(CGRect(x: CGFloat(i) * blockWidth, y: 0, width: blockWidth, height: bandHeight)),
						with: .color(Color(hue: hueTop, saturation: 1, brightness: 1))
					)
					ctx.fill(
						Path(CGRect(x: CGFloat(i) * blockWidth, y: size.height - bandHeight, width: blockWidth, height: bandHeight)),
						with: .color(Color(hue: hueBot, saturation: 1, brightness: 1))
					)
				}

				// Sweeping vertical bar — 1 full traversal per second
				let cycle = elapsed.truncatingRemainder(dividingBy: 1.0)
				let barX = cycle * size.width
				let barWidth = max(4, size.width * 0.008)
				ctx.fill(
					Path(CGRect(x: barX - barWidth / 2, y: 0, width: barWidth, height: size.height)),
					with: .color(.white)
				)

				// Rotating color wheel + bouncing ball (see drawAccents)
				Self.drawAccents(into: &ctx, size: size, elapsed: elapsed)

				// Per-frame flicker square (top-left)
				let flickerSize = size.width * 0.04
				ctx.fill(
					Path(CGRect(x: flickerSize, y: flickerSize, width: flickerSize, height: flickerSize)),
					with: .color(frameIndex % 2 == 0 ? .white : .black)
				)

				// Frame counter / timestamp HUD (bottom-right)
				let hudText = Text(verbatim: String(format: "T %7.2f s\nF %010d", elapsed, frameIndex))
					.font(.system(size: 36, weight: .bold, design: .monospaced))
					.foregroundColor(.white)
				let resolved = ctx.resolve(hudText)
				let hudSize = resolved.measure(in: size)
				let hudPad: CGFloat = 16
				let hudRect = CGRect(
					x: size.width - hudSize.width - hudPad * 2 - 32,
					y: size.height - hudSize.height - hudPad * 2 - 32,
					width: hudSize.width + hudPad * 2,
					height: hudSize.height + hudPad * 2
				)
				ctx.fill(Path(roundedRect: hudRect, cornerRadius: 8), with: .color(.black.opacity(0.7)))
				ctx.draw(
					resolved,
					at: CGPoint(x: hudRect.minX + hudPad, y: hudRect.minY + hudPad),
					anchor: .topLeading
				)
			}
			.ignoresSafeArea()
		}
	}

	/// Helper — pulled out of the main Canvas closure so the Swift type checker
	/// doesn't time out on the monolithic expression tree.
	private static func drawAccents(
		into ctx: inout GraphicsContext,
		size: CGSize,
		elapsed: TimeInterval
	) {
		let minDim = min(size.width, size.height)

		// Rotating RGB color wheel (conic gradient, single draw call)
		let wheelR = minDim * 0.09
		let wheelCX = size.width * 0.15
		let wheelCY = size.height * 0.25
		let wheelRect = CGRect(
			x: wheelCX - wheelR, y: wheelCY - wheelR,
			width: wheelR * 2, height: wheelR * 2
		)
		let wheelPath = Path(ellipseIn: wheelRect)
		ctx.fill(
			wheelPath,
			with: .conicGradient(
				Gradient(colors: [
					.red, .yellow, .green, .cyan, .blue,
					Color(red: 1, green: 0, blue: 1), .red,
				]),
				center: CGPoint(x: wheelCX, y: wheelCY),
				angle: .degrees(elapsed * 45)
			)
		)
		ctx.stroke(wheelPath, with: .color(.white), lineWidth: 2)

		// Bouncing ball — free orbit through screen
		let ballR = minDim * 0.025
		let ballX = size.width * 0.5 + CGFloat(cos(elapsed * 0.9)) * size.width * 0.4
		let ballY = size.height * 0.5 + CGFloat(sin(elapsed * 1.3)) * size.height * 0.35
		let ballRect = CGRect(
			x: ballX - ballR, y: ballY - ballR,
			width: ballR * 2, height: ballR * 2
		)
		let ballPath = Path(ellipseIn: ballRect)
		ctx.fill(ballPath, with: .color(.yellow))
		ctx.stroke(ballPath, with: .color(.white), lineWidth: 2)
	}
}

// MARK: - Identify Overlay

struct IdentifyOverlayView: View {
	let displayName: String
	let roleName: String
	let resolution: String

	var body: some View {
		ZStack {
			Color.black.opacity(0.75)

			VStack(spacing: 12) {
				Text(displayName)
					.font(.system(size: 72, weight: .bold, design: .monospaced))
					.foregroundStyle(.white)

				if !roleName.isEmpty {
					Text(roleName)
						.font(.system(size: 36, weight: .semibold, design: .monospaced))
						.foregroundStyle(roleColor)
				}

				Text(resolution)
					.font(.system(size: 24, weight: .regular, design: .monospaced))
					.foregroundStyle(.white.opacity(0.5))
			}
		}
		.ignoresSafeArea()
	}

	private var roleColor: Color {
		switch roleName {
		case "SOURCE": return ARCTheme.roleSource
		case "KEY OUTPUT": return ARCTheme.roleKeyOutput
		case "CONTROL": return ARCTheme.roleControl
		default: return .white
		}
	}
}

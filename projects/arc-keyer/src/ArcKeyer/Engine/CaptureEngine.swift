//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation
import ScreenCaptureKit
import CoreMedia
import AppKit
import IOKit.pwr_mgt

@Observable
final class CaptureEngine: NSObject {

	// MARK: - State

	enum State: String {
		case idle
		case ready
		case capturing
		case reconnecting
		case error
	}

	private(set) var state: State = .idle
	private(set) var errorMessage: String?

	// MARK: - Stream

	private var stream: SCStream?
	private var streamOutput: StreamOutputDelegate?

	// MARK: - Frame Delivery

	var onFrame: ((CMSampleBuffer) -> Void)?

	// MARK: - Configuration

	var captureFrameRate: Int = 30
	var captureWidth: Int = 1920
	var captureHeight: Int = 1080

	// MARK: - Auto-Reconnect

	private var reconnectTimer: Timer?
	private var reconnectAttempts: Int = 0
	private let maxReconnectAttempts = 20
	private let reconnectInterval: TimeInterval = 2.0
	private(set) var lastCapturedDisplayID: CGDirectDisplayID?
	private var lastExcludedWindows: [SCWindow] = []

	// MARK: - Sleep Prevention (IOKit power assertion)

	private var sleepAssertionID: IOPMAssertionID = 0
	private var hasSleepAssertion: Bool = false

	// MARK: - Display Capture

	func startCapture(display: DisplaySource, excludingWindows: [SCWindow]) async throws {
		guard let scDisplay = display.scDisplay else {
			throw CaptureError.invalidSource
		}

		stopReconnectTimer()
		lastCapturedDisplayID = display.displayID
		lastExcludedWindows = excludingWindows

		// Use source display's native resolution
		captureWidth = display.width
		captureHeight = display.height

		let filter = SCContentFilter(display: scDisplay, excludingWindows: excludingWindows)
		let config = SCStreamConfiguration()
		config.width = captureWidth
		config.height = captureHeight
		config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(captureFrameRate))
		config.pixelFormat = kCVPixelFormatType_32BGRA
		config.queueDepth = 3
		config.showsCursor = false

		let delegate = StreamOutputDelegate { [weak self] sampleBuffer in
			self?.onFrame?(sampleBuffer)
		}
		self.streamOutput = delegate

		let newStream = SCStream(filter: filter, configuration: config, delegate: self)
		try newStream.addStreamOutput(delegate, type: .screen, sampleHandlerQueue: DispatchQueue(
			label: "com.example.arc.arckeyer.capture",
			qos: .userInteractive
		))
		try await newStream.startCapture()
		self.stream = newStream
		self.state = .capturing
		self.reconnectAttempts = 0
		preventSleep()
	}

	// MARK: - Stop Capture

	func stopCapture() {
		stopReconnectTimer()
		// Nil the delegate first — prevents callbacks on freed objects
		self.streamOutput = nil
		allowSleep()
		guard let stream else {
			self.state = .ready
			return
		}
		Task {
			try? await stream.stopCapture()
		}
		self.stream = nil
		self.state = .ready
	}

	// MARK: - Auto-Reconnect

	private func beginReconnect() {
		guard state != .reconnecting else { return }
		// Nil the delegate first to prevent callbacks during teardown
		streamOutput = nil
		stream = nil
		state = .reconnecting
		reconnectAttempts = 0
		NSLog("[CaptureEngine] Beginning reconnect sequence for display %u", lastCapturedDisplayID ?? 0)
		startReconnectTimer()
	}

	private func startReconnectTimer() {
		stopReconnectTimer()
		let timer = Timer(timeInterval: reconnectInterval, repeats: true) { [weak self] _ in
			Task { @MainActor [weak self] in
				await self?.attemptReconnect()
			}
		}
		RunLoop.main.add(timer, forMode: .common)
		reconnectTimer = timer
	}

	private func stopReconnectTimer() {
		reconnectTimer?.invalidate()
		reconnectTimer = nil
	}

	@MainActor private func attemptReconnect() async {
		reconnectAttempts += 1
		if reconnectAttempts > maxReconnectAttempts {
			stopReconnectTimer()
			state = .error
			errorMessage = "Source display lost — reconnect timed out"
			allowSleep()
			return
		}

		do {
			let content = try await SCShareableContent.current
			guard let displayID = lastCapturedDisplayID,
			      let scDisplay = content.displays.first(where: { $0.displayID == displayID }) else {
				return
			}

			// Refresh excluded windows
			let myBundleID = Bundle.main.bundleIdentifier ?? "com.example.arc.ArcKeyer"
			let excludedWindows = content.windows.filter {
				$0.owningApplication?.bundleIdentifier == myBundleID
			}

			// Rebuild DisplaySource from SCDisplay + NSScreen
			let screens = NSScreen.screens
			let matchingScreen = screens.first { screen in
				guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
					return false
				}
				return screenNumber == displayID
			}

			let source = DisplaySource(
				displayID: displayID,
				width: scDisplay.width,
				height: scDisplay.height,
				name: matchingScreen?.localizedName ?? "Display \(displayID)",
				scDisplay: scDisplay,
				isMain: matchingScreen == NSScreen.main
			)

			try await startCapture(display: source, excludingWindows: excludedWindows)
		} catch {
			// Will retry on next timer tick
		}
	}

	// MARK: - Sleep Prevention

	/// Prevent display sleep and screensaver while capture is active.
	/// One show saw the screensaver kick in mid-show; arc-presenter v2.4.0 fixed
	/// the same class of bug. Ported here for show readiness.
	private func preventSleep() {
		guard !hasSleepAssertion else { return }
		let result = IOPMAssertionCreateWithName(
			kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
			IOPMAssertionLevel(kIOPMAssertionLevelOn),
			"ARC Keyer Live Show" as CFString,
			&sleepAssertionID
		)
		if result == kIOReturnSuccess {
			hasSleepAssertion = true
			NSLog("ARC Keyer: Sleep prevention enabled — display will stay on.")
		}
	}

	private func allowSleep() {
		guard hasSleepAssertion else { return }
		IOPMAssertionRelease(sleepAssertionID)
		hasSleepAssertion = false
		NSLog("ARC Keyer: Sleep prevention released.")
	}

	deinit {
		// Safety net — if the engine is deallocated mid-capture, release the assertion
		// so it doesn't outlive the process and pin the display awake forever.
		if hasSleepAssertion {
			IOPMAssertionRelease(sleepAssertionID)
		}
	}

	// MARK: - Errors

	enum CaptureError: LocalizedError {
		case invalidSource
		case permissionDenied

		var errorDescription: String? {
			switch self {
			case .invalidSource: "Selected display is no longer available"
			case .permissionDenied: "Screen recording permission is required"
			}
		}
	}
}

// MARK: - SCStreamDelegate (stream error / display disconnected detection)

extension CaptureEngine: SCStreamDelegate {
	func stream(_ stream: SCStream, didStopWithError error: any Error) {
		NSLog("[CaptureEngine] Stream stopped with error: %@", error.localizedDescription)
		Task { @MainActor in
			self.beginReconnect()
		}
	}
}

// MARK: - Stream Output Delegate

private final class StreamOutputDelegate: NSObject, SCStreamOutput {
	let handler: (CMSampleBuffer) -> Void

	init(handler: @escaping (CMSampleBuffer) -> Void) {
		self.handler = handler
	}

	func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
		guard type == .screen, sampleBuffer.isValid,
		      CMSampleBufferGetImageBuffer(sampleBuffer) != nil else { return }
		handler(sampleBuffer)
	}
}

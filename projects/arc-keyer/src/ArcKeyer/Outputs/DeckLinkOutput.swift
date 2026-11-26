//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation
import CoreVideo
import CoreMedia
import ARCDeckLink

// MARK: - DeckLink Fill+Key Output

/// Sends fill+key to a Blackmagic DeckLink playback device via the shared
/// ARCDeckLink package — including the ATEM Mini Extreme ISO G2 over
/// Thunderbolt, where external keyer mode lands the graphics directly in the
/// switcher's keyers without consuming an HDMI input.
///
/// The DeckLink output is started lazily on the first frame so it can match
/// the incoming buffer dimensions (the Metal pipeline emits at CAPTURE
/// resolution, which may not be 1920x1080). If the device has no matching
/// display mode, start fails once and retries are throttled — no per-frame
/// hammering, no crash.
final class DeckLinkOutput: OutputAdapter {
	let id = "decklink-fillkey"
	let name = "DeckLink Fill+Key (ATEM)"
	let category: OutputCategory = .hardware
	var isActive = false
	var statusMessage: String?

	/// Read for the capture frame rate at lazy-start time.
	weak var keyEngine: KeyEngine?

	/// Devices found on the last refresh. Cached deliberately — enumerating
	/// COM devices from `isAvailable` during a SwiftUI layout pass is what
	/// crashed the 2026-04 DeckLink attempt. Written on main, read on the
	/// capture thread in `startOutput` — both under `stateLock`.
	private(set) var devices: [DeckLinkDevice] = []

	var isAvailable: Bool {
		DeckLinkFillKeyOutput.isDriverInstalled && !devices.isEmpty
	}

	/// Selected device (0 = first available). Persisted; changing it tears
	/// down the running output so the next frame restarts on the new device.
	var devicePersistentID: Int64 {
		didSet {
			guard devicePersistentID != oldValue else { return }
			var config = OutputConfiguration.load()
			config.deckLinkDevicePersistentID = devicePersistentID
			config.save()
			stateLock.lock()
			output?.stop()
			output = nil
			lastStartFailure = nil
			stateLock.unlock()
		}
	}

	// MARK: - Stats (read by OutputPanelView)

	var sentFrames: Int { output?.sentFrames ?? 0 }
	var droppedFrames: Int { output?.droppedFrames ?? 0 }
	var lastErrorMessage: String? { output?.lastErrorMessage }

	// MARK: - Private State

	/// Guards `output` — sendFrame runs on the capture thread while
	/// start/stop/device changes come from the main thread.
	private let stateLock = NSLock()
	private var output: DeckLinkFillKeyOutput?
	private var startedWidth = 0
	private var startedHeight = 0
	private var lastStartFailure: Date?

	/// Minimum interval between start attempts after a failure (e.g. no
	/// display mode matching a 4K capture).
	private static let retryInterval: TimeInterval = 3.0

	init(keyEngine: KeyEngine) {
		self.keyEngine = keyEngine
		self.devicePersistentID = OutputConfiguration.load().deckLinkDevicePersistentID
		refreshDevices()
	}

	/// Re-enumerate connected DeckLink devices (called by the panel's refresh
	/// button and at init).
	func refreshDevices() {
		let found = DeckLinkFillKeyOutput.devices()
		stateLock.lock()
		devices = found
		stateLock.unlock()
	}

	// MARK: - OutputAdapter

	func start() throws {
		guard DeckLinkFillKeyOutput.isDriverInstalled else {
			throw OutputError.noDevice("Desktop Video driver not installed")
		}
		refreshDevices()
		guard !devices.isEmpty else {
			throw OutputError.noDevice("No DeckLink output device connected")
		}
		// Actual DeckLink start is deferred to the first frame — the output
		// mode must match the incoming buffer dimensions, which aren't known
		// until capture delivers a frame.
		lastStartFailure = nil
		isActive = true
		statusMessage = "Waiting for frames"
	}

	func stop() {
		stateLock.lock()
		output?.stop()
		output = nil
		startedWidth = 0
		startedHeight = 0
		lastStartFailure = nil
		stateLock.unlock()
		isActive = false
		statusMessage = nil
	}

	func sendFrame(fill: CVPixelBuffer, key: CVPixelBuffer, timestamp: CMTime) {
		let width = CVPixelBufferGetWidth(fill)
		let height = CVPixelBufferGetHeight(fill)

		stateLock.lock()
		defer { stateLock.unlock() }

		if let output, output.isRunning {
			if width == startedWidth && height == startedHeight {
				output.send(fill: fill, key: key)
				return
			}
			// Capture resolution changed — restart at the new size
			output.stop()
			self.output = nil
		}

		// Lazy start at incoming frame dimensions, throttled after failure
		if let lastFailure = lastStartFailure,
		   Date().timeIntervalSince(lastFailure) < Self.retryInterval {
			return
		}
		startOutput(width: width, height: height)
		if let output, output.isRunning {
			output.send(fill: fill, key: key)
		}
	}

	// MARK: - Private

	/// Must be called with `stateLock` held.
	private func startOutput(width: Int, height: Int) {
		let fps = Double(keyEngine?.captureSettings.frameRate.rawValue ?? 60)
		let out = DeckLinkFillKeyOutput()
		do {
			try out.start(devicePersistentID: devicePersistentID,
			              width: width, height: height, fps: fps,
			              keyer: .externalKey)
			output = out
			startedWidth = width
			startedHeight = height
			lastStartFailure = nil
			let deviceName = devices.first { $0.persistentID == devicePersistentID }?.name
				?? devices.first?.name ?? "DeckLink"
			updateStatus("\(deviceName) (\(width)x\(height) @ \(Int(fps)))")
			NSLog("[DeckLinkOutput] Started %@ %dx%d @ %.0f fps (external key)", deviceName, width, height, fps)
		} catch {
			lastStartFailure = Date()
			updateStatus(error.localizedDescription)
			NSLog("[DeckLinkOutput] Start failed: %@", error.localizedDescription)
		}
	}

	/// statusMessage is read by SwiftUI — hop to main when set from the
	/// capture thread.
	private func updateStatus(_ message: String) {
		DispatchQueue.main.async { [weak self] in
			self?.statusMessage = message
		}
	}
}

//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation
import CoreMedia
import CoreVideo
import AppKit
import Metal
import QuartzCore

@Observable
final class KeyEngine {

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

	// MARK: - Stats

	private(set) var fps: Double = 0
	private(set) var captureWidth: Int = 0
	private(set) var captureHeight: Int = 0
	private(set) var frameCount: UInt64 = 0
	private(set) var droppedFrames: UInt64 = 0

	// MARK: - Settings

	let keySettings = KeySettings()
	let captureSettings = CaptureSettings()

	// MARK: - Engine References

	var captureEngine: CaptureEngine?
	var outputBus: OutputBus?
	var displayManager: DisplayManager?

	// MARK: - Metal

	private var metalPipeline: MetalPipeline?

	// MARK: - FPS Tracking

	private var fpsTimer: DispatchSourceTimer?
	private var framesSinceLastTick: Int = 0
	private var previewSkipCount: Int = 0

	// MARK: - Preview Rendering (Metal-backed, no CGImage)

	/// Shared Metal device for preview layers. Created once, shared with MetalPreviewView.
	private(set) var previewDevice: MTLDevice?
	private var previewQueue: MTLCommandQueue?
	private var previewTextureCache: CVMetalTextureCache?

	/// Guards against rendering after teardown has started.
	/// Set to true before nilling Metal resources so the capture thread
	/// doesn't access freed objects.
	private var previewTornDown = false

	/// Weak refs to preview CAMetalLayers — set by MetalPreviewView on creation.
	weak var fillPreviewLayer: CAMetalLayer?
	weak var keyPreviewLayer: CAMetalLayer?

	// MARK: - Sleep Prevention

	private var sleepActivity: NSObjectProtocol?

	// MARK: - Lifecycle

	func startCapture() async {
		guard let captureEngine, let displayManager else {
			state = .error
			errorMessage = "No source display assigned"
			return
		}

		// Gather @MainActor-isolated DisplayManager data on the main actor
		let (sourceDisplay, excludedWindows) = await MainActor.run {
			(displayManager.sourceDisplay, displayManager.appWindows)
		}

		guard let sourceDisplay else {
			state = .error
			errorMessage = "No source display assigned"
			return
		}

		do {
			metalPipeline = try MetalPipeline()
			setupPreviewRenderer()
		} catch {
			state = .error
			errorMessage = error.localizedDescription
			return
		}

		// Frame rate from settings, resolution from source display
		captureEngine.captureFrameRate = captureSettings.frameRate.rawValue

		captureEngine.onFrame = { [weak self] sampleBuffer in
			self?.processFrame(sampleBuffer)
		}

		do {
			try await captureEngine.startCapture(display: sourceDisplay, excludingWindows: excludedWindows)
			state = .capturing
			// Activate outputs that were saved from last session — deferred until
			// capture is running so we don't put orphan windows on displays.
			// Must run on MainActor because OutputAdapter.isAvailable touches @MainActor state.
			await MainActor.run { outputBus?.activatePendingOutputs() }
			startFPSTimer()
			enableSleepPrevention()
		} catch {
			state = .error
			errorMessage = error.localizedDescription
		}
	}

	func stopCapture() {
		// 1. Nil the callback FIRST — prevents new frames from entering processFrame
		//    while we tear down resources. The capture thread may still be mid-frame,
		//    but processFrame guards against nil pipeline.
		captureEngine?.onFrame = nil
		// 2. Stop the stream (async internally, but no more callbacks after onFrame = nil)
		captureEngine?.stopCapture()
		// 3. Tear down Metal resources AFTER frame delivery is stopped
		teardownPreviewRenderer()
		metalPipeline = nil
		state = .ready
		fps = 0
		stopFPSTimer()
		disableSleepPrevention()
	}

	// MARK: - Frame Processing

	private func processFrame(_ sampleBuffer: CMSampleBuffer) {
		autoreleasepool {
			guard state == .capturing, let pipeline = metalPipeline else { return }

			let params = keySettings.metalParams

			guard let result = pipeline.processFrame(sampleBuffer: sampleBuffer, params: params) else {
				droppedFrames += 1
				return
			}

			frameCount += 1
			framesSinceLastTick += 1

			let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

			// Update resolution stats (cheap, no allocation)
			let w = CVPixelBufferGetWidth(result.fill)
			let h = CVPixelBufferGetHeight(result.fill)
			if captureWidth != w || captureHeight != h {
				DispatchQueue.main.async { [weak self] in
					self?.captureWidth = w
					self?.captureHeight = h
				}
			}

			// Render preview directly to Metal layers — no CGImage, no SwiftUI image pipeline.
			// Throttled to ~10fps to avoid overloading the preview drawable pool.
			previewSkipCount += 1
			if previewSkipCount >= 3 {
				previewSkipCount = 0
				renderPreview(fill: result.fill, key: result.key)
			}

			// Fan out to all active outputs at full frame rate
			outputBus?.sendFrame(fill: result.fill, key: result.key, timestamp: timestamp)
		}
	}

	// MARK: - Preview Renderer Setup

	private func setupPreviewRenderer() {
		guard previewDevice == nil else { return }
		guard let device = MTLCreateSystemDefaultDevice() else { return }
		previewDevice = device
		previewQueue = device.makeCommandQueue()
		var cache: CVMetalTextureCache?
		let status = CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
		guard status == kCVReturnSuccess, let cache else {
			NSLog("[KeyEngine] Failed to create preview texture cache: %d", status)
			previewDevice = nil
			previewQueue = nil
			return
		}
		previewTextureCache = cache
		previewTornDown = false
	}

	private func teardownPreviewRenderer() {
		// Signal capture thread to stop rendering BEFORE nilling resources
		previewTornDown = true
		fillPreviewLayer = nil
		keyPreviewLayer = nil
		if let cache = previewTextureCache {
			CVMetalTextureCacheFlush(cache, 0)
		}
		previewTextureCache = nil
		previewQueue = nil
		previewDevice = nil
	}

	/// Blit CVPixelBuffers directly to preview CAMetalLayers on the capture thread.
	/// CAMetalLayer.nextDrawable() and Metal command buffers are thread-safe.
	private func renderPreview(fill: CVPixelBuffer, key: CVPixelBuffer) {
		guard !previewTornDown else { return }
		if let layer = fillPreviewLayer {
			blitToLayer(layer, pixelBuffer: fill)
		}
		if let layer = keyPreviewLayer {
			blitToLayer(layer, pixelBuffer: key)
		}
	}

	private func blitToLayer(_ layer: CAMetalLayer, pixelBuffer: CVPixelBuffer) {
		let width = CVPixelBufferGetWidth(pixelBuffer)
		let height = CVPixelBufferGetHeight(pixelBuffer)

		// Match drawable to source resolution — CAMetalLayer auto-scales for display.
		// Without this, the small preview drawable only shows the top-left corner.
		let sourceSize = CGSize(width: width, height: height)
		if layer.drawableSize != sourceSize {
			layer.drawableSize = sourceSize
		}

		guard let queue = previewQueue, let cache = previewTextureCache,
		      let drawable = layer.nextDrawable() else { return }

		var cvTexture: CVMetalTexture?
		CVMetalTextureCacheCreateTextureFromImage(nil, cache, pixelBuffer, nil,
		                                          .bgra8Unorm, width, height, 0, &cvTexture)
		guard let cvTex = cvTexture,
		      let srcTexture = CVMetalTextureGetTexture(cvTex),
		      let commandBuffer = queue.makeCommandBuffer(),
		      let blitEncoder = commandBuffer.makeBlitCommandEncoder() else { return }

		let destTexture = drawable.texture
		let copyWidth = min(srcTexture.width, destTexture.width)
		let copyHeight = min(srcTexture.height, destTexture.height)

		blitEncoder.copy(
			from: srcTexture, sourceSlice: 0, sourceLevel: 0,
			sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
			sourceSize: MTLSize(width: copyWidth, height: copyHeight, depth: 1),
			to: destTexture, destinationSlice: 0, destinationLevel: 0,
			destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
		)
		blitEncoder.endEncoding()

		commandBuffer.present(drawable)
		commandBuffer.commit()
	}

	// MARK: - FPS Timer

	private func startFPSTimer() {
		let timer = DispatchSource.makeTimerSource(queue: .main)
		timer.schedule(deadline: .now(), repeating: 1.0)
		timer.setEventHandler { [weak self] in
			guard let self else { return }
			self.fps = Double(self.framesSinceLastTick)
			self.framesSinceLastTick = 0
		}
		timer.resume()
		fpsTimer = timer
	}

	private func stopFPSTimer() {
		fpsTimer?.cancel()
		fpsTimer = nil
	}

	// MARK: - Sleep Prevention

	private func enableSleepPrevention() {
		sleepActivity = ProcessInfo.processInfo.beginActivity(
			options: [.idleDisplaySleepDisabled, .idleSystemSleepDisabled],
			reason: "ARC Keyer capture in progress"
		)
	}

	private func disableSleepPrevention() {
		if let activity = sleepActivity {
			ProcessInfo.processInfo.endActivity(activity)
			sleepActivity = nil
		}
	}
}

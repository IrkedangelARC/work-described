//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation
import CoreVideo
import CoreMedia
import AppKit
import Metal
import QuartzCore

// MARK: - Metal-backed NSView

/// NSView subclass that uses CAMetalLayer as its backing layer.
/// Apple-recommended pattern — avoids use-after-free crashes
/// from replacing contentView.layer directly.
final class MetalLayerView: NSView {
	/// Stored reference set during init, before wantsLayer triggers makeBackingLayer.
	private let _device: MTLDevice

	var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

	init(device: MTLDevice, frame: NSRect) {
		self._device = device
		super.init(frame: frame)
		wantsLayer = true
		// Layer is now created via makeBackingLayer — configure it
		metalLayer.drawableSize = frame.size
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) { fatalError() }

	override func makeBackingLayer() -> CALayer {
		let layer = CAMetalLayer()
		layer.device = _device
		layer.pixelFormat = .bgra8Unorm
		layer.framebufferOnly = true
		layer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
		return layer
	}
}

// MARK: - Key Display Output

/// Renders the key (matte) signal to a fullscreen borderless window on the assigned key output display.
/// Target display is managed by DisplayManager — no per-adapter screen picker needed.
///
/// Window level is cooperative (not CGShieldingWindowLevel) so other AV apps
/// (Stage Timer, etc.) can naturally layer above the key output. When another
/// app occludes the output window, rendering pauses and `isYielded` is set.
final class KeyDisplayOutput: OutputAdapter {
	let id = "display-key"
	let name = "Key Display Output"
	let category: OutputCategory = .display
	var isActive = false
	var statusMessage: String?

	/// True when the key output window is fully occluded by another app's window.
	/// Frame rendering is paused to save GPU while yielded.
	private(set) var isYielded = false

	weak var displayManager: DisplayManager?

	var isAvailable: Bool {
		MainActor.assumeIsolated { displayManager?.keyOutputDisplay != nil }
	}

	private var outputWindow: NSWindow?
	private var metalView: MetalLayerView?
	private var metalDevice: MTLDevice?
	private var commandQueue: MTLCommandQueue?
	private var textureCache: CVMetalTextureCache?
	private var occlusionObserver: NSObjectProtocol?

	/// High window level ensures reliable rendering on BMD HDMI outputs.
	/// ignoresMouseEvents prevents the user from getting trapped.
	private static let keyOutputWindowLevel = NSWindow.Level(Int(CGShieldingWindowLevel()))

	init(displayManager: DisplayManager) {
		self.displayManager = displayManager
	}

	func start() throws {
		// Already running — nothing to do. Calling stop()+start() in the same
		// run loop iteration causes use-after-free: freed window objects remain
		// in the autorelease pool and crash when the pool drains.
		guard outputWindow == nil else { return }

		guard let display = MainActor.assumeIsolated({ displayManager?.keyOutputDisplay }) else {
			throw OutputError.noDevice("No key output display assigned")
		}

		guard let device = MTLCreateSystemDefaultDevice() else {
			throw OutputError.noDevice("No Metal device")
		}
		self.metalDevice = device
		self.commandQueue = device.makeCommandQueue()

		var cache: CVMetalTextureCache?
		CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
		self.textureCache = cache

		// Find matching NSScreen for this display
		let screens = NSScreen.screens
		guard let screen = screens.first(where: { screen in
			guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
				return false
			}
			return screenNumber == display.displayID
		}) else {
			throw OutputError.noDevice("Key output display not found")
		}

		// Wrap view+window creation in autoreleasepool — AppKit creates temporary
		// autoreleased objects when setting up CAMetalLayer-backed views. Draining
		// immediately prevents stale objects from crashing the main run loop pool.
		autoreleasepool {
			// Frame in window-local coordinates (origin 0,0), not global screen coordinates
			let contentFrame = NSRect(origin: .zero, size: screen.frame.size)
			let view = MetalLayerView(device: device, frame: contentFrame)
			// Match contentsScale to target screen (not main screen) — BMD outputs are 1x
			view.metalLayer.contentsScale = screen.backingScaleFactor
			view.metalLayer.drawableSize = CGSize(
				width: screen.frame.width * screen.backingScaleFactor,
				height: screen.frame.height * screen.backingScaleFactor
			)

			let window = createOutputWindow(on: screen)
			window.contentView = view
			self.outputWindow = window
			self.metalView = view

			NSLog("[KeyOutput] Started on %@ (%@)", window.screen?.localizedName ?? "unknown", NSStringFromRect(window.frame))
		}

		startOcclusionMonitoring()
		isActive = true
		isYielded = false
		statusMessage = "\(display.name) (\(display.width)x\(display.height))"
	}

	func stop() {
		stopOcclusionMonitoring()
		// Drain autoreleased objects immediately — window.close() and contentView
		// teardown create autoreleased ObjC objects. If these stay in the main run
		// loop pool while we nil out the owning references, they become dangling
		// pointers and crash during pool drain.
		autoreleasepool {
			outputWindow?.orderOut(nil)   // hide without triggering close lifecycle
			outputWindow?.contentView = nil
		}
		outputWindow = nil
		metalView = nil
		if let cache = textureCache {
			CVMetalTextureCacheFlush(cache, 0)
		}
		textureCache = nil
		metalDevice = nil
		commandQueue = nil
		isActive = false
		isYielded = false
		statusMessage = nil
	}

	func sendFrame(fill: CVPixelBuffer, key: CVPixelBuffer, timestamp: CMTime) {
		guard !isYielded, let layer = metalView?.metalLayer else { return }
		renderToLayer(layer, pixelBuffer: key)
	}

	// MARK: - Private

	private func createOutputWindow(on screen: NSScreen) -> NSWindow {
		// Create with size-only rect, then position with setFrame.
		// Passing screen.frame as contentRect AND screen: causes AppKit to double
		// the origin on external displays (contentRect treated as screen-relative).
		let window = NSWindow(
			contentRect: NSRect(origin: .zero, size: screen.frame.size),
			styleMask: [.borderless],
			backing: .buffered,
			defer: false
		)
		window.title = "ARC Keyer Key"
		window.isReleasedWhenClosed = false  // prevent double-free from autorelease pool
		window.isOpaque = true
		window.backgroundColor = .black
		window.animationBehavior = .none
		window.ignoresMouseEvents = true  // Pure output — clicks pass through to apps behind
		window.level = Self.keyOutputWindowLevel
		window.collectionBehavior = [.stationary, .canJoinAllSpaces, .fullScreenAuxiliary]
		// Position on target screen using global screen coordinates
		window.setFrame(screen.frame, display: true)
		window.orderFront(nil)
		return window
	}

	// MARK: - Occlusion Monitoring

	private func startOcclusionMonitoring() {
		guard let window = outputWindow else { return }
		occlusionObserver = NotificationCenter.default.addObserver(
			forName: NSWindow.didChangeOcclusionStateNotification,
			object: window,
			queue: .main
		) { [weak self] notification in
			guard let self, let window = notification.object as? NSWindow else { return }
			let visible = window.occlusionState.contains(.visible)
			if visible && self.isYielded {
				self.isYielded = false
				self.statusMessage = self.statusMessage?.replacingOccurrences(
					of: " [YIELDED]", with: "")
				NSLog("[KeyOutput] Display available — resuming output")
			} else if !visible && !self.isYielded {
				self.isYielded = true
				self.statusMessage = (self.statusMessage ?? "") + " [YIELDED]"
				NSLog("[KeyOutput] Display occluded by another app — yielding")
			}
		}
	}

	private func stopOcclusionMonitoring() {
		if let observer = occlusionObserver {
			NotificationCenter.default.removeObserver(observer)
			occlusionObserver = nil
		}
	}

	private func renderToLayer(_ layer: CAMetalLayer, pixelBuffer: CVPixelBuffer) {
		guard let queue = commandQueue, let cache = textureCache,
		      let drawable = layer.nextDrawable() else { return }

		let width = CVPixelBufferGetWidth(pixelBuffer)
		let height = CVPixelBufferGetHeight(pixelBuffer)

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
}

// MARK: - Error

enum OutputError: LocalizedError {
	case noDevice(String)
	var errorDescription: String? {
		switch self {
		case .noDevice(let msg): msg
		}
	}
}

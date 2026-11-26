//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation
import Metal
import CoreVideo
import CoreMedia

/// Shader parameter struct — must match Metal side
struct KeyParams {
	var threshold: Float = 0.05
	var softness: Float = 0.02
	var invert: Float = 0.0
}

final class MetalPipeline {

	let device: MTLDevice
	let commandQueue: MTLCommandQueue
	let pipelineState: MTLComputePipelineState

	private var textureCache: CVMetalTextureCache?
	private var currentWidth: Int = 0
	private var currentHeight: Int = 0

	// MARK: - Buffer Pools

	private var fillPool: CVPixelBufferPool?
	private var keyPool: CVPixelBufferPool?

	init() throws {
		guard let device = MTLCreateSystemDefaultDevice() else {
			throw MetalError.noDevice
		}
		self.device = device

		guard let queue = device.makeCommandQueue() else {
			throw MetalError.noCommandQueue
		}
		self.commandQueue = queue

		guard let library = device.makeDefaultLibrary(),
		      let function = library.makeFunction(name: "lumaKeyExtract") else {
			throw MetalError.shaderNotFound
		}
		self.pipelineState = try device.makeComputePipelineState(function: function)

		var cache: CVMetalTextureCache?
		CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
		self.textureCache = cache
	}

	// MARK: - Process Frame

	func processFrame(
		sampleBuffer: CMSampleBuffer,
		params: KeyParams
	) -> (fill: CVPixelBuffer, key: CVPixelBuffer)? {

		guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }

		let width = CVPixelBufferGetWidth(pixelBuffer)
		let height = CVPixelBufferGetHeight(pixelBuffer)
		guard width > 0, height > 0 else { return nil }

		if width != currentWidth || height != currentHeight {
			currentWidth = width
			currentHeight = height
			fillPool = createBufferPool(width: width, height: height)
			keyPool = createBufferPool(width: width, height: height)
		}

		// Wrap input CVPixelBuffer as Metal texture (zero-copy via IOSurface)
		guard let inputTexture = makeTexture(from: pixelBuffer) else { return nil }

		// Get output CVPixelBuffers from pools (IOSurface-backed)
		guard let fp = fillPool, let kp = keyPool else { return nil }
		var fillPB: CVPixelBuffer?
		var keyPB: CVPixelBuffer?
		CVPixelBufferPoolCreatePixelBuffer(nil, fp, &fillPB)
		CVPixelBufferPoolCreatePixelBuffer(nil, kp, &keyPB)
		guard let fillPB, let keyPB else { return nil }

		// Wrap output CVPixelBuffers as Metal textures (zero-copy via IOSurface).
		// The compute shader writes directly into these — no CPU readback needed.
		guard let fillTexture = makeTexture(from: fillPB),
		      let keyTexture = makeTexture(from: keyPB) else { return nil }

		guard let commandBuffer = commandQueue.makeCommandBuffer(),
		      let encoder = commandBuffer.makeComputeCommandEncoder() else { return nil }

		encoder.setComputePipelineState(pipelineState)
		encoder.setTexture(inputTexture, index: 0)
		encoder.setTexture(fillTexture, index: 1)
		encoder.setTexture(keyTexture, index: 2)

		var metalParams = params
		encoder.setBytes(&metalParams, length: MemoryLayout<KeyParams>.stride, index: 0)

		let threadGroupSize = MTLSize(width: 16, height: 16, depth: 1)
		let threadGroups = MTLSize(
			width: (width + threadGroupSize.width - 1) / threadGroupSize.width,
			height: (height + threadGroupSize.height - 1) / threadGroupSize.height,
			depth: 1
		)
		encoder.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupSize)
		encoder.endEncoding()

		// Commit without waiting. Outputs are IOSurface-backed CVPixelBuffers,
		// and Metal's automatic IOSurface hazard tracking serializes access
		// across command queues — downstream consumers (preview blit, key display
		// output) will implicitly wait for this compute pass to finish before
		// sampling these textures on their own queues. Blocking the capture
		// thread here would serialize GPU work that should run in parallel
		// with the next frame's capture.
		commandBuffer.commit()

		return (fillPB, keyPB)
	}

	// MARK: - Texture Management

	private func makeTexture(from pixelBuffer: CVPixelBuffer) -> MTLTexture? {
		guard let cache = textureCache else { return nil }
		let width = CVPixelBufferGetWidth(pixelBuffer)
		let height = CVPixelBufferGetHeight(pixelBuffer)

		var cvTexture: CVMetalTexture?
		let status = CVMetalTextureCacheCreateTextureFromImage(
			nil, cache, pixelBuffer, nil,
			.bgra8Unorm, width, height, 0, &cvTexture
		)
		guard status == kCVReturnSuccess, let cvTexture else { return nil }
		return CVMetalTextureGetTexture(cvTexture)
	}

	private func createBufferPool(width: Int, height: Int) -> CVPixelBufferPool? {
		let poolAttrs: [CFString: Any] = [
			kCVPixelBufferPoolMinimumBufferCountKey: 6,
		]
		let pbAttrs: [CFString: Any] = [
			kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
			kCVPixelBufferWidthKey: width,
			kCVPixelBufferHeightKey: height,
			kCVPixelBufferMetalCompatibilityKey: true,
			kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
		]
		var pool: CVPixelBufferPool?
		CVPixelBufferPoolCreate(nil, poolAttrs as CFDictionary, pbAttrs as CFDictionary, &pool)
		return pool
	}

	// MARK: - Errors

	enum MetalError: LocalizedError {
		case noDevice
		case noCommandQueue
		case shaderNotFound

		var errorDescription: String? {
			switch self {
			case .noDevice: "No Metal GPU device found"
			case .noCommandQueue: "Failed to create Metal command queue"
			case .shaderNotFound: "lumaKeyExtract shader function not found in default library"
			}
		}
	}
}

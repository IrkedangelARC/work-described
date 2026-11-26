//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI
import AppKit
import Metal
import QuartzCore

// MARK: - Metal Preview NSViewRepresentable

/// Wraps a MetalLayerView for SwiftUI. On creation, registers its CAMetalLayer
/// with KeyEngine so the capture thread can blit CVPixelBuffers directly —
/// no CGImage conversion, no SwiftUI image pipeline, no autorelease races.
struct MetalPreviewNSView: NSViewRepresentable {
	enum PreviewType { case fill, key }
	let type: PreviewType
	let engine: KeyEngine

	func makeNSView(context: Context) -> NSView {
		guard let device = engine.previewDevice else {
			// Preview device not ready yet — return placeholder
			let placeholder = NSView(frame: .zero)
			placeholder.wantsLayer = true
			placeholder.layer?.backgroundColor = NSColor.black.cgColor
			return placeholder
		}
		let view = MetalLayerView(device: device, frame: NSRect(x: 0, y: 0, width: 640, height: 360))
		// Register this layer with the engine for direct GPU rendering
		switch type {
		case .fill: engine.fillPreviewLayer = view.metalLayer
		case .key: engine.keyPreviewLayer = view.metalLayer
		}
		return view
	}

	func updateNSView(_ nsView: NSView, context: Context) {
		// drawableSize is set by KeyEngine.blitToLayer() to match source resolution.
		// CAMetalLayer auto-scales the rendered content to fit the view frame.
	}
}

// MARK: - Preview View

/// PREVIEW: the flexible picture. Two panes, FILL and KEY, each under its own small band; the module's
/// band carries the engine state. Idle is one line of text, not an icon.
struct PreviewView: View {
	@Environment(KeyEngine.self) private var keyEngine

	var body: some View {
		Group {
			if keyEngine.state == .capturing {
				HStack(spacing: ARCTheme.paddingSmall) {
					pane("FILL", type: .fill)
					pane("KEY", type: .key)
				}
				.frame(maxWidth: .infinity, maxHeight: .infinity)
			} else {
				VStack(spacing: ARCTheme.paddingSmall) {
					Text("ASSIGN A SOURCE DISPLAY AND START CAPTURE")
						.font(ARCTheme.mono(12, .bold))
						.foregroundStyle(ARCTheme.text1)
						.tracking(1)
					if let error = keyEngine.errorMessage {
						Text(error)
							.font(ARCTheme.mono(12, .regular))
							.foregroundStyle(ARCTheme.arcRed)
							.multilineTextAlignment(.center)
					}
				}
				.frame(maxWidth: .infinity, maxHeight: .infinity)
			}
		}
		.arcModule(title: "PREVIEW", tint: ARCTheme.secGreen, badge: badge)
	}

	private func pane(_ title: String, type: MetalPreviewNSView.PreviewType) -> some View {
		VStack(spacing: 0) {
			Text(title)
				.font(ARCTheme.mono(10, .heavy))
				.foregroundStyle(ARCTheme.text0)
				.tracking(1.4)
				.frame(maxWidth: .infinity)
				.frame(height: ARCTheme.moduleHeaderH)
				.background(ARCTheme.panel)
			MetalPreviewNSView(type: type, engine: keyEngine)
				.aspectRatio(16.0 / 9.0, contentMode: .fit)
				.frame(maxWidth: .infinity, maxHeight: .infinity)
				.background(Color.black)
		}
		.clipShape(RoundedRectangle(cornerRadius: 4))
		.overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(ARCTheme.line, lineWidth: 1))
	}

	private var badge: ARCBandBadge {
		switch keyEngine.state {
		case .idle: ARCBandBadge(text: "IDLE", fill: ARCTheme.text1)
		case .ready: ARCBandBadge(text: "READY", fill: ARCTheme.text0)
		case .capturing: ARCBandBadge(text: "LIVE", fill: ARCTheme.live)
		case .reconnecting: ARCBandBadge(text: "RECONNECTING", fill: ARCTheme.warn)
		case .error: ARCBandBadge(text: "ERROR", fill: ARCTheme.arcRed)
		}
	}
}

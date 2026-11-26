//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI

/// The left rail: DISPLAYS (every display with its role as three chips), TEST PATTERN (only once a source is
/// assigned), CAPTURE (the one big key; STOP is ARC red because red is live).
struct DisplayPickerView: View {
	@Environment(KeyEngine.self) private var keyEngine
	@Environment(DisplayManager.self) private var displayManager

	/// Confirmation gate — prevents accidental test pattern trigger during a live show.
	/// Only the SHOW action requires confirmation; HIDE fires immediately so the operator
	/// can kill the pattern fast if it went live by mistake.
	@State private var showingTestPatternConfirm = false

	var body: some View {
		VStack(spacing: ARCTheme.paddingSmall) {
			displaysModule
			if displayManager.sourceDisplay != nil {
				testPatternModule
			}
			Spacer(minLength: 0)
			captureModule   // pinned to the bottom, on the footer's line
		}
		.alert("Show Test Pattern?", isPresented: $showingTestPatternConfirm) {
			Button("Cancel", role: .cancel) {}
			Button("Show Test Pattern", role: .destructive) {
				displayManager.toggleTestPattern()
			}
		} message: {
			Text(
				"""
				This will override \(displayManager.sourceDisplay?.name ?? "the source display") with the calibration test pattern. Anything currently displayed there will be hidden until you dismiss it.

				Only use during setup or diagnostics — never during a live show.
				"""
			)
		}
	}

	// MARK: - DISPLAYS

	private var displaysModule: some View {
		VStack(spacing: ARCTheme.paddingSmall) {
			if displayManager.connectedDisplays.isEmpty {
				VStack(spacing: ARCTheme.paddingSmall) {
					Text("NO DISPLAYS DETECTED")
						.font(ARCTheme.mono(12, .bold))
						.foregroundStyle(ARCTheme.text1)
						.tracking(1)
					ARCModuleCaption("Grant screen recording permission in System Settings.")
						.multilineTextAlignment(.center)
				}
				.frame(maxWidth: .infinity, maxHeight: .infinity)
			} else {
				ForEach(displayManager.connectedDisplays) { display in
					displayRow(display)
				}
			}
			HStack(spacing: ARCTheme.paddingSmall) {
				ARCChip("ID", tint: ARCTheme.secBlue, wide: true) { displayManager.identifyDisplays() }
					.help("Identify displays")
				ARCChip("RESCAN", tint: ARCTheme.secBlue, wide: true) {
					Task { await displayManager.refreshDisplays() }
				}
			}
		}
		.arcModule(title: "DISPLAYS", tint: ARCTheme.secBlue,
		           badge: ARCBandBadge(text: "\(displayManager.connectedDisplays.count)", fill: ARCTheme.ink.opacity(0.35)))
	}

	private func displayRow(_ display: DisplaySource) -> some View {
		let role = displayManager.role(for: display)
		return ARCRow(tint: role == .none ? ARCTheme.line : roleColor(role)) {
			VStack(alignment: .leading, spacing: ARCTheme.paddingSmall) {
				HStack(alignment: .firstTextBaseline) {
					Text(display.name)
						.font(ARCTheme.mono(13, .bold))
						.foregroundStyle(ARCTheme.text0)
						.lineLimit(1)
					Spacer(minLength: ARCTheme.paddingSmall)
					Text(verbatim: "\(display.width)x\(display.height)")
						.font(ARCTheme.mono(10, .bold))
						.foregroundStyle(ARCTheme.text1)
				}
				if role == .control {
					Text("CONTROL")
						.font(ARCTheme.mono(10, .heavy))
						.foregroundStyle(ARCTheme.roleControl)
						.tracking(1)
				} else {
					HStack(spacing: 2) {
						ARCChip("NONE", tint: ARCTheme.text1, on: role == .none) { assign(display, .none) }
						ARCChip("SOURCE", tint: ARCTheme.roleSource, on: role == .source) { assign(display, .source) }
						ARCChip("KEY OUT", tint: ARCTheme.roleKeyOutput, on: role == .keyOutput) { assign(display, .keyOutput) }
					}
				}
			}
		}
	}

	private func assign(_ display: DisplaySource, _ newRole: DisplayRole) {
		switch newRole {
		case .source:
			displayManager.assignSource(display)
		case .keyOutput:
			displayManager.assignKeyOutput(display)
		case .none:
			if displayManager.sourceDisplay?.displayID == display.displayID {
				displayManager.assignSource(nil)
			}
			if displayManager.keyOutputDisplay?.displayID == display.displayID {
				displayManager.assignKeyOutput(nil)
			}
		case .control:
			break
		}
	}

	// MARK: - TEST PATTERN

	private var testPatternModule: some View {
		VStack(alignment: .leading, spacing: ARCTheme.paddingSmall) {
			ARCChip(displayManager.isTestPatternActive ? "HIDE TEST PATTERN" : "SHOW TEST PATTERN...",
			        tint: ARCTheme.warn, on: displayManager.isTestPatternActive, wide: true) {
				if displayManager.isTestPatternActive {
					// Instant dismiss — no confirm, operator needs fast kill
					displayManager.toggleTestPattern()
				} else {
					// Require confirmation before going live
					showingTestPatternConfirm = true
				}
			}
			.help("Overrides source display with the calibration test pattern. Requires confirmation.")
			ARCModuleCaption("Overrides the source display. Setup only.")
		}
		.arcModule(title: "TEST PATTERN", tint: ARCTheme.secOrange)
	}

	// MARK: - CAPTURE

	private var captureModule: some View {
		Group {
			switch keyEngine.state {
			case .capturing:
				ARCKey(title: "STOP CAPTURE", tint: ARCTheme.arcRed, on: true) { keyEngine.stopCapture() }
			case .reconnecting:
				ARCKey(title: "RECONNECTING...", tint: ARCTheme.warn, on: true) {}
					.disabled(true)
			default:
				ARCKey(title: "START CAPTURE") { Task { await keyEngine.startCapture() } }
					.disabled(displayManager.sourceDisplay == nil)
					.opacity(displayManager.sourceDisplay == nil ? 0.4 : 1)
			}
		}
		.arcModule(title: "CAPTURE", tint: ARCTheme.secCrimson)
	}

	// MARK: - Helpers

	private func roleColor(_ role: DisplayRole) -> Color {
		switch role {
		case .control: ARCTheme.roleControl
		case .source: ARCTheme.roleSource
		case .keyOutput: ARCTheme.roleKeyOutput
		case .none: ARCTheme.line
		}
	}
}

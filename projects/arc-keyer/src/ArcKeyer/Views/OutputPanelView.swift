//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI
import ARCDeckLink

/// OUTPUTS: one row per adapter with a START / STOP key (STOP is ARC red: the output is live), the
/// DeckLink device picker and its sent / dropped readout under its row.
struct OutputPanelView: View {
	@Environment(OutputBus.self) private var outputBus

	var body: some View {
		VStack(alignment: .leading, spacing: ARCTheme.paddingSmall) {
			if outputBus.adapters.isEmpty {
				ARCModuleCaption("No output adapters registered.")
			} else {
				ForEach(OutputCategory.allCases, id: \.self) { category in
					let adaptersInCategory = outputBus.adapters.filter { $0.category == category }
					if !adaptersInCategory.isEmpty {
						categorySection(category, adapters: adaptersInCategory)
					}
				}
			}
		}
		.arcModule(title: "OUTPUTS", tint: ARCTheme.secCrimson,
		           badge: ARCBandBadge(text: "\(outputBus.activeCount) LIVE",
		                               fill: outputBus.activeCount > 0 ? ARCTheme.live : ARCTheme.ink.opacity(0.35)))
	}

	private func categorySection(_ category: OutputCategory, adapters: [any OutputAdapter]) -> some View {
		VStack(alignment: .leading, spacing: 2) {
			Text(category.rawValue.uppercased())
				.font(ARCTheme.mono(10, .heavy))
				.foregroundStyle(ARCTheme.text2)
				.tracking(1)
			ForEach(adapters, id: \.id) { adapter in
				outputRow(adapter)
			}
		}
	}

	private func outputRow(_ adapter: any OutputAdapter) -> some View {
		ARCRow(tint: adapter.isActive ? ARCTheme.live : ARCTheme.line) {
			VStack(alignment: .leading, spacing: ARCTheme.paddingSmall) {
				HStack(spacing: ARCTheme.paddingSmall) {
					VStack(alignment: .leading, spacing: 1) {
						Text(adapter.name)
							.font(ARCTheme.mono(12, .bold))
							.foregroundStyle(adapter.isAvailable ? ARCTheme.text0 : ARCTheme.text2)
							.lineLimit(1)
						if let status = adapter.statusMessage {
							Text(status)
								.font(ARCTheme.mono(10, .regular))
								.foregroundStyle(ARCTheme.text1)
								.lineLimit(1)
						}
					}
					Spacer(minLength: 0)
					if adapter.isAvailable {
						ARCChip(adapter.isActive ? "STOP" : "START",
						        tint: ARCTheme.arcRed, on: adapter.isActive) {
							if adapter.isActive {
								outputBus.disable(id: adapter.id)
							} else {
								try? outputBus.enable(id: adapter.id)
							}
						}
					} else {
						Text("N/A")
							.font(ARCTheme.mono(10, .heavy))
							.foregroundStyle(ARCTheme.text2)
					}
				}
				if let deckLink = adapter as? DeckLinkOutput {
					DeckLinkDetailView(adapter: deckLink)
				}
			}
		}
	}
}

// MARK: - DeckLink Detail

/// Device picker, rescan, and send stats for the DeckLink adapter.
private struct DeckLinkDetailView: View {
	let adapter: DeckLinkOutput

	/// Adapters aren't @Observable — bump to re-render after refresh/selection.
	@State private var refreshTick = 0

	var body: some View {
		VStack(alignment: .leading, spacing: ARCTheme.paddingSmall) {
			HStack(spacing: ARCTheme.paddingSmall) {
				Picker("Device", selection: deviceSelection) {
					Text("First Available").tag(Int64(0))
					ForEach(adapter.devices) { device in
						Text(device.name).tag(device.persistentID)
					}
					if selectionIsOffline {
						Text("Saved device (offline)").tag(adapter.devicePersistentID)
					}
				}
				.labelsHidden()
				.controlSize(.small)
				.font(ARCTheme.mono(11, .bold))

				ARCChip("RESCAN", tint: ARCTheme.secCrimson) {
					adapter.refreshDevices()
					refreshTick += 1
				}
				.help("Rescan DeckLink devices")
			}

			if adapter.isActive {
				TimelineView(.periodic(from: .now, by: 1.0)) { _ in
					VStack(alignment: .leading, spacing: 1) {
						Text(verbatim: "SENT \(adapter.sentFrames)  DROPPED \(adapter.droppedFrames)")
							.font(ARCTheme.mono(10, .bold))
							.foregroundStyle(adapter.droppedFrames > 0 ? ARCTheme.warn : ARCTheme.text1)
						if let error = adapter.lastErrorMessage {
							Text(error)
								.font(ARCTheme.mono(10, .regular))
								.foregroundStyle(ARCTheme.arcRed)
						}
					}
				}
			}
		}
		.id(refreshTick)
	}

	private var deviceSelection: Binding<Int64> {
		Binding(
			get: { adapter.devicePersistentID },
			set: {
				adapter.devicePersistentID = $0
				refreshTick += 1
			}
		)
	}

	/// True when the persisted device ID isn't in the current device list —
	/// keeps the Picker selection valid until the device reappears.
	private var selectionIsOffline: Bool {
		adapter.devicePersistentID != 0 &&
			!adapter.devices.contains { $0.persistentID == adapter.devicePersistentID }
	}
}

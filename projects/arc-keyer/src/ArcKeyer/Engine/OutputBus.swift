//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation
import CoreVideo
import CoreMedia

// MARK: - Output Adapter Protocol

protocol OutputAdapter: AnyObject, Identifiable {
	var id: String { get }
	var name: String { get }
	var category: OutputCategory { get }
	var isAvailable: Bool { get }
	var isActive: Bool { get set }
	var statusMessage: String? { get }

	func start() throws
	func stop()
	func sendFrame(fill: CVPixelBuffer, key: CVPixelBuffer, timestamp: CMTime)
}

enum OutputCategory: String, CaseIterable {
	case display = "Display"
	case hardware = "Hardware"
}

// MARK: - Output Bus

@Observable
final class OutputBus {
	private(set) var adapters: [any OutputAdapter] = []

	var activeAdapters: [any OutputAdapter] {
		adapters.filter { $0.isActive }
	}

	var activeCount: Int { activeAdapters.count }

	func register(_ adapter: any OutputAdapter) {
		adapters.append(adapter)
	}

	func adapter(id: String) -> (any OutputAdapter)? {
		adapters.first { $0.id == id }
	}

	func enable(id: String) throws {
		guard let index = adapters.firstIndex(where: { $0.id == id }),
		      !adapters[index].isActive else { return }
		try adapters[index].start()
		adapters[index].isActive = true
		// Force @Observable notification — adapter properties aren't @Observable,
		// so SwiftUI won't detect isActive changes without this.
		adapters = adapters
		saveConfiguration()
	}

	func disable(id: String) {
		guard let index = adapters.firstIndex(where: { $0.id == id }) else { return }
		adapters[index].stop()
		adapters[index].isActive = false
		adapters = adapters
		saveConfiguration()
	}

	func sendFrame(fill: CVPixelBuffer, key: CVPixelBuffer, timestamp: CMTime) {
		for adapter in activeAdapters {
			adapter.sendFrame(fill: fill, key: key, timestamp: timestamp)
		}
	}

	// MARK: - Persistence

	/// IDs that were active last session — window creation is deferred until
	/// capture starts so we don't put orphan windows on output displays at launch.
	private(set) var pendingRestoreIds: Set<String> = []

	func restoreConfiguration() {
		let config = OutputConfiguration.load()
		// Only mark as pending — actual start() happens when capture begins.
		// This prevents orphan fullscreen windows on output displays before
		// any frames are flowing.
		pendingRestoreIds = config.enabledOutputIds
	}

	/// Called by KeyEngine when capture starts — activates any adapters that
	/// were saved from the previous session.
	func activatePendingOutputs() {
		guard !pendingRestoreIds.isEmpty else { return }
		var activated = false
		for id in pendingRestoreIds {
			guard let index = adapters.firstIndex(where: { $0.id == id }),
			      adapters[index].isAvailable, !adapters[index].isActive else { continue }
			try? adapters[index].start()
			adapters[index].isActive = true
			activated = true
		}
		pendingRestoreIds.removeAll()
		if activated {
			adapters = adapters
		}
	}

	private func saveConfiguration() {
		var config = OutputConfiguration.load()
		config.enabledOutputIds = Set(activeAdapters.map(\.id))
		config.save()
	}
}

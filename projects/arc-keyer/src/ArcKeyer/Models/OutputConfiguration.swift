//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation

struct OutputConfiguration: Codable {
	var enabledOutputIds: Set<String> = []
	/// Persistent ID of the selected DeckLink output device (0 = first available).
	var deckLinkDevicePersistentID: Int64 = 0

	init() {}

	init(from decoder: Decoder) throws {
		// Custom decode so configs saved by older builds (missing keys, or the
		// legacy deckLinkFillDeviceIndex/deckLinkKeyDeviceIndex fields from the
		// removed 2026-04 DeckLink attempt) load cleanly instead of resetting.
		let container = try decoder.container(keyedBy: CodingKeys.self)
		enabledOutputIds = try container.decodeIfPresent(Set<String>.self, forKey: .enabledOutputIds) ?? []
		deckLinkDevicePersistentID = try container.decodeIfPresent(Int64.self, forKey: .deckLinkDevicePersistentID) ?? 0
	}

	static func load() -> OutputConfiguration {
		guard let data = UserDefaults.standard.data(forKey: "outputConfig"),
		      let config = try? JSONDecoder().decode(OutputConfiguration.self, from: data) else {
			return OutputConfiguration()
		}
		return config
	}

	func save() {
		if let data = try? JSONEncoder().encode(self) {
			UserDefaults.standard.set(data, forKey: "outputConfig")
		}
	}
}

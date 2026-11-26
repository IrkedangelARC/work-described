//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation

@Observable
final class KeySettings {
	/// Clip level — luma below this is fully transparent (key = 0)
	var threshold: Double = 0.0 {
		didSet { UserDefaults.standard.set(threshold, forKey: "key.threshold") }
	}
	/// Gain level — luma above this is fully opaque (key = 1)
	var softness: Double = 1.0 {
		didSet { UserDefaults.standard.set(softness, forKey: "key.softness") }
	}
	var invert: Bool = false {
		didSet { UserDefaults.standard.set(invert, forKey: "key.invert") }
	}

	var metalParams: KeyParams {
		KeyParams(
			threshold: Float(threshold),
			softness: Float(softness),
			invert: invert ? 1.0 : 0.0
		)
	}

	init() {
		let defaults = UserDefaults.standard
		if defaults.object(forKey: "key.threshold") != nil {
			threshold = defaults.double(forKey: "key.threshold")
		}
		if defaults.object(forKey: "key.softness") != nil {
			softness = defaults.double(forKey: "key.softness")
		}
		invert = defaults.bool(forKey: "key.invert")
	}
}

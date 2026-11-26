//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation

@Observable
final class CaptureSettings {
	enum FrameRate: Int, CaseIterable, Identifiable {
		case fps30 = 30
		case fps60 = 60

		var id: Int { rawValue }
		var label: String { "\(rawValue) fps" }
	}

	var frameRate: FrameRate = .fps30 {
		didSet { UserDefaults.standard.set(frameRate.rawValue, forKey: "capture.frameRate") }
	}

	init() {
		if let raw = UserDefaults.standard.object(forKey: "capture.frameRate") as? Int,
		   let fps = FrameRate(rawValue: raw) {
			frameRate = fps
		}
	}
}

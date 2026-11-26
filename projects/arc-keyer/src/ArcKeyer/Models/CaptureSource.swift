//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation
import ScreenCaptureKit

struct DisplaySource: Identifiable, Hashable {
	let displayID: CGDirectDisplayID
	let width: Int
	let height: Int
	let name: String
	let scDisplay: SCDisplay?
	let isMain: Bool

	var id: CGDirectDisplayID { displayID }

	var displayName: String {
		let res = "\(width)x\(height)"
		return isMain ? "\(name) (Main) — \(res)" : "\(name) — \(res)"
	}

	func hash(into hasher: inout Hasher) {
		hasher.combine(displayID)
	}

	static func == (lhs: DisplaySource, rhs: DisplaySource) -> Bool {
		lhs.displayID == rhs.displayID
	}
}

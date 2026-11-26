//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation
import ScreenCaptureKit
import CoreGraphics

actor DisplayCapturer {
    func capture(display: SCDisplay) async throws -> CGImage {
        let filter = SCContentFilter(
            display: display,
            excludingApplications: [],
            exceptingWindows: []
        )
        let config = SCStreamConfiguration()
        config.width = display.width
        config.height = display.height
        config.scalesToFit = false
        config.showsCursor = false
        config.capturesAudio = false
        config.queueDepth = 5

        return try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: config
        )
    }
}

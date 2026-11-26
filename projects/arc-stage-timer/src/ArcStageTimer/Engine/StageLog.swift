//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation
import os

/// One line per automated action, in the unified log and on stdout, so a headless run says what it did.
enum StageLog {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ArcStageTimer", category: "stage")
    static func log(_ message: String) {
        logger.info("\(message, privacy: .public)")
        print("[stage] \(message)")
        fflush(stdout)
    }
}

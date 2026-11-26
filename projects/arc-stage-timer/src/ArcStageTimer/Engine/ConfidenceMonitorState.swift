//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI

/// Shared observable state for confidence monitor configuration.
/// Injected via environment so fill/key windows can read it.
/// Updated from the active Show's config when a show is loaded.
@Observable
final class ConfidenceMonitorState {
    var config: ConfidenceMonitorConfig = .default

    /// Load config from a show
    func loadFrom(_ show: Show) {
        config = show.confidenceConfig
    }

    /// Save current config back to a show
    func saveTo(_ show: Show) {
        show.confidenceConfig = config
    }
}

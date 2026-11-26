//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation

/// The unit-test host runs the real app delegate. Anything that touches the
/// operator's files or displays at launch (the show restore, the show-state
/// saver, the run marker, the log) must not run there: on 2026-09-16 a test
/// run restored the console's session into the host and saved the host's
/// state back over the real file (SDI lost), and left a run marker behind.
enum AppEnvironment {
    static let isTestHost = NSClassFromString("XCTestCase") != nil
}

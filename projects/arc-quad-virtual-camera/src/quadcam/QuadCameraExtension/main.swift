//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation
import CoreMediaIO

// The camera extension's process. macOS starts it on demand when an app opens "ARC QUAD".
let providerSource = QuadProviderSource(clientQueue: nil)
CMIOExtensionProvider.startService(provider: providerSource.provider)
CFRunLoopRun()

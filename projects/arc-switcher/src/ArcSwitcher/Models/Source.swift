//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import AppKit

/// A registered application source that can be switched to.
struct Source: Identifiable, Codable, Equatable {
    let id: String
    var friendlyName: String
    let bundleIdentifier: String
    var pid: pid_t?
    var isAvailable: Bool

    /// Non-codable transient reference
    var runningApp: NSRunningApplication? {
        guard let pid else { return nil }
        return NSRunningApplication(processIdentifier: pid)
    }

    var icon: NSImage? {
        runningApp?.icon
    }

    enum CodingKeys: String, CodingKey {
        case id, friendlyName, bundleIdentifier
    }

    init(id: String = UUID().uuidString, friendlyName: String, bundleIdentifier: String, pid: pid_t? = nil) {
        self.id = id
        self.friendlyName = friendlyName
        self.bundleIdentifier = bundleIdentifier
        self.pid = pid
        self.isAvailable = pid != nil
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        friendlyName = try c.decode(String.self, forKey: .friendlyName)
        bundleIdentifier = try c.decode(String.self, forKey: .bundleIdentifier)
        pid = nil
        isAvailable = false
    }
}

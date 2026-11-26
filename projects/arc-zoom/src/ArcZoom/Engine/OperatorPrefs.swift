//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//


import Foundation

/// Operator state that must survive a relaunch mid-show (PLAN_stability_refactor.md step 16): which
/// display holds PGM and MON (by UUID, never index: indices reorder on reconnect), the scene on each
/// window, self view, tile aspect, program mode, audio config, preset, blur, trust, video quality.
/// Plain UserDefaults; every read has a default, so a fresh Mac behaves as before.
enum OperatorPrefs {
    private static let d = UserDefaults.standard
    static func string(_ key: String) -> String? { d.string(forKey: "arczoom." + key) }
    static func bool(_ key: String, default v: Bool) -> Bool { d.object(forKey: "arczoom." + key) == nil ? v : d.bool(forKey: "arczoom." + key) }
    static func double(_ key: String, default v: Double) -> Double { d.object(forKey: "arczoom." + key) == nil ? v : d.double(forKey: "arczoom." + key) }
    /// The unit tests run inside the app as their host; they must not write the operator's preferences.
    private static let underTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    static func set(_ key: String, _ value: Any?) {
        guard !underTest else { return }
        if let value { d.set(value, forKey: "arczoom." + key) } else { d.removeObject(forKey: "arczoom." + key) }
    }
}

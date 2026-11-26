import AppKit

// One copy per login. A second launch (Finder double-click while the menu bar item is
// already up, or a URL open) hands its request to the running copy and leaves.
let bundleID = Bundle.main.bundleIdentifier ?? "com.example.arc.ArcShowMode"
let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
    .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
let underTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
if !others.isEmpty && !underTest {
    if CommandLine.arguments.contains("--on") { NSWorkspace.shared.open(URL(string: "arcshowmode://on")!) }
    if CommandLine.arguments.contains("--off") { NSWorkspace.shared.open(URL(string: "arcshowmode://off")!) }
    exit(0)
}

let application = NSApplication.shared
// The unit-test host must not touch the Mac it runs on (it resumed a live session and
// started closing apps on the office workstation, 2026-10-08). The tests exercise the types directly.
let delegate: AppDelegate? = underTest ? nil : AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()

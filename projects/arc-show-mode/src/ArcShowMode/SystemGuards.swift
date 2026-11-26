import Foundation
import IOKit.pwr_mgt

/// Keeps the display and the Mac awake for as long as Show Mode holds the assertion.
/// The assertions die with the process, so a crash can never leave a Mac pinned awake.
final class SleepGuard {
    private var ids: [IOPMAssertionID] = []
    private var activityTimer: Timer?

    var isHeld: Bool { !ids.isEmpty }

    func hold() {
        guard ids.isEmpty else { return }
        let reason = "ARC Show Mode" as CFString
        for type in [kIOPMAssertionTypePreventUserIdleDisplaySleep, kIOPMAssertionTypePreventUserIdleSystemSleep] {
            var id = IOPMAssertionID(0)
            if IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &id) == kIOReturnSuccess {
                ids.append(id)
            }
        }
        // The assertions stop display and system sleep; they do not stop the screen saver,
        // which runs off the user idle clock. Declaring activity resets that clock.
        declareActivity()
        activityTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.declareActivity()
        }
        RunLoop.main.add(activityTimer!, forMode: .common)
    }

    func release() {
        activityTimer?.invalidate()
        activityTimer = nil
        ids.forEach { IOPMAssertionRelease($0) }
        ids.removeAll()
    }

    private func declareActivity() {
        var id = IOPMAssertionID(0)
        IOPMAssertionDeclareUserActivity("ARC Show Mode" as CFString, kIOPMUserActiveLocal, &id)
    }
}

/// System alert sounds (the beep, "Funk", "Sosumi") go out the same output as the show
/// audio. Show Mode drops the alert volume to zero and puts it back afterwards.
/// `get/set volume` are Standard Additions run in-process: no Apple Events permission.
enum AlertVolume {
    static func current() -> Int? {
        var error: NSDictionary?
        let result = NSAppleScript(source: "alert volume of (get volume settings)")?.executeAndReturnError(&error)
        guard error == nil, let result else { return nil }
        return Int(result.int32Value)
    }

    @discardableResult
    static func set(_ value: Int) -> Bool {
        var error: NSDictionary?
        _ = NSAppleScript(source: "set volume alert volume \(max(0, min(100, value)))")?.executeAndReturnError(&error)
        return error == nil
    }
}

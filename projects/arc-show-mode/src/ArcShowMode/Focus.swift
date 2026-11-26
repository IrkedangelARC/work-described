import AppKit

/// Do Not Disturb, through Shortcuts.
///
/// macOS has no public API to set a Focus. The supported route is a shortcut with the
/// "Set Focus" action, run through /usr/bin/shortcuts. The app ships two signed
/// shortcuts (Resources/) and installs them with one "Add Shortcut" click per Mac.
/// Their source plists live in tools/focus-*.plist; rebuild with tools/sign-shortcuts.sh.
enum Focus {
    static let onName = "ARC Show Focus On"
    static let offName = "ARC Show Focus Off"
    private static let cli = "/usr/bin/shortcuts"

    struct Result {
        let ok: Bool
        let message: String
    }

    /// Both shortcuts present in this user's library. `shortcuts list` takes a few hundred
    /// milliseconds, so the answer is cached; callers refresh after setup or a test.
    private(set) static var installedCached: Bool?

    @discardableResult
    static func installed() -> Bool {
        let names = Set(run([cli, "list"]).output.split(separator: "\n").map(String.init))
        let ok = names.contains(onName) && names.contains(offName)
        installedCached = ok
        return ok
    }

    static func set(_ on: Bool) -> Result {
        let name = on ? onName : offName
        let r = run([cli, "run", name])
        if r.status == 0 {
            Log.info("focus \(on ? "on" : "off")")
            return Result(ok: true, message: on ? "Do Not Disturb on" : "Do Not Disturb off")
        }
        let why = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
        Log.warn("focus \(on ? "on" : "off") failed: exit \(r.status) \(why)")
        return Result(ok: false, message: why.isEmpty ? "\"\(name)\" failed (exit \(r.status))" : why)
    }

    /// Opens each bundled shortcut, which shows Shortcuts' "Add Shortcut" sheet.
    static func install() {
        for name in [onName, offName] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "shortcut") else { continue }
            NSWorkspace.shared.open(url)
        }
    }

    /// Bounded: `shortcuts run` blocks for as long as Shortcuts shows a permission sheet,
    /// and a call that never returns would leave the menu stuck on "Applying…" with no way
    /// to engage or release. After `timeout` seconds the process is killed and the call fails.
    private static func run(_ argv: [String], timeout: TimeInterval = 20) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: argv[0])
        p.arguments = Array(argv.dropFirst())
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        var data = Data()
        let reader = DispatchGroup()
        reader.enter()
        DispatchQueue.global(qos: .utility).async {
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            reader.leave()
        }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        if p.isRunning {
            p.terminate()
            Thread.sleep(forTimeInterval: 0.5)
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            _ = reader.wait(timeout: .now() + 2)
            return (-2, "timed out after \(Int(timeout))s: Shortcuts is probably waiting for a click")
        }
        reader.wait()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

// led-profile: list displays, apply an ARC LED profile to one, or reset it.
//   led-profile list
//   led-profile set "<profile name or .icc path>" [displayIndex]
//   led-profile reset [displayIndex]
//   led-profile verify <file.icc>...
// displayIndex defaults to the first non-built-in display (the LED wall).
import AppKit
import ColorSync

let profileDirs = [NSHomeDirectory() + "/Library/ColorSync/Profiles",
                   (CommandLine.arguments[0] as NSString).deletingLastPathComponent + "/profiles"]

func screens() -> [(index: Int, id: CGDirectDisplayID, name: String, builtin: Bool)] {
    NSScreen.screens.enumerated().map { i, s in
        let id = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! CGDirectDisplayID
        return (i, id, s.localizedName, CGDisplayIsBuiltin(id) != 0)
    }
}

func target(_ arg: String?) -> (index: Int, id: CGDirectDisplayID, name: String, builtin: Bool) {
    let all = screens()
    if let a = arg, let i = Int(a), i < all.count { return all[i] }
    guard let ext = all.first(where: { !$0.builtin }) else {
        fputs("No external display found. Pass a display index from `list`.\n", stderr); exit(1)
    }
    return ext
}

func setProfile(_ id: CGDirectDisplayID, _ url: URL?) -> Bool {
    let uuid = CGDisplayCreateUUIDFromDisplayID(id).takeRetainedValue()
    let entry: [String: Any] = [kColorSyncDeviceDefaultProfileID.takeUnretainedValue() as String: (url as Any?) ?? kCFNull as Any,
                                kColorSyncProfileUserScope.takeUnretainedValue() as String: kCFPreferencesCurrentUser]
    return ColorSyncDeviceSetCustomProfiles(kColorSyncDisplayDeviceClass.takeUnretainedValue(), uuid, entry as CFDictionary)
}

func resolve(_ name: String) -> URL? {
    if FileManager.default.fileExists(atPath: name) { return URL(fileURLWithPath: name) }
    for d in profileDirs {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: d) else { continue }
        let want = name.lowercased()
        if let hit = files.filter({ $0.hasSuffix(".icc") }).sorted()
            .first(where: { $0.lowercased().contains(want) }) { return URL(fileURLWithPath: d + "/" + hit) }
    }
    return nil
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first ?? "list" {
case "list":
    for s in screens() {
        let cs = NSScreen.screens[s.index].colorSpace?.localizedName ?? "?"
        print("[\(s.index)] \(s.name)\(s.builtin ? " (built-in)" : "")  profile: \(cs)")
    }
case "set":
    guard args.count >= 2, let url = resolve(args[1]) else { fputs("Profile not found: \(args.dropFirst().first ?? "")\n", stderr); exit(1) }
    let t = target(args.count > 2 ? args[2] : nil)
    print(setProfile(t.id, url) ? "\(t.name) -> \(url.lastPathComponent)" : "FAILED on \(t.name)")
case "reset":
    let t = target(args.count > 1 ? args[1] : nil)
    print(setProfile(t.id, nil) ? "\(t.name) -> factory profile" : "FAILED on \(t.name)")
case "verify":
    var bad = 0
    for p in args.dropFirst() {
        var errs: Unmanaged<CFError>?, warns: Unmanaged<CFError>?
        guard let prof = ColorSyncProfileCreateWithURL(URL(fileURLWithPath: p) as CFURL, nil)?.takeRetainedValue() else { print("UNREADABLE \(p)"); bad += 1; continue }
        let ok = ColorSyncProfileVerify(prof, &errs, &warns)
        let w = warns.map { "\($0.takeRetainedValue())" } ?? ""
        print("\(ok ? "OK  " : "FAIL") \((p as NSString).lastPathComponent) \(w)")
        if !ok { bad += 1 }
    }
    exit(bad == 0 ? 0 : 1)
default:
    print("usage: led-profile list | set <name> [display] | reset [display] | verify <icc>...")
}

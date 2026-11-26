//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

// ARC Presenter Guard: crash cover for the program display (design §3).
//
// Launched by ARC Presenter while a program output is open, with Presenter's
// pid, the program display id and Presenter's bundle path. Watches the parent
// with kqueue. If it exits without telling the Guard first (SIGTERM = clean
// quit), the Guard puts a black window at the shielding level on the program
// display within milliseconds, relaunches Presenter, waits for the program
// window to report ok over the control API, drops the black and exits.
// Never a loop: two relaunches in a minute, then the black stays and the log
// says so. Measured without it: kill to live picture 3.6 s of desktop.

import AppKit
import Foundation
import ARCDeckLink

let args = CommandLine.arguments
func arg(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}
guard let parentPID = arg("--parent").flatMap({ Int32($0) }), let appPath = arg("--app") else {
    FileHandle.standardError.write("usage: --parent PID --app PATH [--display ID] [--api PORT]\n".data(using: .utf8)!)
    exit(64)
}
let displayID = arg("--display").flatMap { UInt32($0) }
let sdiDevice = arg("--sdi").flatMap { Int64($0) }
let sdiFPS = arg("--fps").flatMap { Double($0) } ?? 59.94
let apiPort = arg("--api").flatMap { Int($0) } ?? 8760
let logsDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/ARC Presenter", isDirectory: true)
try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
let logURL = logsDir.appendingPathComponent("guard.log")
let stateDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    .appendingPathComponent("ARC Presenter Arcdeck Player", isDirectory: true)
let relaunchesURL = stateDir.appendingPathComponent("guard-relaunches.txt")
let markerURL = stateDir.appendingPathComponent("running.marker")
let lastFrameURL = stateDir.appendingPathComponent("last-frame.bgra")
let pidURL = stateDir.appendingPathComponent("guard.pid")
var sdiOut: DeckLinkFillKeyOutput?
var sdiTimer: Timer?

let t0 = Date()
let stamp: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"; return f }()
func log(_ s: String) {
    let line = "\(stamp.string(from: Date())) guard[\(getpid())] \(s)\n"
    if let h = try? FileHandle(forWritingTo: logURL) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
    else { try? line.write(to: logURL, atomically: true, encoding: .utf8) }
}
func ms(_ since: Date) -> Int { Int(Date().timeIntervalSince(since) * 1000) }

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)   // no Dock, no menu bar, never key

var cleanQuitAnnounced = false
var coverDown = false
var black: NSWindow?

func screen(for id: UInt32?) -> NSScreen? {
    guard let id else { return nil }
    return NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32) == id }
}

/// SDI: open the device Presenter was driving (it is free once Presenter is gone) and
/// hold the last frame with the red border until Presenter is back and about to restart it.
func holdSDI(_ image: CGImage?) {
    guard let sdiDevice else { return }
    guard let pb = HeldFrame.pixelBuffer(image) else { log("SDI: could not build the held frame"); return }
    let out = DeckLinkFillKeyOutput()
    do { try out.start(devicePersistentID: sdiDevice, width: 1920, height: 1080, fps: sdiFPS, keyer: .none) }
    catch { log("SDI: device \(sdiDevice) would not start: \(error.localizedDescription)"); return }
    out.send(fill: pb)
    sdiOut = out
    try? String(getpid()).write(to: pidURL, atomically: true, encoding: .utf8)   // Presenter's SDI start reads this and sends SIGUSR1
    log("SDI: holding the last frame with the red border on device \(sdiDevice) at \(sdiFPS) fps")
    sdiTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in out.send(fill: pb) }
}
func releaseSDI(_ why: String) {
    guard let out = sdiOut else { return }
    sdiTimer?.invalidate(); sdiTimer = nil
    out.stop(); sdiOut = nil
    try? FileManager.default.removeItem(at: pidURL)
    log("SDI: released the device (\(why))")
}

func raiseBlack() {
    guard let scr = screen(for: displayID) else { log("no display \(displayID.map(String.init) ?? "-") present: no cover window"); return }
    let w = NSWindow(contentRect: scr.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: scr)
    w.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
    w.backgroundColor = .black
    let held = HeldFrame.View(frame: NSRect(origin: .zero, size: scr.frame.size))
    held.image = HeldFrame.lastImage(at: lastFrameURL)
    w.contentView = held
    log(held.image != nil ? "cover: last frame \(held.image!.width)x\(held.image!.height) with the red border" : "cover: no last frame on disk, black with the red border")
    // The cover as a PNG beside the log, once the window is up (it cost ~100 ms on the critical path).
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        if let rep = held.bitmapImageRepForCachingDisplay(in: held.bounds) {
            held.cacheDisplay(in: held.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: logsDir.appendingPathComponent("guard-cover.png")) }
        }
    }
    w.isOpaque = true
    w.ignoresMouseEvents = true
    w.hasShadow = false
    w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
    w.setFrame(scr.frame, display: true)
    w.orderFrontRegardless()
    black = w
}

func recentRelaunches() -> [Date] {
    let text = (try? String(contentsOf: relaunchesURL, encoding: .utf8)) ?? ""
    return text.split(separator: "\n").compactMap { Double($0) }.map { Date(timeIntervalSince1970: $0) }.filter { Date().timeIntervalSince($0) < 60 }
}
func recordRelaunch() {
    let kept = (recentRelaunches() + [Date()]).map { String($0.timeIntervalSince1970) }.joined(separator: "\n")
    try? kept.write(to: relaunchesURL, atomically: true, encoding: .utf8)
}

func programOK(completion: @escaping (Bool) -> Void) {
    var req = URLRequest(url: URL(string: "http://127.0.0.1:\(apiPort)/state")!)
    req.timeoutInterval = 0.5
    URLSession.shared.dataTask(with: req) { data, _, _ in
        var ok = false
        if let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let health = obj["health"] as? [String: Any], let chips = health["chips"] as? [String: Any],
           let pgm = chips["pgm"] as? [String: Any], let level = pgm["level"] as? String {
            ok = level == "ok"
        }
        DispatchQueue.main.async { completion(ok) }
    }.resume()
}

func waitForProgram(deadline: Date, exited: Date, relaunched: Date) {
    programOK { ok in
        if ok {
            log("program window ok at +\(ms(exited)) ms after the exit (+\(ms(relaunched)) ms after the relaunch); dropping the black in 300 ms")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                black?.orderOut(nil)
                guard sdiOut != nil else { log("done"); exit(0) }
                // Presenter's own SDI comes up ~2 s after its picture; keep the held frame on the
                // wire until its DeckLink start asks for the device (SIGUSR1), or 30 s.
                coverDown = true
                log("cover down; still holding SDI until Presenter asks for the device")
                DispatchQueue.main.asyncAfter(deadline: .now() + 30) { if sdiOut != nil { releaseSDI("30 s and Presenter never asked"); log("done"); exit(0) } }
            }
        } else if Date() > deadline {
            log("program window not ok within 60 s; dropping the black so the room is not blind, exiting")
            releaseSDI("timeout"); black?.orderOut(nil); exit(2)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { waitForProgram(deadline: deadline, exited: exited, relaunched: relaunched) }
        }
    }
}

func parentExited() {
    let exited = Date()
    if cleanQuitAnnounced { log("parent \(parentPID) exited after a clean quit; nothing to do"); exit(0) }
    let markerPresent = FileManager.default.fileExists(atPath: markerURL.path)
    guard markerPresent else { log("parent \(parentPID) exited and its marker is gone (clean); nothing to do"); exit(0) }
    raiseBlack()
    log("parent \(parentPID) EXITED UNCLEAN; cover on display \(displayID.map(String.init) ?? "-") at +\(ms(exited)) ms")
    holdSDI(HeldFrame.lastImage(at: lastFrameURL))
    let recent = recentRelaunches()
    guard recent.count < 2 else {
        log("relaunch storm: \(recent.count) relaunches in the last minute; NOT relaunching, black stays 120 s")
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { releaseSDI("storm timeout"); black?.orderOut(nil); exit(3) }
        return
    }
    recordRelaunch()
    let cfg = NSWorkspace.OpenConfiguration()
    cfg.createsNewApplicationInstance = true
    cfg.activates = false
    NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: appPath), configuration: cfg) { _, err in
        DispatchQueue.main.async {
            let relaunched = Date()
            if let err { log("relaunch FAILED: \(err.localizedDescription); cover stays 60 s"); DispatchQueue.main.asyncAfter(deadline: .now() + 60) { releaseSDI("relaunch failed"); black?.orderOut(nil); exit(4) }; return }
            log("relaunched \(appPath) at +\(ms(exited)) ms")
            waitForProgram(deadline: Date().addingTimeInterval(60), exited: exited, relaunched: relaunched)
        }
    }
}

// Clean quit: Presenter sends SIGTERM before it removes its marker and exits.
signal(SIGTERM, SIG_IGN); signal(SIGINT, SIG_IGN)
let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
termSource.setEventHandler { cleanQuitAnnounced = true; log("SIGTERM from Presenter: clean quit; exiting"); exit(0) }
termSource.resume()
signal(SIGUSR1, SIG_IGN)
let usr1Source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
usr1Source.setEventHandler { releaseSDI("Presenter asked for the device"); if coverDown { log("done"); exit(0) } }
usr1Source.resume()
let intSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
intSource.setEventHandler { exit(0) }
intSource.resume()

guard kill(parentPID, 0) == 0 else { log("parent \(parentPID) is not running; exiting"); exit(0) }
let procSource = DispatchSource.makeProcessSource(identifier: parentPID, eventMask: .exit, queue: .main)
procSource.setEventHandler { parentExited() }
procSource.resume()
log("watching Presenter pid \(parentPID), display \(displayID.map(String.init) ?? "-"), sdi \(sdiDevice.map(String.init) ?? "-") @ \(sdiFPS), api \(apiPort), app \(appPath)")
app.run()

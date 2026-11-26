//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import AppKit
import Foundation

/// Where the windowed slideshow goes. On an intake Mac: the second display.
/// On a show Mac, where ARC Presenter is live beside the capture (design
/// §4.2, a heavy day with late changes), the second display IS the program
/// display and the room would see PowerPoint: so ask Presenter which
/// displays are its outputs and never put the show on one of them. With no
/// other display the show stays on the operator's screen, partly covering
/// the console for the capture's minutes (only a fully covered window stops
/// drawing). With every display an output there is no safe place: the show
/// is left where the app put it and the log says so loudly.
enum ShowWindowPlacement {
    struct Candidate: Equatable {
        var uuid: String
        var isMain: Bool
        var isPresenterOutput: Bool
    }

    /// Presenter's outputs, by display UUID, from its control API. Empty when
    /// Presenter is not running (or answers with nothing routed).
    static func presenterOutputUUIDs(port: Int = 8760, timeout: TimeInterval = 0.3) -> Set<String> {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/displays")!)
        req.timeoutInterval = timeout
        let sem = DispatchSemaphore(value: 0)
        var found = Set<String>()
        URLSession.shared.dataTask(with: req) { data, _, _ in
            defer { sem.signal() }
            guard let data, let obj = try? JSONSerialization.jsonObject(with: data) else { return }
            let rows = (obj as? [[String: Any]]) ?? ((obj as? [String: Any])?["displays"] as? [[String: Any]]) ?? []
            for r in rows where (r["program"] as? Bool == true) || (r["confidence"] as? Bool == true) {
                if let u = r["uuid"] as? String { found.insert(u) }
            }
        }.resume()
        _ = sem.wait(timeout: .now() + timeout + 0.2)
        return found
    }

    static func uuid(of screen: NSScreen) -> String {
        guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let cf = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return "" }
        return CFUUIDCreateString(nil, cf) as String
    }

    /// The pure choice: a display that is not the main one and not an output,
    /// else the main display if it is not an output, else nil.
    static func choose(_ candidates: [Candidate]) -> Candidate? {
        if let other = candidates.first(where: { !$0.isMain && !$0.isPresenterOutput }) { return other }
        if let main = candidates.first(where: { $0.isMain && !$0.isPresenterOutput }) { return main }
        return nil
    }

    /// The screen to move the show window to, and a line for the log.
    static func targetScreen() -> (screen: NSScreen?, note: String) {
        let screens = NSScreen.screens
        guard let main = screens.first else { return (nil, "no displays") }
        let outputs = presenterOutputUUIDs()
        let cands = screens.map { Candidate(uuid: uuid(of: $0), isMain: $0 == main, isPresenterOutput: outputs.contains(uuid(of: $0))) }
        guard let pick = choose(cands), let screen = screens.first(where: { uuid(of: $0) == pick.uuid }) else {
            return (nil, "every display (\(screens.count)) is an ARC Presenter output: the show window is NOT moved; the room may see it")
        }
        let why = outputs.isEmpty ? "no Presenter outputs reported" : "Presenter outputs on \(outputs.count) display(s) avoided"
        return (screen, "show window -> \"\(screen.localizedName)\"\(pick.isMain ? " (the operator display; it partly covers the console)" : "") (\(why))")
    }
}

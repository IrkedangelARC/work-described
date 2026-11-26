//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation

/// yt-dlp's stderr, turned into one line the crew can act on (PLAN_arc_grab_multisite, step 3). The raw
/// line stays in the job log; the row shows the reason and the HINT, and a hint that is a button (UPDATE
/// ENGINE) becomes one. Every pattern below was captured from a real failure on 2026-09-17 or earlier.
struct GrabFailure: Equatable {
    enum Hint: String, Equatable {
        case cookies, password, referer, updateEngine, geo, drm, removed, rateLimited, badLink, retry, updateApp

        /// What the row says after the reason.
        var label: String {
            switch self {
            case .cookies:      return "LOG IN IN YOUR BROWSER, THEN SET COOKIES"
            case .password:     return "NEEDS THE PASSWORD"
            case .referer:      return "SET REFERER TO THE PAGE THE PLAYER IS ON"
            case .updateEngine: return "TRY UPDATE ENGINE"
            case .geo:          return "GEO-BLOCKED"
            case .drm:          return "PROTECTED STREAM · TRY COOKIES"
            case .removed:      return "REMOVED OR PRIVATE"
            case .rateLimited:  return "RATE LIMITED · WAIT, THEN RETRY"
            case .badLink:      return "NOT A PLAYER LINK · PASTE THE PLAYER OR THE PAGE"
            case .retry:        return "RETRY"
            case .updateApp:    return "UPDATE ARC GRAB"
            }
        }
    }

    var reason: String
    var hint: Hint?

    /// The row's status text: "reason · HINT".
    var line: String { hint.map { "\(reason) · \($0.label)" } ?? reason }
}

enum ErrorMapper {
    /// `text` is the last ERROR line yt-dlp printed (already stripped of "ERROR: " by ProgressParser), or
    /// whatever the queue had instead.
    static func map(_ text: String) -> GrabFailure {
        let t = text.lowercased()
        func has(_ needles: String...) -> Bool { needles.contains { t.contains($0) } }

        // Order matters: the most specific instruction first.
        if has("password") && has("protected", "required", "incorrect", "--video-password") {
            return GrabFailure(reason: "password protected", hint: .password)
        }
        if has("not available from this domain", "referer", "domain restriction", "embed permission", "privacy settings") {
            return GrabFailure(reason: "the player is locked to its page", hint: .referer)
        }
        if has("only works when logged-in", "sign in to confirm", "login required", "log in", "members only", "cookies-from-browser", "401", "unauthorized") {
            return GrabFailure(reason: "the site wants a login", hint: .cookies)
        }
        if has("drm protected", "drm") {
            return GrabFailure(reason: "DRM on every format", hint: .drm)
        }
        if has("private video", "is private") {
            return GrabFailure(reason: "private video", hint: .cookies)
        }
        if has("available in your country", "geo restriction", "geo-restricted", "georestricted", "available in your location", "geo-blocked", "geoblocked") {
            return GrabFailure(reason: "not available from here", hint: .geo)
        }
        if has("429", "too many requests", "rate limit", "rate-limit") {
            return GrabFailure(reason: "the site is throttling", hint: .rateLimited)
        }
        // Before the 404 rule: "Encoder not found" would otherwise read as a removed video.
        if has("encoder not found", "audio conversion failed", "unknown encoder") {
            return GrabFailure(reason: "this build cannot encode that format", hint: .updateApp)
        }
        if has("404", "video unavailable", "has been removed", "does not exist", "no longer available", "not found") {
            return GrabFailure(reason: "gone at the source", hint: .removed)
        }
        if has("unsupported url", "no video could be found", "unable to extract", "no media found") {
            return GrabFailure(reason: "no player found at that link", hint: .badLink)
        }
        if has("403", "requested format is not available", "no video formats found", "unable to download json metadata", "unable to download webpage") {
            // YouTube moving under an old extractor, or a site the current build cannot read: the engine
            // update is the fix nine times in ten.
            return GrabFailure(reason: firstSentence(text), hint: .updateEngine)
        }
        if has("timed out", "timeout", "connection reset", "network is unreachable", "temporary failure") {
            return GrabFailure(reason: "network dropped", hint: .retry)
        }
        return GrabFailure(reason: firstSentence(text), hint: nil)
    }

    /// yt-dlp errors run on with advice and issue-tracker links; the row keeps the first clause.
    static func firstSentence(_ text: String) -> String {
        var s = text
        if let r = s.range(of: "ERROR: ") { s = String(s[r.upperBound...]) }
        for stop in ["; please report", "; Try selecting", ". Use --", "; Use --", " (caused by", ". See ", "; see "] {
            if let r = s.range(of: stop) { s = String(s[..<r.lowerBound]) }
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

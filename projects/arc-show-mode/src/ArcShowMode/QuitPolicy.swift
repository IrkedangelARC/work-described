import Foundation

/// Which apps Show Mode closes, and how hard.
///
/// Two tiers. Sync clients are force-quit: Google Drive answers a polite quit with
/// "uploads in progress, quit anyway?", which is itself a popup, and a sync client
/// resumes cleanly after a hard stop. Everything else gets a normal quit so a draft
/// or an unsent message is never lost.
///
/// The show apps (browsers, PowerPoint, Keynote, Zoom, every ARC app) are never on
/// either list. Add or exempt apps per Mac with:
///   defaults write com.example.arc.ArcShowMode extraQuitBundleIDs -array com.example.App
///   defaults write com.example.arc.ArcShowMode keepBundleIDs -array com.apple.mail
enum QuitPolicy {

    /// Force-quit. These raise the "file has been removed" / "sync paused" banners.
    static let syncClients: [String] = [
        "com.google.drivefs",                  // Google Drive for desktop
        "com.getdropbox.dropbox",
        "com.microsoft.OneDrive",
        "com.microsoft.OneDrive-mac",
        "com.box.desktop",
    ]

    /// Normal quit. Messaging, mail and calendar: the apps that post banners and ring.
    static let messaging: [String] = [
        "com.apple.MobileSMS",                 // Messages
        "com.apple.mail",
        "com.apple.FaceTime",                  // Continuity: iPhone calls ring on the Mac
        "com.apple.iCal",                      // Calendar alerts
        "com.apple.reminders",
        "com.microsoft.Outlook",
        "com.readdle.smartemail-Mac",          // Spark
        "com.tinyspeck.slackmacgap",
        "com.microsoft.teams2",
        "com.microsoft.teams",
        "com.hnc.Discord",
        "net.whatsapp.WhatsApp",
        "ru.keepcoder.Telegram",
        "org.whispersystems.signal-desktop",
        "com.adobe.acc.AdobeCreativeCloud",
    ]

    static func isForce(_ bundleID: String) -> Bool {
        syncClients.contains(bundleID)
    }

    /// The full set Show Mode keeps closed, after this Mac's own additions and exemptions.
    static func targets(extra: [String], keep: [String]) -> Set<String> {
        Set(syncClients + messaging + extra).subtracting(keep)
    }

    /// Of the apps running now, the ones to close, in a stable order (sync clients first,
    /// because they are the ones that pop up mid-show).
    static func toClose(running: [String], extra: [String], keep: [String]) -> [String] {
        let wanted = targets(extra: extra, keep: keep)
        let hits = Set(running).intersection(wanted)
        let order = syncClients + messaging + extra
        var seen = Set<String>()
        return order.filter { hits.contains($0) && seen.insert($0).inserted }
    }

    static var userExtra: [String] {
        UserDefaults.standard.stringArray(forKey: "extraQuitBundleIDs") ?? []
    }

    static var userKeep: [String] {
        UserDefaults.standard.stringArray(forKey: "keepBundleIDs") ?? []
    }
}

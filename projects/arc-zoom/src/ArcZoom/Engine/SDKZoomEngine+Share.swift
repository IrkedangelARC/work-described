//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//


import Foundation
import AppKit
import CoreVideo
import ZoomSDK

// MARK: - Share
// Remote shares subscribed by SOURCE id (polled: the AS delegate is silent for phone/iPad shares) and sharing FROM the sidecar (window, display, file, camera, audio).
// State lives in SDKZoomEngine.swift; this file is behaviour only (PLAN_stability_refactor.md step 11).

extension SDKZoomEngine {
    /// Subscribe to the active share's raw frames at full resolution. Same path as video, different type.
    func subscribeShare(_ sourceID: UInt32) async -> Bool {
        guard state == .inMeeting else { return false }
        guard await startRawData() else { return false }
        if subscriptions[sourceID] != nil { return true }
        let gate = frameGate
        let sub = VideoSubscription(userID: sourceID, rawDataType: ZoomSDKRawDataType_Share) { uid, buffer in gate.push(uid, buffer) }
        sub.setResolution(ZoomSDKResolution_1080P)
        guard sub.start() else { return false }
        subscriptions[sourceID] = sub
        return true
    }

    func refreshShare() {
        guard let service = ZoomSDK.shared().getMeetingService() else { return }
        let asc = service.getASController()
        let all = (asc.getViewableSharingUserList() ?? []).map { $0.uint32Value }
        lastShareList = all
        // Our own share: the viewable list may exclude us, so ask for our source list by id instead.
        if let me = myID {
            let mineInfos = asc.getSharingSourceInfoList(me) ?? []
            myShareSources = mineInfos.count
            // A raw share with its sender live is ours whatever the source list says: dropping it here after 3 s
            // would stop PREVIEW's feed if the SDK lists external sources differently.
            let mine = !mineInfos.isEmpty || all.contains(me) || rawShare?.sending == true
            if isSharing, !mine, shareStartedAt.map({ Date().timeIntervalSince($0) > 3 }) ?? true {
                isSharing = false; shareDescription = nil; sharedWindowTitle = nil; ShowLog.log("our share ended"); onRosterChange?()
            } else if !isSharing, mine {
                isSharing = true; onRosterChange?()
            }
        }
        let sharers = all.filter { $0 != myID }
        if let uid = sharers.first, let info = asc.getSharingSourceInfoList(uid)?.first {
            if activeShare?.sourceID != info.shareSourceID { ShowLog.log("share: \(participants.first { $0.id == uid }?.displayName ?? "\(uid)") is sharing (source \(info.shareSourceID), type \(info.contentType.rawValue), status \(info.status.rawValue))") }
            activeShare = (info.shareSourceID, uid)
        } else if let me = myID, let mine = asc.getSharingSourceInfoList(me)?.first {
            // Our own share is a source for the room too: the SHARE element shows what the call sees.
            if activeShare?.sourceID != mine.shareSourceID { ShowLog.log("share: ours (source \(mine.shareSourceID)) on the scenes") }
            activeShare = (mine.shareSourceID, me)
        } else {
            if activeShare != nil { ShowLog.log("share ended") }
            activeShare = nil
        }
    }
    var shareJSON: String {
        let a = activeShare.map { "{\"source\":\($0.sourceID),\"user\":\($0.userID)}" } ?? "null"
        return "{\"active\":\(a),\"viewableSharers\":[\(lastShareList.map(String.init).joined(separator: ","))],\"me\":\(myID.map(String.init) ?? "null"),\"mySources\":\(myShareSources),\"sharing\":\(isSharing)}"
    }

    var asc: ZoomSDKASController? { ZoomSDK.shared().getMeetingService()?.getASController() }

    /// Windows another app owns, big enough to be a picture, on EVERY desktop: the on-screen-only list
    /// hid everything on the operator's other Spaces (2026-09-24). Ours are listed too (the gallery
    /// window as a share is a real use), the operator window is not. Windows off this desktop need a
    /// title (a titleless off-screen window is an app's hidden helper, not a picture) and come after
    /// the visible ones, marked.
    func shareableWindows() -> [ShareableWindow] {
        guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        let ourOutputs = Set(LayoutWindow.Kind.allCases.map(\.title))
        return list.compactMap { w in
            let app = (w[kCGWindowOwnerName as String] as? String) ?? "?"
            let title = (w[kCGWindowName as String] as? String) ?? ""
            // Our own output windows sit at SHIELDING level while ON AIR, which the ordinary-layer test
            // below drops: that is why "ARC Zoom" vanished from the list the moment the outputs went live
            // (2026-09-21). They are the one share the room most wants to send.
            let ours = app == "ARC Zoom" && ourOutputs.contains(title)
            guard let id = w[kCGWindowNumber as String] as? UInt32, ours || (w[kCGWindowLayer as String] as? Int) == 0,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat], let width = b["Width"], let height = b["Height"],
                  width >= 320, height >= 200 else { return nil }
            if app == "ARC Zoom" && !ours { return nil }   // the operator window, and the SDK's own hidden ones (Zoom Client Healthcheck)
            let onScreen = (w[kCGWindowIsOnscreen as String] as? Bool) ?? false
            if !onScreen && (title.isEmpty || ((w[kCGWindowAlpha as String] as? Double) ?? 1) == 0) { return nil }
            return ShareableWindow(id: id, app: app, title: title, width: Int(width), height: Int(height), elsewhere: !onScreen)
        }
        .sorted { ($0.elsewhere ? 1 : 0, $0.app, $0.title) < ($1.elsewhere ? 1 : 0, $1.app, $1.title) }
    }

    func applyShareSettings() {
        guard let asc else { return }
        asc.enableShareComputerSound = shareSound
        asc.enableOptimizingScreenShareForVideoClip = shareOptimizeVideo
        _ = asc.setAudioShareMode(shareStereo ? ZoomSDKAudioShareMode_Stereo : ZoomSDKAudioShareMode_Mono)
    }

    /// `carriesSound`: false for Zoom's camera share, which is picture only whatever SHARE SOUND says (its
    /// log used to read "with sound" for a silent camera share, 2026-09-24).
    func shareResult(_ what: String, _ e: ZoomSDKError?, carriesSound: Bool = true) -> Bool {
        guard let e else { lastError = "not in a meeting"; return false }
        guard e == ZoomSDKError_Success else {
            var reason = ZoomSDKCannotShareReasonType_None
            _ = asc?.canStartShare(&reason)
            lastError = "\(what) refused (\(Self.name(for: e)); cannot-share reason \(reason.rawValue))"
            ShowLog.error("Zoom SDK: \(lastError!)")
            return false
        }
        isSharing = true
        shareStartedAt = Date()
        shareDescription = what
        sharedWindowTitle = what
        ShowLog.log("sharing: \(what)\(!carriesSound ? ", picture only" : (shareSound ? " with sound" : ""))\(shareOptimizeVideo ? ", optimised for video" : "")\(shareStereo ? ", stereo" : "")")
        onRosterChange?()
        return true
    }

    func shareWindow(_ id: CGWindowID, label: String? = nil) -> Bool {
        guard state == .inMeeting else { lastError = "not in a meeting"; return false }
        applyShareSettings()
        guard asc?.isShareAppValid(id) == true else { lastError = "window \(id) cannot be shared (gone, or not an ordinary window)"; return false }
        return shareResult(label ?? "window \(id)", asc?.startAppShare(id))
    }

    func shareDisplay(_ id: CGDirectDisplayID, label: String? = nil) -> Bool {
        guard state == .inMeeting else { lastError = "not in a meeting"; return false }
        applyShareSettings()
        return shareResult(label ?? "display \(id)", asc?.startMonitorShare(id))
    }

    func shareVideoFile(_ path: String) -> Bool {
        guard state == .inMeeting else { lastError = "not in a meeting"; return false }
        guard asc?.canShareVideoFile() == true else { lastError = "video file sharing is not available in this meeting"; return false }
        applyShareSettings()
        return shareResult("video file \((path as NSString).lastPathComponent)", asc?.startVideoFileShare(path, display: canvas()))
    }

    func shareCamera(_ deviceID: String, label: String) -> Bool {
        guard state == .inMeeting else { lastError = "not in a meeting"; return false }
        guard asc?.isAbleToShareCamera() == true else { lastError = "camera sharing is not available in this meeting"; return false }
        applyShareSettings()
        return shareResult("camera \(label)", asc?.startShareCamera(deviceID, display: canvas()), carriesSound: false)
    }

    func shareAudioOnly() -> Bool {
        guard state == .inMeeting else { lastError = "not in a meeting"; return false }
        guard asc?.isAbleToShareComputerAudio() == true else { lastError = "computer audio sharing is not available in this meeting"; return false }
        applyShareSettings()
        return shareResult("computer audio only", asc?.startAudioShare())
    }

    func pauseShare(_ pause: Bool) -> Bool {
        action(pause ? ActionMeetingCmd_PauseShare : ActionMeetingCmd_ResumeShare, user: myID ?? 0, what: pause ? "share paused" : "share resumed")
    }

    /// The old entry point: a window by TITLE (Presenter's "ARC Presenter Program" share window).
    func startShare(windowTitle: String, withSound: Bool) async -> Bool {
        shareSound = withSound
        guard let w = shareableWindows().first(where: { $0.title == windowTitle }) else {
            lastError = "no window titled \"\(windowTitle)\" is on screen"
            ShowLog.error("share: \(lastError!)")
            return false
        }
        return shareWindow(w.id, label: "\(w.app): \(w.title)")
    }

    func stopShare() async {
        rawShare?.detach(); rawShare = nil; previewShare = nil
        _ = asc?.stopShare()
        isSharing = false
        shareDescription = nil
        sharedWindowTitle = nil
        shareCanvas?.orderOut(nil)
        ShowLog.log("share stopped")
        onRosterChange?()
    }

    func canvas() -> NSWindow {
        if let c = shareCanvas { return c }
        let w = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 320, height: 180), styleMask: [.borderless], backing: .buffered, defer: false)
        w.title = "ARC Zoom Share Canvas"
        w.isReleasedWhenClosed = false
        w.level = .normal
        w.orderBack(nil)
        shareCanvas = w
        return w
    }

    var shareStateJSON: String {
        let wins = shareableWindows().prefix(60).map { "{\"id\":\($0.id),\"app\":\"\(jsonEscape($0.app))\",\"title\":\"\(jsonEscape($0.title))\",\"w\":\($0.width),\"h\":\($0.height)}" }.joined(separator: ",")
        let cams = ((ZoomSDK.shared().getSettingService()?.getVideoSetting()?.getCameraList() as? [SDKDeviceInfo]) ?? []).map { "{\"id\":\"\(jsonEscape($0.getDeviceID()))\",\"name\":\"\(jsonEscape($0.getDeviceName()))\"}" }.joined(separator: ",")
        return "{\"sharing\":\(isSharing),\"what\":\(shareDescription.map { "\"\(jsonEscape($0))\"" } ?? "null"),\"sound\":\(shareSound),\"optimizeVideo\":\(shareOptimizeVideo),\"stereo\":\(shareStereo),"
            + "\"canVideoFile\":\(asc?.canShareVideoFile() ?? false),\"canCamera\":\(asc?.isAbleToShareCamera() ?? false),\"canAudioOnly\":\(asc?.isAbleToShareComputerAudio() ?? false),"
            + "\"windows\":[\(wins)],\"cameras\":[\(cams)]}"
    }
}

//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//


import Foundation
import AppKit
import CoreVideo
import ZoomSDK

// MARK: - Support
// Result helpers (apply, action, note), readable error names, diagnostics JSON.
// State lives in SDKZoomEngine.swift; this file is behaviour only (PLAN_stability_refactor.md step 11).

extension SDKZoomEngine {
    /// In someone else's meeting and not yet promoted: most controls will refuse until the host clicks.
    var coHostNeeded: Bool { state == .inMeeting && !amHost && !amCoHost }
    /// Result to log and error, shared by the controls.
    func apply(_ what: String, _ e: ZoomSDKError?) -> Bool {
        guard let e else { lastError = "not in a meeting"; return false }
        if e == ZoomSDKError_Success { ShowLog.log(what); return true }
        lastError = "\(what) refused (\(Self.name(for: e)))" + (coHostNeeded ? "; ARC Zoom needs co-host" : "")
        ShowLog.error("Zoom SDK: \(lastError!)")
        return false
    }
    var act: ZoomSDKMeetingActionController? { ZoomSDK.shared().getMeetingService()?.getMeetingActionController() }

    func note(_ prompt: String) {
        prompts.append(prompt)
        if prompts.count > 40 { prompts.removeFirst(prompts.count - 40) }
        ShowLog.log("prompt: \(prompt)")
    }

    /// The SDK answers in enum cases; an operator needs a word. Only the ones worth telling apart.
    nonisolated static func name(for error: ZoomSDKError) -> String {
        switch error {
        case ZoomSDKError_Success: return "success"
        case ZoomSDKError_Failed: return "failed"
        case ZoomSDKError_Uninit: return "the SDK is not initialised"
        case ZoomSDKError_NoPermission: return "no permission"
        case ZoomSDKError_WrongUsage: return "wrong usage"
        case ZoomSDKError_ServiceFailed: return "the service failed"
        case ZoomSDKError_InvalidParameter: return "invalid parameter"
        case ZoomSDKError_ModuleLoadFail: return "a module failed to load: check that Contents/Frameworks has the whole SDK"
        case ZoomSDKError_NoRecordingInProgress: return "no recording in progress"
        case ZoomSDKError_TooFrequentCall: return "called too often; wait a moment"
        default: return "error \(error.rawValue)"
        }
    }

    nonisolated static func name(for error: ZoomSDKAuthError) -> String {
        switch error {
        case ZoomSDKAuthError_Success: return "success"
        case ZoomSDKAuthError_KeyOrSecretWrong: return "the Client ID or Secret is wrong for this app"
        case ZoomSDKAuthError_AccountNotSupport: return "this Zoom account cannot use the Meeting SDK"
        case ZoomSDKAuthError_AccountNotEnableSDK: return "the Meeting SDK is not enabled for this app: Marketplace > Features > Embed > Meeting SDK"
        case ZoomSDKAuthError_JwtTokenWrong: return "the JWT was rejected: check the Client ID and Secret pair"
        case ZoomSDKAuthError_KeyOrSecretEmpty: return "the Client ID or Secret is empty"
        case ZoomSDKAuthError_Timeout: return "Zoom timed out"
        case ZoomSDKAuthError_NetworkIssue: return "a network problem"
        case ZoomSDKAuthError_Unknown: return "unknown"
        default: return "auth error \(error.rawValue)"
        }
    }

    var diagnosticsJSON: String {
        let invite = meetingInvite
        func q(_ s: String?) -> String { s.map { "\"\(jsonEscape($0))\"" } ?? "null" }
        let inviteJSON = "{\"number\":\(q(invite.number)),\"passcode\":\(q(invite.passcode)),\"url\":\(q(invite.url))}"
        let v = sdkVersion.map { "\"\(jsonEscape($0))\"" } ?? "null"
        let err = lastError.map { "\"\(jsonEscape($0))\"" } ?? "null"
        return "{\"sdkVersion\":\(v),\"authenticated\":\(isAuthenticated),\"rawData\":\(rawDataRunning),\"invite\":\(inviteJSON),\"error\":\(err)}"
    }
}

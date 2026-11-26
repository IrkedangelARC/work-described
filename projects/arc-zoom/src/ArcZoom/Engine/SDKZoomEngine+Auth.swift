//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//


import Foundation
import AppKit
import CoreVideo
import ZoomSDK

// MARK: - Auth
// SDK initialisation, app JWT authentication, OAuth tokens (refresh before browser), unattended handlers.
// State lives in SDKZoomEngine.swift; this file is behaviour only (PLAN_stability_refactor.md step 11).

extension SDKZoomEngine {
    /// The scopes the sidecar asks Zoom for. `user:read:zak` is the one that makes the sidecar the HOST
    /// (and so keeps OBF out of the path); `user:read:token` is only for joining a client-hosted meeting.
    /// The settings pair reads and flips the portal toggles (automated captions, cloud recording) that
    /// `/users/me/settings` refused with 4711 before they were added; Zoom's granular verb is `update`,
    /// not `write`. Changing this list needs a fresh sign-in: a stored token carries its old scope set.
    /// `POST /portal/pmi` needs `user:update:user` as well; it is NOT asked for by default (the operator sets the
    /// PMI in the portal, 2026-09-21), because a scope the Marketplace app does not carry would fail the
    /// consent at every launch. Add it here AND on the app to use that route.
    static let oauthScopes = ["user:read:zak", "user:read:user", "user:read:token",
                              "user:read:settings", "user:update:settings"]

    /// Which of `oauthScopes` a granted scope string is missing. Zoom returns them space separated.
    static func missingScopes(in granted: String?) -> [String] {
        let have = Set((granted ?? "").split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init))
        return have.isEmpty ? [] : oauthScopes.filter { !have.contains($0) }
    }

    /// The SDK is present when this file compiles, but the credentials still have to exist.
    static var available: Bool {
        if case .success = ZoomCredentials.load() { return true }
        return false
    }

    static var unavailableReason: String {
        if case .failure(let e) = ZoomCredentials.load() { return e.description }
        return "the Zoom Meeting SDK is present and credentials are in the keychain"
    }

    /// Initialise the SDK, then authenticate the app. Both are needed once per launch, before anything
    /// else works. Returns false with `lastError` set, never throwing into the operator's face.
    @discardableResult
    func prepare() async -> Bool {
        guard !isAuthenticated else { return true }
        lastError = nil

        guard case .success(let creds) = ZoomCredentials.load() else {
            lastError = Self.unavailableReason
            ShowLog.error("Zoom SDK: \(lastError!)")
            return false
        }

        // Raw video is the whole point of this app, so ask for it before init: the SDK decides its
        // rawdata mode at initialisation and will not change it later.
        let sdk = ZoomSDK.shared()
        sdk.videoRawDataMode = ZoomSDKRawDataMemoryMode_Stack
        sdk.enableRawdataIntermediateMode = false

        let params = ZoomSDKInitParams()
        params.zoomDomain = "zoom.us"
        params.enableLog = true
        params.needCustomizedUI = true      // no Zoom windows: this app draws its own (LayoutWindow)
        let initError = sdk.initSDK(with: params)
        guard initError == ZoomSDKError_Success else {
            lastError = "the Zoom SDK refused to initialise (\(Self.name(for: initError)))"
            ShowLog.error("Zoom SDK: \(lastError!)")
            return false
        }
        didInit = true
        sdkVersion = sdk.getVersionNumber()
        wireMeetingDelegates()
        sdk.getReminderHelper()?.delegate = self
        sdk.getNetworkService()?.delegate = self
        ShowLog.log("Zoom SDK initialised, version \(sdkVersion ?? "?")")

        // App-level JWT from the Client ID and Secret. No OAuth scope is involved at this step.
        let jwt: String
        do {
            jwt = try JWTSigner.makeSDKInitToken(sdkKey: creds.clientID, sdkSecret: creds.clientSecret)
        } catch {
            lastError = "could not sign the SDK token: \(error)"
            ShowLog.error("Zoom SDK: \(lastError!)")
            return false
        }

        let auth = sdk.getAuthService()
        auth.delegate = self
        let context = ZoomSDKAuthContext()
        context.jwtToken = jwt
        let authError = auth.sdkAuth(context)
        guard authError == ZoomSDKError_Success else {
            lastError = "the SDK refused the auth request (\(Self.name(for: authError)))"
            ShowLog.error("Zoom SDK: \(lastError!)")
            return false
        }

        // The verdict comes back on onZoomSDKAuthReturn:.
        let ok = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            authContinuation = c
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                if let pending = self.authContinuation {
                    self.authContinuation = nil
                    self.lastError = "the SDK never answered the auth request within 20 s"
                    ShowLog.error("Zoom SDK: \(self.lastError!)")
                    pending.resume(returning: false)
                }
            }
        }
        isAuthenticated = ok
        if ok {
            // The setting and pre-meeting services only exist once the SDK is authenticated
            // (measured 2026-09-20: both nil straight after initSDK).
            applyUnattendedSettings()
            applyOwnVideoPreference()
            applyVideoQuality()
            restoreAudioDevices()
            sampleSound()
        }
        return ok
    }

    /// The meeting service's per-controller delegates. Set at init AND again on every InMeeting: the
    /// reaction delegate set at init never fired for a real 👍 from the iPad (2026-09-21), and unlike
    /// chat or share there is no list to poll for reactions, so the hypothesis under test is that the
    /// SDK recreates its controllers per meeting and drops delegates set before it.
    func wireMeetingDelegates() {
        guard let m = ZoomSDK.shared().getMeetingService() else { return }
        m.getMeetingActionController().delegate = self
        m.getWaitingRoomController().delegate = self
        m.getASController().delegate = self
        m.getMeetingChatController().delegate = self
        m.getCloseCaptionController().delegate = self
        m.getRecordController().delegate = self
        m.getReactionController().delegate = self
    }

    /// Sign the sidecar in to ARC Tech, once. Opens a browser for Zoom's consent, catches the redirect
    /// on localhost:8767, exchanges the code, and keeps the tokens in the keychain. Needed before the
    /// first join; after that the stored refresh token carries it.
    @discardableResult
    func authorize() async -> Bool {
        guard case .success(let creds) = ZoomCredentials.load() else {
            lastError = Self.unavailableReason
            return false
        }
        // The account this Mac signs in as is pinned to the one it last signed in as (ARC Tech). A browser
        // already signed in to another Zoom account consents AS THAT ACCOUNT, and those tokens used to be
        // stored and used for the show (2026-09-24, Chrome on another account).
        let pinned = TokenStore.load()
        browserSignInExpected = pinned.userEmail ?? pinned.userDisplayName
        browserSignInSince = Date()
        defer { browserSignInSince = nil }
        do {
            let token = try await OAuthFlow.authorize(
                clientId: creds.clientID,
                clientSecret: creds.clientSecret,
                scopes: Self.oauthScopes)
            let info = try? await TokenFetcher.fetchUserInfo(accessToken: token.accessToken)
            if let expectedID = pinned.userId {
                guard let info, info.id == expectedID else {
                    let who = info.map { $0.email ?? $0.displayName ?? $0.id } ?? "an account that could not be checked"
                    lastError = "Zoom sign-in came back as \(who), not \(pinned.userEmail ?? "ARC Tech"). Nothing was saved: sign out of Zoom in the browser (or use a window signed in as ARC Tech) and try again."
                    ShowLog.error("oauth: refused tokens for \(who); this Mac is pinned to \(pinned.userEmail ?? expectedID)")
                    return false
                }
            }
            var stored = TokenStore.load()
            stored.accessToken = token.accessToken
            stored.refreshToken = token.refreshToken
            stored.scope = token.scope
            stored.expiresIn = token.expiresIn
            stored.obtainedAt = Date()
            if let info {
                stored.userId = info.id
                stored.userEmail = info.email
                stored.userDisplayName = info.displayName
                stored.pmi = info.pmi
            }
            if !TokenStore.save(stored) { ShowLog.error("keychain refused the Zoom tokens; sign-in will not survive a relaunch") }
            ShowLog.log("signed in to Zoom as \(stored.userDisplayName ?? stored.userEmail ?? "?")")
            lastError = nil
            return true
        } catch {
            lastError = "Zoom sign-in failed: \(error)"
            ShowLog.error("Zoom SDK: \(lastError!)")
            return false
        }
    }

    /// A usable access token without a browser whenever possible: fresh → as is; stale with a refresh
    /// token → the refresh grant (Zoom rotates the refresh token, so the new one is saved); otherwise
    /// the browser consent. The first build opened the browser 60 minutes after sign-in, in the middle
    /// of a show (audit P1).
    func freshAccessToken() async -> String? {
        var tokens = TokenStore.load()
        // A token keeps the scope set it was granted with, and the refresh grant never widens it. When the
        // Marketplace app gains a scope, only a new browser consent picks it up, so ask for one (once per
        // launch: if Zoom still will not grant it the app has not been saved, and re-asking every call
        // would open a browser mid-show).
        if !reconsentAsked, case .success = ZoomCredentials.load() {
            let missing = Self.missingScopes(in: tokens.scope)
            if !missing.isEmpty, tokens.accessToken != nil {
                reconsentAsked = true
                ShowLog.log("Zoom sign-in needed for new scopes: \(missing.joined(separator: " "))")
                if await authorize(), let a = TokenStore.load().accessToken { return a }
                ShowLog.error("consent did not grant \(missing.joined(separator: " ")); is the Marketplace app saved with them?")
                tokens = TokenStore.load()
            }
        }
        if tokens.accessTokenIsFresh, let a = tokens.accessToken { return a }
        if let r = tokens.refreshToken, case .success(let creds) = ZoomCredentials.load() {
            do {
                let t = try await OAuthFlow.refresh(refreshToken: r, clientId: creds.clientID, clientSecret: creds.clientSecret)
                tokens.accessToken = t.accessToken
                tokens.refreshToken = t.refreshToken ?? r
                tokens.scope = t.scope; tokens.expiresIn = t.expiresIn; tokens.obtainedAt = Date()
                if !TokenStore.save(tokens) { ShowLog.error("keychain refused the refreshed Zoom tokens") }
                ShowLog.log("Zoom access token refreshed without a browser")
                return t.accessToken
            } catch {
                ShowLog.error("Zoom token refresh failed (\(error)); falling back to the browser")
            }
        }
        guard await authorize() else { return nil }
        guard let a = TokenStore.load().accessToken else { lastError = "no Zoom access token"; return nil }
        return a
    }

    /// Everything that would otherwise pop a dialog on a rack Mac nobody is watching
    /// (PLAN_controls.md 3.4). Applied once after init; `GET /meeting` reports what took.
    func applyUnattendedSettings() {
        let sdk = ZoomSDK.shared()
        var applied: [String] = [], refused: [String] = []
        func put(_ name: String, _ e: ZoomSDKError) {
            if e == ZoomSDKError_Success { applied.append(name) } else { refused.append("\(name) (\(Self.name(for: e)))") }
        }
        if let g = sdk.getSettingService()?.getGeneralSetting() {
            put("confirm-on-leave OFF", g.setConfirmLeavingMeeting(false))
            put("mute on lock screen OFF", g.setMuteVideoAndAudioWhenLockScreen(false))
        }
        if let r = sdk.getSettingService()?.getRecordSetting() {
            put("choose recording path on end OFF", r.chooseRecordingPath(whenMeetingEnd: false))
        }
        if let a = sdk.getSettingService()?.getAudioSetting() {
            put("auto-join computer audio ON", a.enableAutoJoinVoip(true))
            put("mic muted on join ON", a.enableMuteMicJoinVoip(true))
            put("3rd-party audio prompt OFF", a.disablePromptJoinAudioDialog(whenUse3rdPartyAudio: true))
        }
        if let pre = sdk.getPremeetingService() {
            pre.disableAutoShowSelectJoinAudioDlg(whenJoinMeeting: true)
            applied.append("join-audio dialog OFF")
        }
        unattended = (applied, refused)
        ShowLog.log("unattended: \(applied.count) settings applied" + (refused.isEmpty ? "" : "; refused: \(refused.joined(separator: ", "))"))
    }

    /// Re-sign the app JWT and authenticate again, for `onZoomAuthIdentityExpired`. Init is not repeated.
    func reauthenticate() async -> Bool {
        guard didInit, case .success(let creds) = ZoomCredentials.load(),
              let jwt = try? JWTSigner.makeSDKInitToken(sdkKey: creds.clientID, sdkSecret: creds.clientSecret) else { return false }
        let auth = ZoomSDK.shared().getAuthService()
        auth.delegate = self
        let context = ZoomSDKAuthContext()
        context.jwtToken = jwt
        guard auth.sdkAuth(context) == ZoomSDKError_Success else { return false }
        let ok = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            authContinuation = c
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                if let pending = self.authContinuation { self.authContinuation = nil; pending.resume(returning: false) }
            }
        }
        isAuthenticated = ok
        ShowLog.log(ok ? "Zoom SDK re-authenticated" : "Zoom SDK re-authentication FAILED")
        return ok
    }
}

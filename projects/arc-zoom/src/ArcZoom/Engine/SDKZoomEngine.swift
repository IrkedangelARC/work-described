//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation
import AppKit
import CoreVideo
import ZoomSDK

/// The real engine: the Zoom Meeting SDK for macOS, v7.1.5.84750, linked from `sdk/ZoomSDK`.
///
/// This file is the engine's STATE: every stored property and nested type, in one place, with the
/// section each belongs to. The behaviour is in one extension per concern (PLAN_stability_refactor.md
/// step 11): `+Auth` (init, JWT, OAuth tokens), `+Meeting` (start, join, end, teardown, spotlight, mute,
/// waiting room), `+Video` (the raw-data gate and subscriptions), `+Share` (remote shares and sharing from
/// the sidecar), `+Devices` (own camera and mic, device lists), `+Roster` (the polled roster), `+Chat`,
/// `+Captions`, `+Recording`, `+Hands`, `+Health` (the 1 Hz sampler and capabilities), `+Support`
/// (result helpers, error names), `+Controls` (settings and sound), `+Events` and `+Delegates` (the SDK
/// callbacks, most of which are SILENT in this setup and are backed by polls).
///
/// Nothing here is `private`: the extensions live in other files and share this state on purpose.
@MainActor
@Observable
final class SDKZoomEngine: NSObject, ZoomEngine {
    let kind = "sdk"
    var state: MeetingState = .idle
    /// Internal setter: the event delegates in SDKZoomEngine+Events.swift report through it too.
    /// The last refused control or failure, with WHEN, so the operator surface can show it briefly.
    var lastError: String? { didSet { if lastError != nil { lastErrorAt = Date() } } }
    @ObservationIgnored var lastErrorAt: Date?
    /// PREVIEW's camera is live AS VIDEO (ARC Zoom's own camera, spotlighted), not as a share.
    var sendingAsVideo = false
    @ObservationIgnored var videoSendRestore: VideoSendRestore?
    @ObservationIgnored weak var previewForVideoSend: PreviewPlayer?
    /// The mic slider was set and the device did not follow (no hardware gain on it).
    var micGainIgnored = false
    /// The slider at 0 muted the sidecar in the call; the slider above 0 undoes only that mute.
    var micMutedBySlider = false
    /// The operator set the mic level by hand this session: SPEECH keeps auto gain off from then on.
    @ObservationIgnored var micLevelManual = false
    @ObservationIgnored var micLevelTarget: Float = 100
    @ObservationIgnored var micLevelCheck: Task<Void, Never>?
    /// A browser consent is out and the app is waiting on its redirect (the operator window shows it, with
    /// CANCEL). nil the rest of the time.
    var browserSignInSince: Date?
    /// The account the browser consent must come back as: ARC Tech, as stored from the last good sign-in.
    var browserSignInExpected: String?
    /// The mic the SDK now sends, whenever it changes (the sidecar re-points its meter).
    @ObservationIgnored var onMicDeviceChange: ((String?) -> Void)?
    /// Policies the SDK has no getter for: the last command we sent (audit: RENAME chip always lit).
    var allowRenameLast = true
    var allowVideoLast = true
    var allowChatLast = true
    /// Background blur on our own camera, re-applied per meeting.
    var wantBlur = false
    /// The invite, cached when the meeting is up: three SDK calls per render otherwise (audit P2).
    var invite: (number: String?, passcode: String?, url: String?) = (nil, nil, nil)
    /// The last saved preferences snapshot; `savePrefs` writes only when something moved.
    @ObservationIgnored var prefsSnapshot = ""
    var participants: [Participant] = []
    var meetingNumber: String?
    var isSharing = false {
        didSet {
            // Any end of our share (STOP, the SDK withdrawing it, the meeting ending) releases PREVIEW's feed.
            guard oldValue, !isSharing else { return }
            rawShare?.detach(); rawShare = nil; previewShare = nil
        }
    }
    var sharedWindowTitle: String?
    /// What PREVIEW put on air: "camera", "camera-raw", "file-raw", "file-sdk"; nil when the share (if any)
    /// came from the SHARE module (SDKZoomEngine+RawShare.swift).
    var previewShare: String?
    /// The external share source while PREVIEW's file or camera + audio feeds the call.
    /// Never simply released: the SDK keeps an UNRETAINED pointer to it and calls it after the share
    /// stops, so a replaced or cleared source is retired (kept alive, cut loose) instead of freed.
    @ObservationIgnored var rawShare: RawShareSource? {
        didSet { if let old = oldValue, old !== rawShare { RawShareSource.retire(old) } }
    }

    @ObservationIgnored var onFrame: ((UInt32, CVPixelBuffer) -> Void)?
    @ObservationIgnored var onRosterChange: (() -> Void)?
    @ObservationIgnored var onStateChange: ((MeetingState) -> Void)?

    /// Authentication is asynchronous and arrives on a delegate; this bridges it back to `authenticate()`.
    @ObservationIgnored var authContinuation: CheckedContinuation<Bool, Never>?
    var isAuthenticated = false
    /// initSDK has run; unInitSDK must run before the process exits.
    @ObservationIgnored var didInit = false
    @ObservationIgnored var subscriptions: [UInt32: VideoSubscription] = [:]
    /// Newest frame per id, one main-actor drain at a time (audit P1: one Task per frame queued without bound).
    @ObservationIgnored lazy var frameGate = FrameCoalescer { [weak self] id, buffer in self?.onFrame?(id, buffer) }
    @ObservationIgnored var rawDataRunning = false
    /// One browser consent per launch when the stored token predates a scope the app now asks for
    /// (SDKZoomEngine+Auth.oauthScopes); never re-asked, so a show cannot be interrupted by a browser.
    @ObservationIgnored var reconsentAsked = false
    /// Holds a webcam's video open so its microphone is not digital silence (WebcamMicKeeper).
    @ObservationIgnored let micKeeper = WebcamMicKeeper()
    /// The entry audio join could not run yet (no own id in the roster at InMeeting, measured
    /// 2026-09-21: "audio on entry: no own id yet"); the roster poll runs it when the id appears.
    @ObservationIgnored var audioJoinPending = false
    /// Spotlight commands the SDK's list has not caught up with yet: user → (wanted, hold until). The
    /// list lags a command by about a second, and reading it in between flickered the chip and the
    /// tiles (2026-09-21: "lights up, goes dark, comes back"). Cleared once the SDK agrees.
    @ObservationIgnored var spotlightPending: [UInt32: (on: Bool, until: Date)] = [:]
    /// The spotlight list as last ACCEPTED (see settleSpotlights): getSpotlightedUserList returns EMPTY
    /// for a moment on every change, and publishing each blank blinked every spotlit chip and tile
    /// (measured 2026-09-21 from the operator's screen recording: both chips dark for ~0.75 s, repeatedly).
    @ObservationIgnored var spotlightAccepted: [UInt32] = []
    /// Ids seen missing from the list ONCE; a second consecutive miss makes the removal real.
    @ObservationIgnored var spotlightRemovalSeen: Set<UInt32> = []
    var sdkVersion: String?

    // MARK: - Meeting facts fed by the event delegates (SDKZoomEngine+Events.swift). Internal setters
    // because that file is a separate compilation unit; nothing outside the engine writes them.
    var hostID: UInt32?
    var myID: UInt32?
    var amHost = false
    var amCoHost = false
    var meetingLocked = false
    var meetingTopic: String?
    var activeSpeakerID: UInt32? { didSet { if let id = activeSpeakerID { lastSpoke[id] = Date() } } }
    /// When each participant last spoke, for the roster order (host first, most recent speaker next).
    var lastSpoke: [UInt32: Date] = [:]
    var raisedHands: Set<UInt32> = []
    var talking: Set<UInt32> = []
    /// Per user, per component, per direction: "video.up" -> "Good". From onUserNetworkStatusChanged.
    var userQuality: [UInt32: [String: String]] = [:]
    var lastWarning: String?
    var waitingRoomIDs: [UInt32] = []
    /// What the unattended-host handlers did, newest last, so a stalled join can be explained.
    var prompts: [String] = []
    /// Venue SSL inspection: off by default, because trusting an unknown certificate is a decision.
    var trustVenueCertificates = false
    var unattended: (applied: [String], refused: [String]) = ([], [])
    var joinPasscode: String?
    var joinDisplayName = "ARC Zoom"

    // Audio routing config (PLAN_controls.md 3.9) and the sound preset, kept here because extensions
    // cannot hold storage. `micIsMixMinus` is the operator's assertion that the selected mic is a
    // mix-minus aux; it is what lets MUSIC through in BASIC.
    var audioConfig = "basic"
    var micIsMixMinus = false
    var soundPreset = "speech"
    var micLevel: UInt32 = 0
    var speakerLevel: UInt32 = 0
    var micTestRunning = false
    var speakerTestRunning = false

    /// Our own send: HD capture (the 720p ceiling; 1080p also needs the account's Group HD setting) and a
    /// smoothness preference (the SDK holds 24 to 30 fps and drops resolution first). Receivers still
    /// decide what they pull: a 360p send means nobody on the call is viewing us large yet.
    // MARK: - Chat
    struct ChatMessage: Identifiable, Equatable {
        let id: String
        let senderID: UInt32
        let sender: String
        let receiver: String
        let text: String
        let time: Date
        let toAll: Bool
        let mine: Bool
    }
    var chatMessages: [ChatMessage] = []
    var unreadChat = 0

    /// The chat controller's delegate did not fire for a phone's message (2026-09-21), like the share
    /// controller's; the message list is the truth. Polled once a second from sample().
    @ObservationIgnored var seenChatIDs: Set<String> = []
    // MARK: - Captions and transcription
    struct Caption: Identifiable, Equatable { let id: String; let speaker: String; let text: String; let time: Date; let final: Bool }
    var captions: [Caption] = []
    var transcriptionStatus = "OFF"
    @ObservationIgnored var lastCaptionAt: Date?
    @ObservationIgnored var transcriptionOnSince: Date?
    @ObservationIgnored var captionHistorySeen: Set<String> = []

    struct Language: Identifiable, Equatable { let id: Int; let name: String }
    // MARK: - Recording (local)
    var recordingStatus = "OFF"
    var mp4Progress = -1
    var lastRecordingPath: String?
    /// Local FILE recording is refused (WrongUsage) while raw video runs: the SDK's recorder is the same
    /// one that releases raw frames (measured 2026-09-21 01:35). So while the outputs are live this
    /// starts CLOUD recording when the account allows it, and says so otherwise. ARC's own recorder of the
    /// program feed, from the frames already in hand, is the real path (PLAN_controls.md).
    var recordingKind = ""
    // MARK: - Hands and reactions
    /// Raise time per hand, so the queue is in order.
    var handRaisedAt: [UInt32: Date] = [:]
    struct Reaction: Identifiable, Equatable { let id = UUID(); let user: UInt32; let name: String; let type: String; let time: Date }
    var reactions: [Reaction] = []
    var hdCapture = true { didSet { applyVideoQuality() } }
    var smoothVideo = true { didSet { applyVideoQuality() } }

    @ObservationIgnored var onShareChange: ((UInt32?) -> Void)?

    var lastShareList: [UInt32] = []
    var myShareSources = 0
    @ObservationIgnored var shareStartedAt: Date?

    /// One-second samples for the sidecar's own window (HEALTH, SETTINGS, SOUND). The getters behind
    /// them are cheap but they are SDK calls, so the view reads these, never the SDK.
    struct HealthSample: Equatable {
        var connection = "", network = "", dataCenter = ""
        var videoUp = "", audioUp = "", videoDown = ""
        var sendKbps = 0, sendFps = 0, sendW = 0, sendH = 0, sendRTT = 0, sendLoss = 0.0
        var recvFps = 0, recvLoss = 0.0
        var shareKbps = 0, shareFps = 0, shareW = 0, shareH = 0
        var advice = ""
    }
    struct SettingsSample: Equatable {
        var allowUnmute = true, waitingRoom = false, muteOnEntry = false, followOrder = false
        var share = "", focusEnabled = false, focus = false
    }
    struct SoundSample: Equatable {
        var original = false, hifi = false, stereo = false, agc = true, noise = "auto"
        var speakerVolume = -1.0, micVolume = -1.0
        var mic = "", speaker = "", camera = ""
        var blur = false
        /// A webcam held open so the pinned mic delivers audio (WebcamMicKeeper), or nil.
        var heldCamera: String?
    }
    var health = HealthSample()
    var settingsSample = SettingsSample()
    var soundSample = SoundSample()
    @ObservationIgnored var sampleTimer: Timer?

    // MARK: - Initialise and authenticate

    // MARK: - ZoomEngine (the rest of Phase 0)

    /// The state before the current one, so InMeeting can tell a fresh join from a reconnect.
    @ObservationIgnored var previousState: MeetingState = .idle
    /// Send our own camera into the meeting. The leading suspect for raw video never arriving: the
    /// sidecar joins sending nothing and renders nothing through the SDK's own UI, so the SDK may never
    /// start its video pipeline at all (2026-09-20, the operator's suggestion). Set BEFORE joining or starting;
    /// the pre-meeting service is where the SDK keeps it.
    var sendsOwnVideo = true {
        didSet { applyOwnVideoPreference() }
    }

    // MARK: - Waiting room (the sidecar is the host, so the sidecar owns the door)

    /// `id` is deviceID + name: the SDK's device IDs are NOT unique (2026-09-20: four clicks on the two
    /// "Insta360 Link 2" chips each selected "Same as system", the first entry with that ID).
    struct AudioDevice: Identifiable, Equatable {
        let deviceID: String; let name: String; let selected: Bool
        var id: String { deviceID + "|" + name }
        var json: String { "{\"id\":\"\(jsonEscape(deviceID))\",\"name\":\"\(jsonEscape(name))\",\"selected\":\(selected)}" }
    }
    /// NEXT (gating item 4): ZoomSDKShareCtrl, sharing by window. Find the CGWindowID for `windowTitle`
    /// the way FakeZoomEngine.windowExists does, and hand it over. This is what removes the operator's
    /// trip through Zoom's share picker.
    // MARK: - Sharing FROM the sidecar (gating item 4 and everything beside it)

    /// Share settings, applied before a share starts (the SDK reads them at start) and live when possible.
    var shareSound = true { didSet { asc?.enableShareComputerSound = shareSound; if isSharing { _ = asc?.enableShareComputerSound(whenSharing: shareSound) } } }
    var shareOptimizeVideo = false { didSet { asc?.enableOptimizingScreenShareForVideoClip = shareOptimizeVideo; if isSharing { _ = asc?.enableOptimizingScreenShareForVideoClip(whenSharing: shareOptimizeVideo) } } }
    var shareStereo = false { didSet { _ = asc?.setAudioShareMode(shareStereo ? ZoomSDKAudioShareMode_Stereo : ZoomSDKAudioShareMode_Mono) } }
    /// What we are sharing, in words, for the UI and the API.
    var shareDescription: String?
    /// Video-file and camera shares want a window to draw into in custom-UI mode; a small one, off screen.
    @ObservationIgnored var shareCanvas: NSWindow?

    struct ShareableWindow: Identifiable {
        let id: CGWindowID; let app: String; let title: String; let width: Int; let height: Int
        /// On another desktop (Space) or minimised: listed, marked, and sorted after the visible ones.
        var elsewhere = false
    }

    // MARK: - Readable error names


    // MARK: - Video: the one HD subscription (PROGRAM); every other tile stays at 360p (SDK budget)
    /// The participant on the room's program gets 720p; everyone else 360p (one HD subscription at a
    /// time, PLAN_controls.md trap 2). The Sidecar sets it on every relayout.
    var hdID: UInt32? {
        didSet {
            guard hdID != oldValue else { return }
            for (id, sub) in subscriptions where sub.rawDataType == ZoomSDKRawDataType_Video { sub.setResolution(id == hdID ? ZoomSDKResolution_720P : ZoomSDKResolution_360P) }
        }
    }


    // MARK: - Share: the active remote share, polled (+Share)
    /// The meeting's active remote share: its share source id (what the renderer subscribes to) and the
    /// sharer. Set from the share controller's events; nil when nobody but us is sharing.
    var activeShare: (sourceID: UInt32, userID: UInt32)? {
        didSet {
            guard activeShare?.sourceID != oldValue?.sourceID else { return }
            onShareChange?(activeShare?.sourceID)
        }
    }


    override init() {
        super.init()
        restorePrefs()
    }

    // MARK: - Preferences (OperatorPrefs): audio config, preset, blur, trust, video quality, own video

    var prefsLine: String { "\(audioConfig)|\(micIsMixMinus)|\(soundPreset)|\(wantBlur)|\(trustVenueCertificates)|\(hdCapture)|\(smoothVideo)|\(sendsOwnVideo)" }
    func restorePrefs() {
        audioConfig = OperatorPrefs.string("audioConfig") ?? audioConfig
        micIsMixMinus = OperatorPrefs.bool("micIsMixMinus", default: micIsMixMinus)
        soundPreset = OperatorPrefs.string("soundPreset") ?? soundPreset
        wantBlur = OperatorPrefs.bool("blur", default: wantBlur)
        trustVenueCertificates = OperatorPrefs.bool("trustVenueCertificates", default: trustVenueCertificates)
        hdCapture = OperatorPrefs.bool("hdCapture", default: hdCapture)
        smoothVideo = OperatorPrefs.bool("smoothVideo", default: smoothVideo)
        sendsOwnVideo = OperatorPrefs.bool("sendsOwnVideo", default: sendsOwnVideo)
        prefsSnapshot = prefsLine
    }
    /// Called by the 1 Hz sampler and at quit; writes only on change.
    func savePrefs() {
        let now = prefsLine
        guard now != prefsSnapshot else { return }
        prefsSnapshot = now
        OperatorPrefs.set("audioConfig", audioConfig); OperatorPrefs.set("micIsMixMinus", micIsMixMinus)
        OperatorPrefs.set("soundPreset", soundPreset); OperatorPrefs.set("blur", wantBlur)
        OperatorPrefs.set("trustVenueCertificates", trustVenueCertificates)
        OperatorPrefs.set("hdCapture", hdCapture); OperatorPrefs.set("smoothVideo", smoothVideo); OperatorPrefs.set("sendsOwnVideo", sendsOwnVideo)
    }

}

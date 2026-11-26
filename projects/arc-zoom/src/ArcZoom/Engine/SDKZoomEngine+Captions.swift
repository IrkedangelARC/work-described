//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//


import Foundation
import AppKit
import CoreVideo
import ZoomSDK

// MARK: - Captions
// Live transcription: start/stop/language, timed text per speaker, the saved-history poll as fallback, diagnostics for the portal toggles.
// State lives in SDKZoomEngine.swift; this file is behaviour only (PLAN_stability_refactor.md step 11).

extension SDKZoomEngine {
    var captionsSupported: Bool { cc?.isLiveTranscriptionFeatureEnabled() ?? false }
    /// ON for a while with nothing arriving: Zoom's caption service has not attached. The clients show
    /// "looking for a service" at the same moment; the portal's Automated Captions setting is the fix.
    var captionsWaiting: Bool { transcriptionStatus == "ON" && lastCaptionAt == nil && (transcriptionOnSince.map { Date().timeIntervalSince($0) > 15 } ?? false) }
    var cc: ZoomSDKCloseCaptionController? { ZoomSDK.shared().getMeetingService()?.getCloseCaptionController() }

    func startTranscription() -> Bool {
        guard let cc else { lastError = "not in a meeting"; return false }
        let can = cc.canStartLiveTranscription()
        guard can == ZoomSDKError_Success else { lastError = "transcription cannot start (\(Self.name(for: can)))"; return false }
        return apply("live transcription started", cc.startLiveTranscription())
    }
    func stopTranscription() -> Bool { apply("live transcription stopped", cc?.stopLiveTranscription()) }

    func spokenLanguages() -> [Language] {
        (cc?.getAvailableMeetingSpokenLanguages() ?? []).map { Language(id: Int($0.languageID), name: $0.languageName ?? "\($0.languageID)") }
    }
    var spokenLanguage: String { cc?.getMeetingSpokenLanguage().languageName ?? "?" }
    func setSpokenLanguage(_ id: Int) -> Bool { apply("spoken language \(id)", cc?.setMeetingSpokenLanguage(Int32(id), isForAll: true)) }

    /// The URL a captioning vendor posts to. Needs the portal's caption API token setting.
    var thirdPartyCaptionURL: String? {
        guard let cc, cc.is3rdPartCCServerAvailable() else { return nil }
        var url: NSString?
        return cc.getClosedCaptionUrlFor3rdParty(&url) == ZoomSDKError_Success ? url as String? : nil
    }

    func caption(_ speaker: String, _ text: String, id: String? = nil, final: Bool, at time: Date = Date()) {
        guard !text.isEmpty else { return }
        let key = id ?? "\(speaker)|\(text)"
        if final, let i = captions.lastIndex(where: { !$0.final && $0.speaker == speaker }) { captions[i] = Caption(id: key, speaker: speaker, text: text, time: time, final: true) }
        else if let i = captions.firstIndex(where: { $0.id == key }) { captions[i] = Caption(id: key, speaker: speaker, text: text, time: time, final: final) }
        else { captions.append(Caption(id: key, speaker: speaker, text: text, time: time, final: final)) }
        if captions.count > 400 { captions.removeFirst(captions.count - 400) }
        lastCaptionAt = Date()
    }

    /// Poll: the status word every second; and if the delegate has gone quiet while transcription runs,
    /// save the CC history the SDK keeps and read any new lines (the delegate pattern failed twice today).
    func pollCaptions() {
        guard let cc else { return }
        let word = Self.transcriptionWord(cc.getLiveTranscriptionStatus().rawValue)
        if word != transcriptionStatus { transcriptionStatus = word; ShowLog.log("transcription \(word)"); transcriptionOnSince = word == "ON" ? Date() : nil }
        guard word == "ON", lastCaptionAt.map({ Date().timeIntervalSince($0) > 8 }) ?? true, cc.isCanSaveClosedCaption() else { return }
        guard cc.saveCCHistory() == ZoomSDKError_Success else { return }
        let path = cc.getClosedCaptionHistorySavedPath()
        guard !path.isEmpty, let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        for line in text.split(separator: "\n").map(String.init) where !captionHistorySeen.contains(line) {
            captionHistorySeen.insert(line)
            // "HH:MM:SS Speaker Name: words"
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2, let colon = parts[1].firstIndex(of: ":") else { continue }
            let speaker = String(parts[1][..<colon]).trimmingCharacters(in: .whitespaces)
            let words = String(parts[1][parts[1].index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            caption(speaker, words, id: line, final: true)
        }
    }

    /// ZoomSDKLiveTranscriptionStaus: 0 stop, 1 start, 2 user subscribed, 10 service connecting.
    nonisolated static func transcriptionWord<T: BinaryInteger>(_ raw: T) -> String {
        switch raw { case 1: return "ON"; case 2: return "SUBSCRIBED"; case 10: return "CONNECTING"; default: return "OFF" }
    }

    /// Why captions might be silent, measured: each is a separate SDK answer.
    var captionDiagnostics: String {
        guard let cc else { return "{}" }
        return "{\"canStart\":\"\(Self.name(for: cc.canStartLiveTranscription()))\",\"meetingSupportsCC\":\(cc.isMeetingSupportCloseCaption()),\"featureEnabled\":\(cc.isLiveTranscriptionFeatureEnabled()),\"thirdPartyServer\":\(cc.is3rdPartCCServerAvailable()),\"multiLanguage\":\(cc.isMultiLanguageTranscriptionEnabled()),\"canSaveHistory\":\(cc.isCanSaveClosedCaption()),\"legalNotice\":\(cc.isLiveTranscriptLegalNoticeAvailable()),\"rawStatus\":\(cc.getLiveTranscriptionStatus().rawValue)}"
    }

    var captionsJSON: String {
        let list = captions.suffix(100).map { "{\"id\":\"\(jsonEscape($0.id))\",\"speaker\":\"\(jsonEscape($0.speaker))\",\"text\":\"\(jsonEscape($0.text))\",\"time\":\(Int($0.time.timeIntervalSince1970)),\"final\":\($0.final)}" }.joined(separator: ",")
        return "{\"status\":\"\(transcriptionStatus)\",\"diagnostics\":\(captionDiagnostics),\"supported\":\(captionsSupported),\"language\":\"\(jsonEscape(spokenLanguage))\",\"vendorURL\":\(thirdPartyCaptionURL.map { "\"\(jsonEscape($0))\"" } ?? "null"),\"captions\":[\(list)]}"
    }
}

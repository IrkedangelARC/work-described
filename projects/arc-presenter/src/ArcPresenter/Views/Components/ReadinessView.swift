//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI
import Combine
import AppKit
import ApplicationServices
import ARCDeckLink

/// What this Mac has granted ARC Presenter and what it is missing, readable at
/// a glance on the load screen (V4.1, the fresh-Mac lesson of 2026-09-15:
/// every permission a switch needs must be visible BEFORE show day, with the
/// button that fixes it on the same row). Re-checked every few seconds.
@MainActor @Observable final class Readiness {
    struct Check: Identifiable {
        let id: String; let ok: Bool; let label: String; let required: Bool; let hint: String
        /// One or two words for a status tile: GRANTED, NOT GRANTED, INSTALLED, NONE, READY.
        var state: String = ""
        var action: (title: String, run: @MainActor () -> Void)? = nil
    }
    var checks: [Check] = []

    static let powerPointBundleID = "com.microsoft.Powerpoint"

    func refresh() {
        let ax = AXIsProcessTrusted()
        let screen = CGPreflightScreenCaptureAccess()
        let displays = NSScreen.screens.count
        let pptURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.powerPointBundleID)
        let automation = Self.automationState(for: Self.powerPointBundleID)

        var list: [Check] = []
        var axCheck = Check(id: "ax", ok: ax, label: "ACCESSIBILITY", required: true,
                            hint: ax ? "granted: clicker and keyboard reach the show" : "System Settings > Privacy & Security > Accessibility: switch on ARC Presenter (the clicker needs it)")
        axCheck.state = ax ? "GRANTED" : "NOT GRANTED"
        if !ax { axCheck.action = ("GRANT", { _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary) }) }
        list.append(axCheck)

        var screenCheck = Check(id: "screen", ok: screen, label: "SCREEN RECORDING", required: false,
                                hint: screen ? "granted: a PowerPoint deck can be taken live" : "needed only for PowerPoint decks: System Settings > Privacy & Security > Screen & System Audio Recording, then relaunch ARC Presenter")
        screenCheck.state = screen ? "GRANTED" : "NOT GRANTED"
        if !screen { screenCheck.action = ("GRANT", { _ = CGRequestScreenCaptureAccess() }) }
        list.append(screenCheck)

        list.append(Check(id: "ppt", ok: pptURL != nil, label: "POWERPOINT", required: false,
                          hint: pptURL != nil ? "installed" : "not installed: PowerPoint decks cannot be taken live on this Mac; .arcdeck and PDF play as usual",
                          state: pptURL != nil ? "INSTALLED" : "NONE"))

        if pptURL != nil {
            var autoCheck: Check
            switch automation {
            case .granted:
                autoCheck = Check(id: "auto", ok: true, label: "POWERPOINT CONTROL", required: false, hint: "granted: ARC Presenter may drive PowerPoint's show", state: "GRANTED")
            case .denied:
                autoCheck = Check(id: "auto", ok: false, label: "POWERPOINT CONTROL", required: false,
                                  hint: "DENIED: System Settings > Privacy & Security > Automation > ARC Presenter: switch on Microsoft PowerPoint", state: "DENIED")
            case .notAsked:
                autoCheck = Check(id: "auto", ok: false, label: "POWERPOINT CONTROL", required: false,
                                  hint: "not asked yet: macOS asks the first time a PowerPoint deck is opened from SOURCES; click OK then", state: "NOT ASKED")
                autoCheck.action = ("ASK NOW", { Self.askAutomation(for: Self.powerPointBundleID) })
            case .powerPointNotRunning:
                autoCheck = Check(id: "auto", ok: false, label: "POWERPOINT CONTROL", required: false,
                                  hint: "unknown until PowerPoint is running; open a deck from SOURCES and answer the prompt (or ASK NOW launches PowerPoint and asks)", state: "UNKNOWN")
                autoCheck.action = ("ASK NOW", { Self.askAutomation(for: Self.powerPointBundleID) })
            }
            list.append(autoCheck)
        }

        let driver = DeckLinkOutput.driverInstalled
        let dlCount = driver ? DeckLinkFillKeyOutput.devices().filter(\.supportsPlayback).count : 0
        list.append(Check(id: "decklink", ok: driver && dlCount > 0, label: "DECKLINK / SDI", required: false,
                          hint: !driver ? "Blackmagic Desktop Video not installed: optional, only for PROGRAM over SDI / HDMI from an UltraStudio"
                              : dlCount == 0 ? "driver installed, no UltraStudio / DeckLink output connected (optional)"
                              : "\(dlCount) output device\(dlCount == 1 ? "" : "s") ready: pick it under SDI in the header",
                          state: !driver ? "NO DRIVER" : dlCount == 0 ? "NO DEVICE" : "READY"))
        list.append(Check(id: "display", ok: displays > 1, label: "EXTERNAL DISPLAY", required: false,
                          hint: displays > 1 ? "\(displays - 1) connected: assign PROGRAM and MONITOR in the header" : "none connected: outputs open once a display is plugged in",
                          state: displays > 1 ? "\(displays - 1) CONNECTED" : "NONE"))
        checks = list
    }

    var allRequiredOK: Bool { checks.filter(\.required).allSatisfy(\.ok) }
    var allOK: Bool { checks.allSatisfy(\.ok) }

    enum AutomationState { case granted, denied, notAsked, powerPointNotRunning }

    /// Apple Events permission to `bundleID`, WITHOUT prompting. macOS can only
    /// answer for a running target, so a stopped PowerPoint reads as unknown.
    static func automationState(for bundleID: String) -> AutomationState {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty == false else {
            return .powerPointNotRunning
        }
        var target = AEAddressDesc()
        let bytes = Array(bundleID.utf8)
        let made = bytes.withUnsafeBufferPointer { buf in
            AECreateDesc(typeApplicationBundleID, buf.baseAddress, buf.count, &target)
        }
        guard made == noErr else { return .powerPointNotRunning }
        defer { AEDisposeDesc(&target) }
        let status = AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, false)
        switch status {
        case noErr: return .granted
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(errAEEventWouldRequireUserConsent): return .notAsked
        case OSStatus(procNotFound): return .powerPointNotRunning
        default: return .notAsked
        }
    }

    /// Launch the target if needed and let macOS put up its consent dialog.
    static func askAutomation(for bundleID: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        let config = NSWorkspace.OpenConfiguration(); config.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                var target = AEAddressDesc()
                let bytes = Array(bundleID.utf8)
                _ = bytes.withUnsafeBufferPointer { buf in AECreateDesc(typeApplicationBundleID, buf.baseAddress, buf.count, &target) }
                _ = AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, true)
                AEDisposeDesc(&target)
            }
        }
    }
}

/// THIS MAC on the load screen: one status tile per check (name over state, the long hint in the
/// tooltip), ONE fix for the permissions, and the PRE-SHOW CHECK. Not-required items that are
/// missing read amber, never red: a dev box with no second display is not an error.
struct ReadinessView: View {
    @Bindable var readiness: Readiness
    private let ticker = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    private var grants: [Readiness.Check] { readiness.checks.filter { $0.action?.title == "GRANT" } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // One row of equal tiles when it fits, else a wrapping grid beside the buttons, else stacked.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    HStack(alignment: .top, spacing: 6) {
                        ForEach(readiness.checks) { c in ReadinessTile(check: c).frame(minWidth: 176, maxWidth: .infinity) }
                    }
                    actions.frame(width: 260)
                }
                HStack(alignment: .top, spacing: 12) {
                    tiles.frame(minWidth: 560, maxWidth: .infinity)
                    actions.frame(width: 260)
                }
                VStack(alignment: .leading, spacing: 10) {
                    tiles
                    actions
                }
            }
            PreShowResults()
        }
        .arcModule(title: "THIS MAC", tint: ARCTheme.secGreen,
                   badge: readiness.checks.isEmpty ? nil
                        : readiness.allRequiredOK ? ARCBandBadge(text: "READY", fill: ARCTheme.ink)
                        : ARCBandBadge(text: "NOT READY", fill: ARCTheme.liveRed))
        .onAppear { readiness.refresh() }
        .onReceive(ticker) { _ in readiness.refresh() }
    }

    private var tiles: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 176), spacing: 6)], alignment: .leading, spacing: 6) {
            ForEach(readiness.checks) { c in ReadinessTile(check: c) }
        }
    }

    private var actions: some View {
        VStack(spacing: 6) {
            let pending = grants
            Button {
                Task { @MainActor in
                    // The GRANT actions, in the order the rows list them; each puts up its own macOS prompt.
                    for c in pending {
                        c.action?.run()
                        try? await Task.sleep(for: .milliseconds(700))
                    }
                    readiness.refresh()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: pending.isEmpty ? "checkmark.shield" : "wrench.and.screwdriver")
                        .font(.system(size: 13, weight: .semibold))
                    Text(pending.isEmpty ? "PERMISSIONS OK" : "FIX \(pending.count) PERMISSION\(pending.count == 1 ? "" : "S")")
                        .font(ARCTheme.mono(12, .heavy)).tracking(0.8).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(pending.isEmpty ? ARCTheme.textTertiary : ARCTheme.textPrimary)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity).frame(height: 36)
                .background(ARCTheme.surfaceLight)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(pending.isEmpty ? ARCTheme.line : ARCTheme.warn, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(pending.isEmpty)
            .help(pending.isEmpty ? "Every permission ARC Presenter asks for is granted"
                  : "Asks macOS for: " + pending.map { $0.label.capitalized }.joined(separator: ", ") + ". Switch ARC Presenter on in the System Settings pane that opens.")
            PreShowCheckButton()
        }
    }
}

/// A THIS MAC tile: the name over its state with a dot, the full hint as the tooltip. A tile with
/// an action (GRANT, ASK NOW) is a button that runs it.
private struct ReadinessTile: View {
    let check: Readiness.Check
    @State private var hover = false

    private var level: ARCStatusLevel { check.ok ? .ok : (check.required ? .bad : .warn) }
    private var colour: Color {
        switch level { case .ok: ARCTheme.readyGreen; case .warn: ARCTheme.warn; case .bad: ARCTheme.liveRed; case .off: ARCTheme.text2 }
    }

    private var tile: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(check.label)
                    .font(ARCTheme.mono(10, .heavy)).tracking(0.6)
                    .foregroundStyle(ARCTheme.textSecondary)
                    .lineLimit(1).minimumScaleFactor(0.85)
                Spacer(minLength: 0)
                if check.required {
                    Text("REQ").font(ARCTheme.mono(9, .heavy)).foregroundStyle(ARCTheme.textTertiary).fixedSize()
                }
            }
            HStack(spacing: 6) {
                Circle().fill(colour).frame(width: 8, height: 8)
                Text(check.state.isEmpty ? (check.ok ? "OK" : "MISSING") : check.state)
                    .font(ARCTheme.mono(14, .heavy))
                    .foregroundStyle(level == .ok ? ARCTheme.textPrimary : colour)
                    .lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 0)
                if let a = check.action {
                    Text(a.title)
                        .font(ARCTheme.mono(9, .heavy))
                        .foregroundStyle(hover ? ARCTheme.ink : ARCTheme.textPrimary)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(hover ? ARCTheme.text0 : ARCTheme.subGroup)
                        .cornerRadius(3)
                        .fixedSize()
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ARCTheme.surfaceLight)
        .overlay(alignment: .leading) { Rectangle().fill(colour).frame(width: 3) }
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(level == .bad ? ARCTheme.liveRed : (hover && check.action != nil ? ARCTheme.text2 : ARCTheme.line), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    var body: some View {
        if let a = check.action {
            Button { a.run() } label: { tile.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .onHover { hover = $0 }
                .help(check.hint + "\n\nClick: " + a.title)
        } else {
            tile.help(check.hint)
        }
    }
}


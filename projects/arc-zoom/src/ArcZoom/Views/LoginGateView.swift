//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI
import ARCStyle

/// The operator window until OPERATOR signs in (AppLogin.swift: a guard, not a lock). OperatorView is not
/// built at all while this shows, so none of its keyboard shortcuts can fire behind it.
struct LoginGateView: View {
    @State private var login = AppLogin.shared
    @State private var user = AppLogin.user
    @State private var password = ""
    @State private var refused = false
    @FocusState private var passwordFocused: Bool
    /// `provisioned` reads the keychain, which SwiftUI cannot observe: a seed that lands while this screen is
    /// up (seed-zoom-credentials.sh launches the app, then posts) must flip it without a relaunch. The re-check
    /// is free: a missing item never raises a dialog, and a present or refused one is answered from
    /// Keychain's cache, so this timer can no longer re-ask after a Deny (2026-09-23).
    @State private var tick = 0
    private let recheck = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    @Environment(Sidecar.self) private var sidecar
    @Environment(DisplayManager.self) private var displays
    /// SIGN IN beside THIS GATE from 900 pt of content, else stacked.
    @State private var wide = true

    /// The welcome standard (2026-09-23, after Presenter 5.5.0's first screen): a header bar, the SIGN IN module,
    /// a module saying what the gate does and does not guard, and THIS MAC as status tiles with tooltips. The
    /// logic is unchanged: one `provisioned` read per render (Keychain-cached), `refused` only when it is not,
    /// the 2 s re-check, TRY AGAIN. The tiles read nothing new from the keychain.
    var body: some View {
        let _ = tick
        let provisioned = login.provisioned
        let keychainRefused = !provisioned && AppLogin.refused
        VStack(spacing: 0) {
            header(provisioned: provisioned, keychainRefused: keychainRefused)
            ARCTheme.divider.frame(height: 1)
            // Centred in the window when it is taller than the content; scrolls when it is shorter.
            GeometryReader { g in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: ARCTheme.railPad) {
                    // ONE copy of the fields, laid out by width. A ViewThatFits built the SIGN IN module twice, two
                    // SecureFields on one FocusState, and the live window hung in a SwiftUI update loop (2026-09-23).
                    (wide ? AnyLayout(HStackLayout(alignment: .top, spacing: ARCTheme.railPad))
                          : AnyLayout(VStackLayout(alignment: .leading, spacing: ARCTheme.railPad))) {
                        signIn(provisioned: provisioned, keychainRefused: keychainRefused).frame(width: wide ? 440 : nil)
                        aboutGate
                    }
                    thisMac(provisioned: provisioned, keychainRefused: keychainRefused)
                }
                .padding(ARCTheme.railPad)
                .frame(maxWidth: 1100, alignment: .topLeading)
                .frame(maxWidth: .infinity)
                .onGeometryChange(for: Bool.self) { $0.size.width >= 900 } action: { wide = $0 }
                .frame(minHeight: g.size.height, alignment: .center)
            }
            }
        }
        .frame(minWidth: 520, maxWidth: .infinity, minHeight: 420, maxHeight: .infinity)
        .background(ARCTheme.ink)
        .onAppear { passwordFocused = true }
        .onReceive(recheck) { _ in if !login.provisioned { tick += 1 } }
        .onReceive(NotificationCenter.default.publisher(for: .arcKeychainChanged)) { _ in tick += 1 }
    }

    // MARK: - Header

    private func header(provisioned: Bool, keychainRefused: Bool) -> some View {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = "V\(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))"
        return HStack(spacing: ARCTheme.s(10)) {
            Text("ARC ZOOM").font(ARCTheme.ui(18, .heavy)).tracking(2).foregroundStyle(ARCTheme.text0).fixedSize()
            Text(version).font(ARCTheme.ui(10, .bold)).foregroundStyle(ARCTheme.text1).fixedSize()
                .padding(.horizontal, 6).padding(.vertical, 2)
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(ARCTheme.line, lineWidth: 1))
                .help("Version (build) \(info["ARCGitHash"] as? String ?? "")")
            #if DEBUG
            Text("DEBUG").font(ARCTheme.ui(10, .heavy)).foregroundStyle(ARCTheme.ink).fixedSize()
                .padding(.horizontal, 6).padding(.vertical, 2).background(ARCTheme.warn).cornerRadius(3)
            #endif
            Spacer(minLength: ARCTheme.s(10))
            Text(provisioned ? "OPERATOR WINDOW LOCKED" : (keychainRefused ? "LOGIN REFUSED BY MACOS" : "NO LOGIN ON THIS MAC"))
                .font(ARCTheme.ui(11, .heavy)).foregroundStyle(provisioned ? ARCTheme.text1 : ARCTheme.warn).lineLimit(1)
        }
        .padding(.horizontal, ARCTheme.s(14)).padding(.vertical, ARCTheme.s(12))
        .background(ARCTheme.surface)
    }

    // MARK: - SIGN IN

    private func signIn(provisioned: Bool, keychainRefused: Bool) -> some View {
        VStack(alignment: .leading, spacing: ARCTheme.s(10)) {
            if provisioned {
                VStack(alignment: .leading, spacing: 8) {
                    field("USER") { TextField("User", text: $user).textFieldStyle(.roundedBorder) }
                    field("PASSWORD") {
                        SecureField("Password", text: $password).textFieldStyle(.roundedBorder)
                            .focused($passwordFocused)
                            .onSubmit(submit)
                    }
                }
                ARCActionButton("SIGN IN", enabled: !password.isEmpty, action: submit)
                    .frame(height: 44)
                    .keyboardShortcut(.defaultAction)
                Text(refused ? "User or password not recognised" : " ")
                    .font(ARCTheme.ui(11, .regular)).foregroundStyle(ARCTheme.warn)
            } else if keychainRefused {
                Text("macOS refused ARC Zoom its OPERATOR login in the keychain.\nClick TRY AGAIN and choose Always Allow once.")
                    .font(ARCTheme.ui(12, .regular)).foregroundStyle(ARCTheme.text0)
                    .fixedSize(horizontal: false, vertical: true)
                arcChip("TRY AGAIN", fill: ARCTheme.arcRed) { Keychain.invalidate(); tick += 1 }
            } else if Keychain.loading {
                // The launch preload is still out (Keychain.swift reads off the main thread). Normally a blink;
                // when macOS is holding the read behind an approval dialog, say where to look.
                Text(Keychain.waitingOnMacOS ? "Waiting for macOS to allow ARC Zoom into the keychain.\nLook for its dialog (bring ARC Zoom to the front) and choose Always Allow."
                                             : "Checking this Mac's keychain…")
                    .font(ARCTheme.ui(12, .regular)).foregroundStyle(ARCTheme.text0)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("This Mac has no OPERATOR login yet.\nFrom the office workstation: seed-zoom-credentials.sh <host>")
                    .font(ARCTheme.ui(12, .regular)).foregroundStyle(ARCTheme.text0)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text("This screen notices the seed on its own; no relaunch.")
                    .font(ARCTheme.ui(11, .regular)).foregroundStyle(ARCTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .arcModule(title: "SIGN IN", tint: ARCTheme.secBlue)
    }

    private func field<F: View>(_ label: String, @ViewBuilder _ content: () -> F) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(ARCTheme.ui(10, .heavy)).foregroundStyle(ARCTheme.textSecondary)
            content()
        }
    }

    // MARK: - What the gate guards

    private var aboutGate: some View {
        VStack(alignment: .leading, spacing: ARCTheme.s(6)) {
            line("GUARDS", "the operator window: meeting, participants, share, outputs, settings")
            line("STILL LIVE", "the control API on 127.0.0.1:8766 (Presenter and Companion drive it with nobody at the keyboard)")
            line("⌘⇧E", "Meeting > End Meeting for Everyone works without signing in: ending never waits on a password")
            line("⌘⇧L", "locks the operator window again once you are in")
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .arcModule(title: "THIS GATE", tint: ARCTheme.text2)
    }

    private func line(_ key: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: ARCTheme.s(10)) {
            Text(key).font(ARCTheme.ui(11, .heavy)).foregroundStyle(ARCTheme.text0).frame(width: 110, alignment: .leading)
            Text(text).font(ARCTheme.ui(11, .regular)).foregroundStyle(ARCTheme.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - THIS MAC

    private func thisMac(provisioned: Bool, keychainRefused: Bool) -> some View {
        let sdk = sidecar.engineKind == "sdk"
        let externals = displays.externalScreens.count
        let meeting: (String, ARCStatusLevel) = {
            switch sidecar.state {
            case .idle: return ("OUT", .off)
            case .joining: return ("JOINING", .warn)
            case .inMeeting: return ("IN", .ok)
            case .reconnecting: return ("RECONNECTING", .warn)
            case .failed: return ("FAILED", .bad)
            }
        }()
        let tiles = Group {
            ARCStatusTile(name: "LOGIN", state: provisioned ? "SEEDED" : (keychainRefused ? "REFUSED" : "NOT SEEDED"),
                          level: provisioned ? .ok : .warn, widest: ("LOGIN", "NOT SEEDED"))
                .help(provisioned ? "The OPERATOR login is in this Mac's keychain" : (keychainRefused ? "The item is there but macOS refused this build: TRY AGAIN, Always Allow" : "Seed it from the office workstation: seed-zoom-credentials.sh <host>"))
            ARCStatusTile(name: "ENGINE", state: sdk ? "SDK" : "FAKE", level: sdk ? .ok : .warn, widest: ("ENGINE", "FAKE"))
                .help(sdk ? "The Zoom Meeting SDK is up: devices and pre-flight are ready behind this screen" : "Still the rehearsal engine: the SDK starts a few seconds after launch, or has no Marketplace pair (see the log)")
            ARCStatusTile(name: "MEETING", state: meeting.0, level: meeting.1, widest: ("MEETING", "RECONNECTING"))
                .help("A meeting can be up behind this screen: the control API starts and ends meetings without the operator window")
            ARCStatusTile(name: "DISPLAYS", state: externals == 0 ? "NONE" : "\(externals) EXTERNAL", level: externals == 0 ? .warn : .ok, widest: ("DISPLAYS", "9 EXTERNAL"))
                .help("External displays for PGM and MON, assigned in the operator window's header")
            ARCStatusTile(name: "CONTROL API", state: ":8766", level: .ok, widest: ("CONTROL API", ":8766"))
                .help("curl 127.0.0.1:8766/routes lists every route. Not behind this gate")
        }
        return FlowRow(spacing: ARCTheme.s(8)) { tiles }
            .frame(maxWidth: .infinity, alignment: .leading)
            .arcModule(title: "THIS MAC", tint: ARCTheme.secGreen)
    }

    private func submit() {
        refused = !login.attempt(user: user, password: password)
        password = ""
    }
}

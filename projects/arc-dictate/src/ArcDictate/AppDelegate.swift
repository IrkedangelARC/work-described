import AppKit
import AVFoundation
import Carbon.HIToolbox
import CoreAudio

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private enum State {
        case idle
        case recording
        case transcribing
    }

    private var state: State = .idle
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let recorder = Recorder()
    private var dictateHotkey: Hotkey?
    private var cancelHotkey: Hotkey?
    private var tickTimer: Timer?
    private var recordingURL: URL?
    private var lastPeakDB: Float = -120
    private var probe: LevelProbe?
    private var job: TranscriptionJob?
    private var deviceListenerInstalled = false

    private let workQueue = DispatchQueue(label: "com.example.arc.ArcDictate.transcribe", qos: .userInitiated)

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        Vocabulary.ensureSeeded()

        // Runs a WAV through the real transcription path and prints the result, so the
        // vocabulary and context-budget plumbing can be checked without a microphone.
        if let index = CommandLine.arguments.firstIndex(of: "--transcribe-file"),
           index + 1 < CommandLine.arguments.count {
            transcribeAndExit(URL(fileURLWithPath: CommandLine.arguments[index + 1]))
            return
        }

        sweepStaleRecordings()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        menu.delegate = self
        render()

        dictateHotkey = Hotkey(keyCode: Prefs.hotkeyCode, modifiers: Prefs.hotkeyModifiers) { [weak self] in
            DispatchQueue.main.async { self?.toggle() }
        }
        cancelHotkey = Hotkey(keyCode: Prefs.cancelHotkeyCode, modifiers: Prefs.cancelHotkeyModifiers) { [weak self] in
            DispatchQueue.main.async { self?.cancelCurrent() }
        }

        installDeviceListener()

        // Draws the panel with sample content and no microphone, so its layout can be
        // checked without opening a live input.
        if CommandLine.arguments.contains("--hud-demo") {
            HUD.shared.show("Listening…  0:07", meterDB: -14, caption: hudHint())
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                HUD.shared.show("Send the estimate to the client for the main hall job on Thursday.",
                                caption: "Pasted  ·  peak -12 dBFS")
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        job?.cancel()
        if recorder.isRecording { recorder.stop() }
        if let url = recordingURL { try? FileManager.default.removeItem(at: url) }
        recordingURL = nil
    }

    private func transcribeAndExit(_ url: URL) -> Never {
        let prompt = Prefs.useVocabulary ? Vocabulary.prompt() : nil
        FileHandle.standardError.write(Data("prompt: \(prompt ?? "(none)")\n".utf8))
        do {
            let text = try TranscriptionJob().run(audio: url, language: Prefs.language, prompt: prompt)
            print(text)
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    /// Temp WAVs are removed as each take finishes, but a crash or a force quit mid-take
    /// leaves one behind. Clear anything older than an hour at launch.
    private func sweepStaleRecordings() {
        let directory = FileManager.default.temporaryDirectory
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]) else { return }

        let cutoff = Date().addingTimeInterval(-3600)
        for entry in entries where entry.lastPathComponent.hasPrefix("arc-dictate-") {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified > cutoff { continue }
            try? FileManager.default.removeItem(at: entry)
        }
    }

    // MARK: - Device changes

    /// Core Audio tells us when devices come and go. If the one being recorded disappears
    /// mid-take, the take is over: say so rather than writing silence.
    private func installDeviceListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main) { [weak self] _, _ in
                self?.devicesChanged()
            }
        deviceListenerInstalled = (status == noErr)
    }

    private func devicesChanged() {
        guard state == .recording, let uid = Prefs.deviceUID else { return }
        guard AudioDevices.device(withUID: uid) == nil else { return }
        abandonTake(reason: "Input device disappeared", detail: "The selected input was unplugged mid-take.")
    }

    // MARK: - Status item

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let rightClick = NSApp.currentEvent?.type == .rightMouseUp
        if rightClick {
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            toggle()
        }
    }

    private func render() {
        guard let button = statusItem.button else { return }
        switch state {
        case .idle:
            button.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "ARC Dictate")
            button.title = ""
            button.toolTip = "ARC Dictate — click or press \(Prefs.hotkeyDescription) to dictate"
        case .recording:
            button.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Recording")
            button.title = " " + elapsedText()
            button.toolTip = "Recording — \(Prefs.hotkeyDescription) to stop, \(Prefs.cancelHotkeyDescription) to discard"
        case .transcribing:
            button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Transcribing")
            button.title = " …"
            button.toolTip = "Transcribing — \(Prefs.cancelHotkeyDescription) to cancel"
        }
        button.image?.isTemplate = true
    }

    private func elapsed() -> TimeInterval {
        recorder.startedAt.map { Date().timeIntervalSince($0) } ?? 0
    }

    private func elapsedText() -> String {
        let seconds = Int(elapsed())
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    // MARK: - Recording

    private func toggle() {
        switch state {
        case .idle: beginRecording()
        case .recording: endRecording(reason: .user)
        case .transcribing: NSSound.beep()
        }
    }

    /// The escape hatch: discard a take being recorded, or kill a transcription in flight.
    private func cancelCurrent() {
        switch state {
        case .idle:
            break
        case .recording:
            abandonTake(reason: "Take discarded", detail: nil)
        case .transcribing:
            job?.cancel()
        }
    }

    private func abandonTake(reason: String, detail: String?) {
        tickTimer?.invalidate()
        tickTimer = nil
        recorder.stop()
        if let url = recordingURL { try? FileManager.default.removeItem(at: url) }
        recordingURL = nil
        state = .idle
        render()
        play("Basso")
        HUD.shared.show(reason, caption: detail)
        HUD.shared.dismiss(after: 2.5)
    }

    private func beginRecording() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            startCapture()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted { self?.startCapture() } else { self?.showMicrophoneDenied() }
                }
            }
        default:
            showMicrophoneDenied()
        }
    }

    private func startCapture() {
        let device = selectedDevice()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("arc-dictate-\(UUID().uuidString).wav")

        do {
            try recorder.start(deviceID: device?.id ?? AudioDevices.defaultInput(),
                               channel: Prefs.channel,
                               to: url)
        } catch {
            report(error)
            return
        }

        recordingURL = url
        state = .recording
        render()
        play("Tink")

        HUD.shared.show("Listening…  0:00", meterDB: -120, caption: hudHint())
        recorder.onLevel = { [weak self] level in
            guard let self, self.state == .recording else { return }
            HUD.shared.show("Listening…  " + self.elapsedText(), meterDB: level, caption: self.hudHint())
        }

        // .common, so the countdown keeps running while a menu is open.
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    private func tick() {
        guard state == .recording else { return }
        if elapsed() >= Prefs.maximumRecordingSeconds {
            endRecording(reason: .limit)
        } else {
            render()
        }
    }

    private enum StopReason {
        case user
        case limit
    }

    private func endRecording(reason: StopReason) {
        tickTimer?.invalidate()
        tickTimer = nil

        let duration = recorder.stop()
        lastPeakDB = recorder.peakDB
        let dropped = recorder.droppedSamples

        guard let url = recordingURL else {
            state = .idle
            render()
            HUD.shared.dismiss()
            return
        }
        recordingURL = nil

        guard duration >= 0.4 else {
            try? FileManager.default.removeItem(at: url)
            state = .idle
            render()
            HUD.shared.show("Too short", caption: "Hold the take open long enough to speak.")
            HUD.shared.dismiss(after: 2)
            return
        }

        state = .transcribing
        render()
        play("Morse")

        var caption = String(format: "%.0f seconds  ·  peak %@", duration, levelText())
        if reason == .limit {
            caption = "Stopped at the \(Int(Prefs.maximumRecordingSeconds / 60) ) minute limit  ·  " + caption
        }
        if dropped > 0 {
            caption += "  ·  \(dropped) samples dropped"
        }
        HUD.shared.show("Transcribing…", caption: caption)

        let language = Prefs.language
        let prompt = Prefs.useVocabulary ? Vocabulary.prompt() : nil
        let job = TranscriptionJob()
        self.job = job

        workQueue.async { [weak self] in
            defer { try? FileManager.default.removeItem(at: url) }
            do {
                let text = try job.run(audio: url, language: language, prompt: prompt)
                DispatchQueue.main.async { self?.finish(with: text) }
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.job = nil
                    self.state = .idle
                    self.render()
                    if case TranscriberError.cancelled = error {
                        self.play("Basso")
                        HUD.shared.show("Cancelled", caption: nil)
                        HUD.shared.dismiss(after: 2)
                    } else {
                        self.report(error)
                    }
                }
            }
        }
    }

    private func finish(with text: String) {
        job = nil
        state = .idle
        render()

        guard !text.isEmpty else {
            play("Basso")
            statusItem.button?.toolTip = "Nothing was heard (peak \(levelText()))"
            HUD.shared.show("Nothing was heard",
                            caption: "Peak \(levelText()). Check Input and Channel, or run Test Microphone.")
            HUD.shared.dismiss(after: 5)
            return
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        var history = Prefs.history
        history.insert(text, at: 0)
        Prefs.history = history

        play("Pop")

        let pasted = Prefs.autoPaste && paste()
        let caption: String
        if pasted {
            caption = "Pasted  ·  peak \(levelText())"
        } else if Prefs.autoPaste {
            caption = "Copied. Press ⌘V — auto-paste needs Accessibility permission."
        } else {
            caption = "Copied to the clipboard. Press ⌘V."
        }
        HUD.shared.show(text, caption: caption)
        HUD.shared.dismiss(after: 5)
    }

    private func hudHint() -> String {
        "\(Prefs.hotkeyDescription) to transcribe  ·  \(Prefs.cancelHotkeyDescription) to discard"
    }

    /// Synthesises command-V into whatever app is frontmost. Needs Accessibility.
    /// - Returns: true if the keystroke was posted.
    @discardableResult
    private func paste() -> Bool {
        guard AXIsProcessTrusted() else {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            return false
        }
        let source = CGEventSource(stateID: .combinedSessionState)
        let v = CGKeyCode(kVK_ANSI_V)
        let down = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
        return true
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let toggleTitle: String
        switch state {
        case .idle: toggleTitle = "Start Dictation"
        case .recording: toggleTitle = "Stop and Transcribe"
        case .transcribing: toggleTitle = "Transcribing…"
        }
        let toggleItem = NSMenuItem(title: toggleTitle, action: #selector(menuToggle), keyEquivalent: "")
        toggleItem.target = self
        toggleItem.isEnabled = state != .transcribing
        menu.addItem(toggleItem)

        if state != .idle {
            let cancelTitle = state == .recording ? "Discard This Take" : "Cancel Transcription"
            let cancelItem = NSMenuItem(title: cancelTitle, action: #selector(menuCancel), keyEquivalent: "")
            cancelItem.target = self
            menu.addItem(cancelItem)
        }

        let hint = NSMenuItem(title: "\(Prefs.hotkeyDescription) dictate  ·  \(Prefs.cancelHotkeyDescription) discard",
                              action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)

        let test = NSMenuItem(title: "Test Microphone…", action: #selector(testMicrophone), keyEquivalent: "")
        test.target = self
        test.isEnabled = state == .idle
        menu.addItem(test)

        menu.addItem(.separator())

        let history = Prefs.history
        if let last = history.first {
            let copy = NSMenuItem(title: "Copy Last: " + preview(last), action: #selector(copyLast), keyEquivalent: "")
            copy.target = self
            menu.addItem(copy)

            if history.count > 1 {
                let recent = NSMenuItem(title: "Recent", action: nil, keyEquivalent: "")
                let submenu = NSMenu()
                for (index, entry) in history.enumerated().dropFirst() {
                    let item = NSMenuItem(title: preview(entry), action: #selector(copyHistory(_:)), keyEquivalent: "")
                    item.target = self
                    item.tag = index
                    submenu.addItem(item)
                }
                submenu.addItem(.separator())
                let clear = NSMenuItem(title: "Clear History", action: #selector(clearHistory), keyEquivalent: "")
                clear.target = self
                submenu.addItem(clear)
                recent.submenu = submenu
                menu.addItem(recent)
            }
            menu.addItem(.separator())
        }

        menu.addItem(deviceMenuItem())
        menu.addItem(channelMenuItem())

        let level = NSMenuItem(title: "Last peak: " + levelText(), action: nil, keyEquivalent: "")
        level.isEnabled = false
        menu.addItem(level)

        menu.addItem(.separator())

        let vocabulary = NSMenuItem(title: "Bias Toward Vocabulary", action: #selector(toggleVocabulary), keyEquivalent: "")
        vocabulary.target = self
        vocabulary.state = Prefs.useVocabulary ? .on : .off
        menu.addItem(vocabulary)

        let editVocabulary = NSMenuItem(title: "Edit Vocabulary…", action: #selector(editVocabulary), keyEquivalent: "")
        editVocabulary.target = self
        menu.addItem(editVocabulary)

        let autoPaste = NSMenuItem(title: "Paste Into Front App", action: #selector(toggleAutoPaste), keyEquivalent: "")
        autoPaste.target = self
        autoPaste.state = Prefs.autoPaste ? .on : .off
        menu.addItem(autoPaste)

        let sounds = NSMenuItem(title: "Play Sounds", action: #selector(toggleSounds), keyEquivalent: "")
        sounds.target = self
        sounds.state = Prefs.playSounds ? .on : .off
        menu.addItem(sounds)

        menu.addItem(languageMenuItem())

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit ARC Dictate", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func deviceMenuItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Input", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let current = selectedDevice()

        let system = NSMenuItem(title: "System Default", action: #selector(chooseDevice(_:)), keyEquivalent: "")
        system.target = self
        system.representedObject = ""
        system.state = Prefs.deviceUID == nil ? .on : .off
        submenu.addItem(system)
        submenu.addItem(.separator())

        for device in AudioDevices.inputs() {
            let item = NSMenuItem(title: "\(device.name)  (\(device.channelCount) ch)",
                                  action: #selector(chooseDevice(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = device.uid
            item.state = device.uid == current?.uid ? .on : .off
            submenu.addItem(item)
        }

        parent.submenu = submenu
        return parent
    }

    private func channelMenuItem() -> NSMenuItem {
        let count = selectedDevice()?.channelCount ?? 2
        let parent = NSMenuItem(title: "Channel", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for index in 0..<max(count, 1) {
            let item = NSMenuItem(title: "Channel \(index + 1)", action: #selector(chooseChannel(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = index == Prefs.channel ? .on : .off
            submenu.addItem(item)
        }
        if count > 2 {
            submenu.addItem(.separator())
            let note = NSMenuItem(title: "Multi-channel interface: pick the mic's channel", action: nil, keyEquivalent: "")
            note.isEnabled = false
            submenu.addItem(note)
        }
        parent.submenu = submenu
        return parent
    }

    private func languageMenuItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Language", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for (code, name) in [("en", "English"), ("auto", "Auto-detect")] {
            let item = NSMenuItem(title: name, action: #selector(chooseLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = code
            item.state = Prefs.language == code ? .on : .off
            submenu.addItem(item)
        }
        parent.submenu = submenu
        return parent
    }

    // MARK: - Menu actions

    @objc private func menuToggle() { toggle() }
    @objc private func menuCancel() { cancelCurrent() }

    @objc private func copyLast() {
        guard let text = Prefs.history.first else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func copyHistory(_ sender: NSMenuItem) {
        let history = Prefs.history
        guard sender.tag < history.count else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(history[sender.tag], forType: .string)
    }

    @objc private func clearHistory() { Prefs.history = [] }

    @objc private func chooseDevice(_ sender: NSMenuItem) {
        let uid = sender.representedObject as? String ?? ""
        Prefs.deviceUID = uid.isEmpty ? nil : uid
        Prefs.channel = 0
    }

    @objc private func chooseChannel(_ sender: NSMenuItem) { Prefs.channel = sender.tag }

    @objc private func chooseLanguage(_ sender: NSMenuItem) {
        Prefs.language = sender.representedObject as? String ?? "en"
    }

    @objc private func toggleAutoPaste() {
        Prefs.autoPaste.toggle()
        if Prefs.autoPaste, !AXIsProcessTrusted() {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
    }

    @objc private func toggleSounds() { Prefs.playSounds.toggle() }

    @objc private func toggleVocabulary() { Prefs.useVocabulary.toggle() }

    @objc private func editVocabulary() {
        Vocabulary.ensureSeeded()
        NSWorkspace.shared.open(Vocabulary.fileURL)
    }

    /// Records four seconds from the selected device and reports EVERY channel's level,
    /// so you can see which jack the mic is really in and whether the gain is up.
    @objc private func testMicrophone() {
        guard state == .idle else { NSSound.beep(); return }

        let device = selectedDevice()
        let name = device?.name ?? "System Default"
        let deviceID = device?.id ?? AudioDevices.defaultInput()

        let probe = LevelProbe()
        self.probe = probe
        state = .recording
        render()
        play("Tink")

        HUD.shared.show("Testing \(name) — say something", meterDB: -120, caption: "Listening for 4 seconds")

        probe.run(deviceID: deviceID, seconds: 4) { level in
            HUD.shared.show("Testing \(name) — say something", meterDB: level, caption: "Listening for 4 seconds")
        } completion: { [weak self] result in
            guard let self else { return }
            self.probe = nil
            self.state = .idle
            self.render()
            HUD.shared.dismiss()
            self.play("Pop")

            switch result {
            case .failure(let error):
                self.report(error)
            case .success(let levels):
                self.presentTestResult(levels, deviceName: name)
            }
        }
    }

    private func presentTestResult(_ levels: [ChannelLevel], deviceName: String) {
        let hottest = levels.max(by: { $0.peakDB < $1.peakDB })

        var lines = ["Device: \(deviceName)", ""]
        for level in levels {
            let marker = level.channel == Prefs.channel ? "▸" : " "
            let verdict: String
            switch level.peakDB {
            case ..<(-50): verdict = "silent"
            case ..<(-30): verdict = "very quiet"
            case ..<(-6):  verdict = "good"
            default:       verdict = "hot, back the gain off"
            }
            lines.append(String(format: "%@ Channel %d   peak %6.1f dBFS   rms %6.1f dBFS   %@",
                                marker, level.channel + 1, level.peakDB, level.rmsDB, verdict))
        }

        lines.append("")
        if let hottest, hottest.peakDB > -50 {
            if hottest.channel == Prefs.channel {
                lines.append("Channel \(Prefs.channel + 1) is selected and is the loudest. That is correct.")
            } else {
                lines.append("Channel \(hottest.channel + 1) is the loudest, but Channel \(Prefs.channel + 1) is selected.")
            }
        } else {
            lines.append("Nothing heard on any channel. Check the mic cable, phantom power, and the gain knob.")
        }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Microphone Test"
        alert.informativeText = lines.joined(separator: "\n")
        alert.alertStyle = .informational

        if let hottest, hottest.peakDB > -50, hottest.channel != Prefs.channel {
            alert.addButton(withTitle: "Use Channel \(hottest.channel + 1)")
            alert.addButton(withTitle: "Keep Channel \(Prefs.channel + 1)")
            if alert.runModal() == .alertFirstButtonReturn {
                Prefs.channel = hottest.channel
            }
        } else {
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    // MARK: - Helpers

    private func selectedDevice() -> InputDevice? {
        guard let uid = Prefs.deviceUID else { return nil }
        return AudioDevices.device(withUID: uid)
    }

    private func levelText() -> String {
        lastPeakDB <= -119 ? "—" : String(format: "%.0f dBFS", lastPeakDB)
    }

    private func preview(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count <= 48 ? flat : String(flat.prefix(48)) + "…"
    }

    private func play(_ name: String) {
        guard Prefs.playSounds else { return }
        NSSound(named: name)?.play()
    }

    private func report(_ error: Error) {
        play("Basso")
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "ARC Dictate"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }

    private func showMicrophoneDenied() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Microphone access is off"
        alert.informativeText = "Turn ARC Dictate on in System Settings › Privacy & Security › Microphone."
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }
}

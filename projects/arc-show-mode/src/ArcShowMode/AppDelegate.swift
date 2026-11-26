import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let show = ShowMode()

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu.delegate = self
        statusItem.menu = menu

        show.onChange = { [weak self] in self?.render() }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        Log.info("launch ARC Show Mode \(version), log at \(Log.fileURL.path)")
        seedLoginItemOnce()
        show.resumeIfNeeded()
        render()
        DispatchQueue.global(qos: .utility).async {
            let ok = Focus.installed()
            if !ok { Log.warn("Do Not Disturb shortcuts are not installed on this Mac") }
            DispatchQueue.main.async { self.render() }
        }

        if CommandLine.arguments.contains("--on") { show.engage() }
        if CommandLine.arguments.contains("--off") { show.release() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        show.releaseForQuit()
    }

    /// arcshowmode://on, arcshowmode://off, arcshowmode://toggle
    /// From a terminal or over ssh: open -g arcshowmode://on
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "arcshowmode" {
            Log.info("url \(url.absoluteString)")
            switch url.host?.lowercased() {
            case "on": show.engage()
            case "off": show.release()
            case "toggle": show.isEngaged ? show.release() : show.engage()
            default: NSSound.beep()
            }
        }
    }

    // MARK: - Status item

    /// The masks are the identity in every state ("I liked the masks", 2026-10-09).
    /// State is the fill and the tint: outline = off, filled red = engaged, filled red with
    /// "!" = engaged with a failed step, outline orange = Do Not Disturb not set up yet.
    private func render() {
        guard let button = statusItem.button else { return }
        let bold = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .bold)
        if show.isEngaged {
            let degraded = show.checks.contains { !$0.ok } || Focus.installedCached == false
            button.image = Self.masks("theatermasks.fill", tint: .systemRed)
            button.contentTintColor = nil
            button.attributedTitle = NSAttributedString(string: degraded ? " !" : "",
                                                        attributes: [.foregroundColor: NSColor.systemRed, .font: bold])
            button.toolTip = degraded ? "Show Mode ON, with a problem: open the menu" : "Show Mode ON"
        } else if Focus.installedCached == false {
            // Not ready for a show: say so where the operator will see it before doors.
            button.image = Self.masks("theatermasks", tint: .systemOrange)
            button.contentTintColor = nil
            button.attributedTitle = NSAttributedString(string: " ?",
                                                        attributes: [.foregroundColor: NSColor.systemOrange, .font: bold])
            button.toolTip = "ARC Show Mode: Do Not Disturb is not set up on this Mac"
        } else {
            button.image = NSImage(systemSymbolName: "theatermasks", accessibilityDescription: "ARC Show Mode")
            button.image?.isTemplate = true
            button.contentTintColor = nil
            button.attributedTitle = NSAttributedString(string: "")
            button.toolTip = "ARC Show Mode: off"
        }
    }

    /// The menu bar ignores contentTintColor on a template image (macOS 26 rendered the
    /// red masks black), so a coloured state carries its colour in the symbol itself.
    private static func masks(_ name: String, tint: NSColor) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: NSFont.systemFontSize + 2, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [tint]))
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "ARC Show Mode")?.withSymbolConfiguration(config)
        image?.isTemplate = false
        return image
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let header: String
        if let session = show.session {
            header = "Show Mode ON since \(session.startedAt.formatted(date: .omitted, time: .shortened))"
        } else {
            header = "Show Mode OFF"
        }
        menu.addItem(disabled(header))

        let toggle = NSMenuItem(title: show.isEngaged ? "Release Show Mode" : "Engage Show Mode",
                                action: #selector(toggleShow), keyEquivalent: "")
        toggle.target = self
        toggle.isEnabled = !show.busy
        menu.addItem(toggle)

        if !show.checks.isEmpty {
            menu.addItem(.separator())
            for check in show.checks {
                let item = disabled(check.text)
                item.image = NSImage(systemSymbolName: check.ok ? "checkmark.circle" : "exclamationmark.triangle.fill",
                                     accessibilityDescription: nil)
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        if Focus.installedCached == false {
            let warn = disabled("Do Not Disturb NOT set up on this Mac")
            warn.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
            menu.addItem(warn)
        }
        menu.addItem(action("Set Up Do Not Disturb…", #selector(setUpFocus)))
        menu.addItem(action("Test Do Not Disturb", #selector(testFocus)))
        menu.addItem(closeListSubmenu())

        let login = action("Launch at Login", #selector(toggleLoginItem))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(action("Open Log", #selector(openLog)))

        menu.addItem(.separator())
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        menu.addItem(disabled("ARC Show Mode \(version)"))
        menu.addItem(action(show.isEngaged ? "Quit (releases Show Mode)" : "Quit", #selector(quit)))
    }

    private func closeListSubmenu() -> NSMenuItem {
        let parent = NSMenuItem(title: "Apps It Closes", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let keep = Set(QuitPolicy.userKeep)
        let sections: [(String, [String])] = [
            ("Force-quit (sync clients)", QuitPolicy.syncClients),
            ("Quit", QuitPolicy.messaging),
            ("Added on this Mac", QuitPolicy.userExtra),
        ]
        for (title, ids) in sections where !ids.isEmpty {
            sub.addItem(disabled(title))
            for id in ids where !keep.contains(id) {
                sub.addItem(disabled("    " + ShowMode.displayName(id)))
            }
        }
        if !keep.isEmpty {
            sub.addItem(disabled("Exempt on this Mac"))
            keep.sorted().forEach { sub.addItem(disabled("    " + ShowMode.displayName($0))) }
        }
        parent.submenu = sub
        return parent
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        return item
    }

    // MARK: - Actions

    @objc private func toggleShow() {
        show.isEngaged ? show.release() : show.engage()
    }

    @objc private func setUpFocus() {
        if Focus.installed() {
            inform("Do Not Disturb is already set up",
                   "Both shortcuts are installed. Use Test Do Not Disturb to check it switches.")
            return
        }
        inform("Add both shortcuts",
               "Shortcuts will open twice. Click Add Shortcut each time, then come back and choose Test Do Not Disturb.\n\nAlso check System Settings > Focus > Do Not Disturb: allow no people, allow no apps, and turn Time Sensitive notifications off, or those still get through.")
        Focus.install()
    }

    @objc private func openLog() {
        NSWorkspace.shared.open(Log.fileURL)
    }

    @objc private func testFocus() {
        DispatchQueue.global(qos: .userInitiated).async {
            Focus.installed()
            let on = Focus.set(true)
            Thread.sleep(forTimeInterval: 3)
            let off = on.ok ? Focus.set(false) : on
            DispatchQueue.main.async {
                self.render()
                if on.ok && off.ok {
                    self.inform("Do Not Disturb works", "It switched on for three seconds and back off.")
                } else {
                    self.inform("Do Not Disturb did not switch", (on.ok ? off : on).message)
                }
            }
        }
    }

    /// Fleet Macs are meant to run this from login. Register once; after that the
    /// menu checkbox is the operator's choice and is never overridden.
    private func seedLoginItemOnce() {
        let key = "loginItemSeeded"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        try? SMAppService.mainApp.register()
        UserDefaults.standard.set(true, forKey: key)
    }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            inform("Launch at Login did not change", error.localizedDescription)
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func inform(_ title: String, _ text: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }
}

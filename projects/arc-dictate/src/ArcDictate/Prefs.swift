import Carbon.HIToolbox
import Foundation

/// Everything the app remembers between launches.
enum Prefs {

    private static let defaults = UserDefaults.standard

    private enum Key {
        static let deviceUID = "inputDeviceUID"
        static let channel = "inputChannel"
        static let language = "language"
        static let autoPaste = "autoPaste"
        static let playSounds = "playSounds"
        static let history = "history"
        static let useVocabulary = "useVocabulary"
    }

    static var deviceUID: String? {
        get { defaults.string(forKey: Key.deviceUID) }
        set { defaults.set(newValue, forKey: Key.deviceUID) }
    }

    /// Zero-based. Channel 1 on the front of the interface is index 0.
    static var channel: Int {
        get { defaults.integer(forKey: Key.channel) }
        set { defaults.set(newValue, forKey: Key.channel) }
    }

    static var language: String {
        get { defaults.string(forKey: Key.language) ?? "en" }
        set { defaults.set(newValue, forKey: Key.language) }
    }

    /// On by default: dictation that only reaches the clipboard is too easy to lose.
    static var autoPaste: Bool {
        get { defaults.object(forKey: Key.autoPaste) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.autoPaste) }
    }

    static var playSounds: Bool {
        get { defaults.object(forKey: Key.playSounds) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.playSounds) }
    }

    /// Feed the vocabulary list to whisper as an initial prompt.
    static var useVocabulary: Bool {
        get { defaults.object(forKey: Key.useVocabulary) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.useVocabulary) }
    }

    static var history: [String] {
        get { defaults.stringArray(forKey: Key.history) ?? [] }
        set { defaults.set(Array(newValue.prefix(10)), forKey: Key.history) }
    }

    /// Fixed for now: control-option-D to dictate, control-option-escape to abandon a take.
    static let hotkeyCode = UInt32(kVK_ANSI_D)
    static let hotkeyModifiers = UInt32(controlKey | optionKey)
    static let hotkeyDescription = "⌃⌥D"

    static let cancelHotkeyCode = UInt32(kVK_Escape)
    static let cancelHotkeyModifiers = UInt32(controlKey | optionKey)
    static let cancelHotkeyDescription = "⌃⌥⎋"

    /// A take that runs this long stops itself, so a missed keypress cannot record all day.
    static let maximumRecordingSeconds: TimeInterval = 600
}

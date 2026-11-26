import Carbon.HIToolbox
import Foundation

/// A system-wide hotkey. Carbon's RegisterEventHotKey is used deliberately: unlike a
/// CGEvent tap it needs no Accessibility permission, so the app works the moment it launches.
final class Hotkey {

    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void

    private static var registry: [UInt32: Hotkey] = [:]
    private static var nextID: UInt32 = 1

    private let id: UInt32

    /// - Parameters:
    ///   - keyCode: a `kVK_` virtual key code.
    ///   - modifiers: Carbon modifier mask, e.g. `controlKey | optionKey`.
    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.action = action
        self.id = Hotkey.nextID
        Hotkey.nextID += 1

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))

        let callback: EventHandlerUPP = { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event,
                              EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID),
                              nil,
                              MemoryLayout<EventHotKeyID>.size,
                              nil,
                              &hotKeyID)
            Hotkey.registry[hotKeyID.id]?.action()
            return noErr
        }

        guard InstallEventHandler(GetApplicationEventTarget(), callback, 1, &eventType, nil, &handler) == noErr else {
            return nil
        }

        let hotKeyID = EventHotKeyID(signature: OSType(0x41524344) /* 'ARCD' */, id: id)
        guard RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref) == noErr else {
            if let handler { RemoveEventHandler(handler) }
            return nil
        }

        Hotkey.registry[id] = self
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
        Hotkey.registry[id] = nil
    }
}

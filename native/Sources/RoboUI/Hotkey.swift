// The push-to-talk key: Ctrl+Q works in every app, and tells key down from key up.
// Carbon's RegisterEventHotKey, not an NSEvent monitor: it needs no Accessibility or Input Monitoring
// permission, and sends one event down and one up (no auto-repeat while held).
import Carbon.HIToolbox

final class Hotkey {
    var onDown: () -> Void = {}, onUp: () -> Void = {}  // the main thread
    private var key: EventHotKeyRef?, handler: EventHandlerRef?

    /// Claim Ctrl+Q; false when the system refuses (robo then wakes by name again). Another app's own
    /// Ctrl+Q hotkey is not noticed: a probe from a second process was accepted (2026-10-16).
    func register(keyCode: Int = kVK_ANSI_Q, modifiers: Int = controlKey) -> Bool {
        var kinds = [kEventHotKeyPressed, kEventHotKeyReleased].map {
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32($0))
        }
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, me in
            let hotkey = Unmanaged<Hotkey>.fromOpaque(me!).takeUnretainedValue()
            if GetEventKind(event) == UInt32(kEventHotKeyPressed) { hotkey.onDown() } else { hotkey.onUp() }
            return noErr
        }, kinds.count, &kinds, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard installed == noErr else { return false }
        let id = EventHotKeyID(signature: 0x726F_626F, id: 1)  // 'robo'
        return RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &key) == noErr
    }

    deinit {
        if let key { UnregisterEventHotKey(key) }
        if let handler { RemoveEventHandler(handler) }
    }
}

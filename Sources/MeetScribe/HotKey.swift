import Carbon.HIToolbox
import Foundation

/// Global ⌥⇧R hotkey via Carbon RegisterEventHotKey  -  no dependencies,
/// no Accessibility permission needed. Fixed combo in v1.
final class HotKey {
    static let comboDescription = "⌥⇧R"
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let onPress: () -> Void

    init(onPress: @escaping () -> Void) {
        self.onPress = onPress
    }

    enum RegistrationError: Error, LocalizedError {
        case eventHandler(OSStatus)
        case hotKey(OSStatus)

        var errorDescription: String? {
            switch self {
            case .eventHandler(let status): "Could not install hotkey handler (OSStatus \(status))"
            case .hotKey(let status): "The global shortcut is unavailable (OSStatus \(status))"
            }
        }
    }

    func register() throws {
        guard ref == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let handlerStatus = InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue().onPress()
            return noErr
        }, 1, &eventType, selfPtr, &handler)
        guard handlerStatus == noErr else {
            handler = nil
            throw RegistrationError.eventHandler(handlerStatus)
        }
        let hotKeyID = EventHotKeyID(signature: OSType(0x4D53_4352), id: 1) // 'MSCR'
        let hotKeyStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_R), UInt32(optionKey | shiftKey),
            hotKeyID, GetApplicationEventTarget(), 0, &ref)
        guard hotKeyStatus == noErr else {
            if let handler { RemoveEventHandler(handler); self.handler = nil }
            ref = nil
            throw RegistrationError.hotKey(hotKeyStatus)
        }
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref); self.ref = nil }
        if let handler { RemoveEventHandler(handler); self.handler = nil }
    }

    deinit { unregister() }
}

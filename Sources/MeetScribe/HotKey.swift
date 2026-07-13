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

    func register() {
        guard ref == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue().onPress()
            return noErr
        }, 1, &eventType, selfPtr, &handler)
        let hotKeyID = EventHotKeyID(signature: OSType(0x4D53_4352), id: 1) // 'MSCR'
        RegisterEventHotKey(UInt32(kVK_ANSI_R), UInt32(optionKey | shiftKey),
                            hotKeyID, GetApplicationEventTarget(), 0, &ref)
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref); self.ref = nil }
        if let handler { RemoveEventHandler(handler); self.handler = nil }
    }
}

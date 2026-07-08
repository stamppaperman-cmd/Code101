import Carbon.HIToolbox
import Foundation

/// Registers a system-wide hotkey (default ⌥⌘L) via Carbon's
/// RegisterEventHotKey, which needs no accessibility permission and fires
/// even while the app is in the background.
final class HotKeyManager {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private let onPress: () -> Void

    init(
        keyCode: UInt32 = UInt32(kVK_ANSI_L),
        modifiers: UInt32 = UInt32(optionKey | cmdKey),
        onPress: @escaping () -> Void
    ) {
        self.onPress = onPress

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return noErr }
                Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue().onPress()
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )

        let hotKeyID = EventHotKeyID(signature: OSType(0x4F56_4C4E), id: 1) // 'OVLN'
        RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    deinit {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
    }
}

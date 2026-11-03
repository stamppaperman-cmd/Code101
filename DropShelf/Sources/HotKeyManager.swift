import Carbon.HIToolbox
import Foundation

/// Registers a system-wide hotkey (default ⌥⌘L) via Carbon's
/// RegisterEventHotKey, which needs no accessibility permission and fires
/// even while the app is in the background.
final class HotKeyManager {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private let onPress: () -> Void
    private let id: UInt32

    init(
        keyCode: UInt32 = UInt32(kVK_ANSI_L),
        modifiers: UInt32 = UInt32(optionKey | cmdKey),
        id: UInt32 = 1,
        onPress: @escaping () -> Void
    ) {
        self.onPress = onPress
        self.id = id

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            // Each instance stacks a handler on the app target. Carbon calls
            // the newest first and stops at the first one that returns noErr,
            // so a press that isn't ours must go back as eventNotHandledErr —
            // returning noErr here swallowed every other hotkey and left only
            // the last one registered working.
            { _, event, userData in
                guard let userData, let event else { return OSStatus(eventNotHandledErr) }
                var pressed = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &pressed
                )
                let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                guard status == noErr, pressed.signature == HotKeyManager.signature, pressed.id == manager.id else {
                    return OSStatus(eventNotHandledErr)
                }
                manager.onPress()
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )

        let hotKeyID = EventHotKeyID(signature: HotKeyManager.signature, id: id)
        RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    static let signature = OSType(0x4452_5348) // 'DRSH'

    deinit {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
    }
}

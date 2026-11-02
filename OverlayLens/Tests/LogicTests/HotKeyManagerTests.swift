import Carbon.HIToolbox
import Testing
@testable import StampLabLogic

@Suite("คีย์ลัดทั้งระบบ (HotKeyManager)", .serialized)
@MainActor
struct HotKeyManagerTests {
    /// Keys nobody uses (⌃⌥⌘⇧ F17–F19) and ids clear of the app's 1–7.
    private let mods = UInt32(controlKey | optionKey | cmdKey | shiftKey)

    /// Hands a hotkey press to the app's Carbon handlers the way the system
    /// does, with no real key and no permission needed.
    private func press(id: UInt32) -> OSStatus {
        var event: EventRef?
        CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed),
                    GetCurrentEventTime(), EventAttributes(kEventAttributeNone), &event)
        guard let event else { return OSStatus(eventInternalErr) }
        defer { ReleaseEvent(event) }
        var hotKey = EventHotKeyID(signature: HotKeyManager.signature, id: id)
        SetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                          MemoryLayout<EventHotKeyID>.size, &hotKey)
        return SendEventToEventTarget(event, GetApplicationEventTarget())
    }

    @Test("ทุกปุ่มกดติด ไม่ใช่แค่ปุ่มที่ลงทะเบียนทีหลังสุด")
    func everyHotKeyFires() {
        var fired: [UInt32] = []
        let managers = [(kVK_F17, 901), (kVK_F18, 902), (kVK_F19, 903)].map { key, id in
            HotKeyManager(keyCode: UInt32(key), modifiers: mods, id: UInt32(id)) { fired.append(UInt32(id)) }
        }
        for id: UInt32 in [901, 902, 903] {
            _ = press(id: id)
        }
        withExtendedLifetime(managers) {}
        #expect(fired == [901, 902, 903])
    }

    @Test("ปุ่มที่ไม่ใช่ของเราส่งต่อ ไม่ถูกกลืน")
    func foreignPressPassesOn() {
        var fired = false
        let manager = HotKeyManager(keyCode: UInt32(kVK_F17), modifiers: mods, id: 904) { fired = true }
        #expect(press(id: 999) == OSStatus(eventNotHandledErr))
        withExtendedLifetime(manager) {}
        #expect(!fired)
    }
}

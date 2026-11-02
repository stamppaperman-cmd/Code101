import Foundation
import Testing
@testable import StampLabLogic

@Suite("เวลาโควตารีเซ็ต (ทำต่ออัตโนมัติ)")
struct QuotaResetTests {
    private let bangkok: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Bangkok")!
        return calendar
    }()

    private func at(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    @Test("ข้อความจริงตอนโควตา 5 ชม. เต็ม → 01:30 ของคืนนี้")
    func sessionLimit() {
        let reset = QuotaReset.parse("You've hit your session limit · resets 1:30am (Asia/Bangkok)",
                                     now: at("2026-10-31T22:45:00+07:00"), calendar: bangkok)
        #expect(reset == at("2026-11-01T01:30:00+07:00"))
    }

    @Test("เวลาบ่ายในวันเดียวกัน")
    func sameDayPM() {
        let reset = QuotaReset.parse("5-hour limit reached ∙ resets 3pm",
                                     now: at("2026-10-31T10:00:00+07:00"), calendar: bangkok)
        #expect(reset == at("2026-10-31T15:00:00+07:00"))
    }

    @Test("ลิมิตรายสัปดาห์ระบุวัน → จันทร์หน้า 03:00")
    func weekly() {
        let reset = QuotaReset.parse("Weekly limit reached · resets Mon 3:00 AM",
                                     now: at("2026-10-31T22:45:00+07:00"), calendar: bangkok)
        #expect(reset == at("2026-11-02T03:00:00+07:00"))
    }

    @Test("12am คือเที่ยงคืน 12pm คือเที่ยงวัน")
    func twelve() {
        let now = at("2026-10-31T10:00:00+07:00")
        #expect(QuotaReset.parse("resets 12am", now: now, calendar: bangkok) == at("2026-11-01T00:00:00+07:00"))
        #expect(QuotaReset.parse("resets 12pm", now: now, calendar: bangkok) == at("2026-10-31T12:00:00+07:00"))
    }

    @Test("ข้อความที่ไม่มีเวลารีเซ็ต → nil")
    func noMatch() {
        #expect(QuotaReset.parse("API Error: Rate limit reached") == nil)
        #expect(QuotaReset.parse("resets 25:00") == nil)
    }

    @Test("ชื่อแชตล่าสุดจากท้าย transcript")
    func title() {
        let tail = """
        {"type":"user","message":"x"}
        {"type":"custom-title","customTitle":"ชื่อเก่า","sessionId":"a"}
        {"type":"assistant","message":"y"}
        {"type":"custom-title","customTitle":"ออกแบบ Finish Engine ใน StampLab","sessionId":"a"}
        """
        #expect(QuotaReset.sessionTitle(inTranscriptTail: tail) == "ออกแบบ Finish Engine ใน StampLab")
        #expect(QuotaReset.sessionTitle(inTranscriptTail: "{\"type\":\"user\"}") == nil)
    }
}

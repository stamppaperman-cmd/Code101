import Foundation
import Testing
@testable import StampLabLogic

private func json(_ s: String) -> Data { Data(s.utf8) }

@Suite("อ่านคำตอบจาก Google Translate")
struct OnlineTranslatorParseTests {
    @Test("gtx: รวมทุกท่อนคำแปล")
    func gtxJoinsSegments() throws {
        let data = json(#"[[["สวัสดี ","Hello ",null,null,10],["โลก","world",null,null,10]],null,"en"]"#)
        #expect(try OnlineTranslator.parseGtx(data) == "สวัสดี โลก")
    }

    @Test("gtx: คำตอบผิดรูปแบบต้องแจ้งพลาด ไม่ใช่ได้ข้อความว่าง")
    func gtxRejectsBadShapes() {
        #expect(throws: (any Error).self) { try OnlineTranslator.parseGtx(json(#"{"error":"blocked"}"#)) }
        #expect(throws: (any Error).self) { try OnlineTranslator.parseGtx(json("[[]]")) }
        #expect(throws: (any Error).self) { try OnlineTranslator.parseGtx(json("<html>429</html>")) }
    }

    @Test("ช่องทางสำรอง: รับได้ทั้งแบบข้อความ และแบบ [คำแปล, ภาษา]")
    func dictExtensionBothShapes() throws {
        #expect(try OnlineTranslator.parseDictExtension(json(#"["สวัสดี"]"#)) == "สวัสดี")
        #expect(try OnlineTranslator.parseDictExtension(json(#"[["สวัสดี","en"]]"#)) == "สวัสดี")
    }

    @Test("ช่องทางสำรอง: คำตอบว่างต้องแจ้งพลาด")
    func dictExtensionRejectsEmpty() {
        #expect(throws: (any Error).self) { try OnlineTranslator.parseDictExtension(json("[]")) }
        #expect(throws: (any Error).self) { try OnlineTranslator.parseDictExtension(json("{}")) }
    }
}

@Suite("แยกภาษาเพื่อเลือกทิศทางแปล")
struct LanguageDetectionTests {
    @Test func thai() { #expect(DetectedSourceLanguage.detect(for: "วันนี้อากาศดีมาก เราไปเดินเล่นกัน") == .thai) }
    @Test func chinese() { #expect(DetectedSourceLanguage.detect(for: "今天天气很好，我们去散步吧") == .chinese) }
    @Test func english() { #expect(DetectedSourceLanguage.detect(for: "Open the settings and turn on the switch") == .other) }
}

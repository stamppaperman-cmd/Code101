import CoreGraphics
import Testing
@testable import StampLabLogic

/// One-piece row in view points (bottom-left origin), 20pt tall by default.
private func row(_ text: String, x: CGFloat = 0, y: CGFloat, width: CGFloat, height: CGFloat = 20) -> TextRow {
    let rect = CGRect(x: x, y: y, width: width, height: height)
    return TextRow(rect: rect, pieces: [TextPiece(rect: rect, text: text)])
}

@Suite("จัดบรรทัดก่อนส่งแปล")
struct TextLayoutTests {
    @Test("รายการในแถบข้างไม่ถูกรวมเป็นประโยคเดียว")
    func sidebarListKeepsLines() {
        let rows = [
            row("Home", y: 200, width: 60),
            row("Downloads", y: 172, width: 110),
            row("Settings", y: 144, width: 90),
        ]
        #expect(TextLayout.text(of: rows) == "Home\nDownloads\nSettings")
    }

    /// Thai has no capitals, so only the paragraph check keeps these apart.
    @Test("เมนูภาษาไทยไม่ถูกรวมเป็นคำเดียว")
    func thaiMenuKeepsLines() {
        let rows = [
            row("หน้าแรก", y: 200, width: 50),
            row("ดาวน์โหลดไฟล์ทั้งหมด", y: 172, width: 200),
            row("ตั้งค่า", y: 144, width: 60),
            row("ออกจากระบบ", y: 116, width: 90),
        ]
        #expect(TextLayout.text(of: rows) == "หน้าแรก\nดาวน์โหลดไฟล์ทั้งหมด\nตั้งค่า\nออกจากระบบ")
    }

    @Test("ย่อหน้าอังกฤษที่ตัดบรรทัด ต่อกลับเป็นประโยคเดียว")
    func englishParagraphJoins() {
        let rows = [
            row("The quick brown fox jumps over", y: 200, width: 400),
            row("the lazy dog and keeps running", y: 176, width: 398),
            row("into the forest.", y: 152, width: 150),
        ]
        #expect(TextLayout.text(of: rows) == "The quick brown fox jumps over the lazy dog and keeps running into the forest.")
    }

    @Test("ย่อหน้าไทยต่อกันโดยไม่แทรกช่องว่าง")
    func thaiParagraphJoinsWithoutSpaces() {
        let rows = [
            row("วันนี้อากาศดีมากเราจึงออกไป", y: 200, width: 400),
            row("เดินเล่นที่สวนสาธารณะใกล้บ้าน", y: 176, width: 400),
            row("กันทั้งครอบครัว", y: 152, width: 120),
        ]
        #expect(TextLayout.text(of: rows) == "วันนี้อากาศดีมากเราจึงออกไปเดินเล่นที่สวนสาธารณะใกล้บ้านกันทั้งครอบครัว")
    }

    @Test("หัวข้อย่อย (•) อยู่คนละบรรทัด")
    func bulletsStaySeparate() {
        let rows = [
            row("• First item that is quite long", y: 200, width: 400),
            row("• Second item that is also long", y: 176, width: 400),
            row("• Third", y: 152, width: 80),
        ]
        #expect(TextLayout.text(of: rows) == "• First item that is quite long\n• Second item that is also long\n• Third")
    }

    @Test("ช่องว่างใหญ่ระหว่างบรรทัด = ขึ้นย่อหน้าใหม่")
    func largeGapStartsParagraph() {
        let rows = [
            row("Title", y: 200, width: 100),
            row("Body text", y: 150, width: 120),
        ]
        #expect(TextLayout.text(of: rows) == "Title\n\nBody text")
    }

    @Test("ชิ้นข้อความบนบรรทัดเดียวกันถูกรวมเป็นแถว เรียงซ้ายไปขวา")
    func piecesOnOneLineFormOneRow() {
        let pieces = [
            TextPiece(rect: CGRect(x: 0, y: 70, width: 60, height: 20), text: "Next"),
            TextPiece(rect: CGRect(x: 55, y: 100, width: 80, height: 20), text: "การตั้งค่า"),
            TextPiece(rect: CGRect(x: 0, y: 100, width: 50, height: 20), text: "Open"),
        ]
        let rows = TextLayout.rows(from: pieces)
        #expect(rows.count == 2)
        #expect(rows.first?.pieces.map(\.text) == ["Open", "การตั้งค่า"])
        #expect(rows.last?.pieces.map(\.text) == ["Next"])
    }

    @Test("แถวที่ชิดกันเป็นกล่องเดียว แถวที่ห่างแยกกล่อง")
    func blocksSplitOnDistance() {
        let rows = [
            row("Line one", y: 200, width: 300),
            row("Line two", y: 176, width: 300),
            row("Far away", y: 100, width: 300),
        ]
        let blocks = TextLayout.blocks(from: rows, maxHeight: 1000)
        #expect(blocks.map { $0.rows.count } == [2, 1])
    }
}

import Foundation
import Testing
@testable import StampLabLogic

@Suite("ลากไฟล์เสียงมาวางเพื่อถอดเสียง")
struct MeetingImportTests {
    private let noon = Date(timeIntervalSince1970: 1_762_000_000)  // 2025-11-01 ~14:46 local

    @Test("รับไฟล์เสียงและวิดีโอ ไม่รับไฟล์อื่น")
    func supported() {
        #expect(MeetingImport.isSupported(URL(fileURLWithPath: "/a/b.m4a")))
        #expect(MeetingImport.isSupported(URL(fileURLWithPath: "/a/b.MP3")))
        #expect(MeetingImport.isSupported(URL(fileURLWithPath: "/a/call.mov")))
        #expect(!MeetingImport.isSupported(URL(fileURLWithPath: "/a/b.pdf")))
        #expect(!MeetingImport.isSupported(URL(fileURLWithPath: "/a/b")))
    }

    @Test("ไฟล์ m4a ไม่ต้องแปลง ไฟล์อื่นต้องแปลง")
    func transcode() {
        #expect(!MeetingImport.needsTranscode(URL(fileURLWithPath: "/a/b.m4a")))
        #expect(!MeetingImport.needsTranscode(URL(fileURLWithPath: "/a/b.M4A")))
        #expect(MeetingImport.needsTranscode(URL(fileURLWithPath: "/a/b.wav")))
    }

    @Test("ชื่อโฟลเดอร์ขึ้นต้นด้วยวันเวลาแบบที่ระบบอ่านออก แล้วตามด้วยชื่อไฟล์")
    func folderName() {
        let name = MeetingImport.folderName(for: URL(fileURLWithPath: "/d/Saowapha Institute.m4a"), date: noon)
        #expect(name.hasSuffix("_Saowapha Institute"))
        let prefix = String(name.prefix(15))
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd_HHmm"
        #expect(format.date(from: prefix) != nil)  // MeetingRecorderModel.session(at:) parses this
    }

    @Test("ชื่อไฟล์ที่มีอักขระต้องห้ามถูกล้างจนใช้เป็นชื่อโฟลเดอร์ได้")
    func sanitise() {
        #expect(!MeetingImport.folderName(for: URL(fileURLWithPath: "/d/a:b.m4a"), date: noon).contains(":"))
        #expect(MeetingImport.sanitise(".hidden") == "hidden")
        #expect(MeetingImport.sanitise("  ประชุม ทีม  ") == "ประชุม ทีม")
        #expect(MeetingImport.sanitise(String(repeating: "ก", count: 200)).count == 60)
    }

    @Test("ไฟล์ไม่มีชื่อ ยังได้โฟลเดอร์และหัวข้อที่อ่านออก")
    func emptyName() {
        let url = URL(fileURLWithPath: "/d/.m4a")
        #expect(MeetingImport.folderName(for: url, date: noon).hasSuffix("_ไฟล์เสียง"))
        #expect(MeetingImport.title(for: url, date: noon).hasPrefix("ไฟล์เสียง · "))
    }

    @Test("หัวข้อคือชื่อไฟล์ ตามด้วยเวลาที่นำเข้า")
    func title() {
        let t = MeetingImport.title(for: URL(fileURLWithPath: "/d/ประชุมทีม.mp3"), date: noon)
        #expect(t.hasPrefix("ประชุมทีม · "))
    }

    @Test("วางไฟล์เดิมซ้ำ ไม่ทับโฟลเดอร์เก่า")
    func unique() {
        let root = URL(fileURLWithPath: "/root")
        let taken: Set<String> = ["/root/a", "/root/a-2"]
        let url = MeetingImport.uniqueFolder(in: root, named: "a") { taken.contains($0.path) }
        #expect(url.lastPathComponent == "a-3")
    }

    @Test("วางไฟล์ที่เปิดไม่ได้ ได้ข้อความบอกว่ารองรับอะไรบ้าง")
    func rejection() {
        let pdf = URL(fileURLWithPath: "/d/สรุป.pdf")
        let message = MeetingImport.rejectionMessage(for: [pdf])
        #expect(message?.contains("สรุป.pdf") == true)
        #expect(message?.contains("m4a") == true)
        #expect(MeetingImport.rejectionMessage(for: []) != nil)
        // มีไฟล์ที่ใช้ได้ปนมา = ไม่ต้องเตือน
        #expect(MeetingImport.rejectionMessage(for: [pdf, URL(fileURLWithPath: "/d/a.wav")]) == nil)
    }
}

import Foundation
import Testing
@testable import StampLabLogic

@Suite("Finish Engine: กล่องโปรเจกต์")
struct FinishEngineLogicTests {
    private let now = Date(timeIntervalSince1970: 1_793_500_000)

    private func task(_ title: String, _ project: String, _ status: String, tier: String = "MVP",
                      edited minutesAgo: Double = 0, holder: String? = nil) -> FinishEngineTask {
        FinishEngineTask(id: UUID().uuidString, task: title, project: project, status: status,
                         tier: tier, weight: 1, blocker: "", holder: holder,
                         lastEdited: now.addingTimeInterval(-minutesAgo * 60))
    }

    @Test("ขั้นต่อไป: Doing ก่อน Todo, MVP ก่อน LATER, แก้ล่าสุดก่อน")
    func workOrder() {
        let tasks = [
            task("todo mvp", "A", "Todo", edited: 1),
            task("doing later", "A", "Doing", tier: "LATER", edited: 1),
            task("doing mvp old", "A", "Doing", edited: 60),
            task("doing mvp new", "A", "Doing", edited: 5),
            task("todo later", "A", "Todo", tier: "LATER"),
            task("done", "A", "Done"),
            task("cut", "A", "Cut"),
        ]
        let p = FinishEngineBoard.project(named: "A", tasks: tasks)
        #expect(p.remaining.map(\.task) == ["doing mvp new", "doing mvp old", "doing later", "todo mvp", "todo later"])
        #expect(p.next == "doing mvp new")
    }

    @Test("ความคืบหน้านับงาน MVP ถ้ามี ไม่งั้นนับทุกงานที่ไม่ถูก Cut")
    func progressCounts() {
        let mixed = [task("a", "A", "Done"), task("b", "A", "Doing"),
                     task("c", "A", "Done", tier: "LATER"), task("d", "A", "Cut")]
        let a = FinishEngineBoard.project(named: "A", tasks: mixed)
        #expect(a.doneCount == 1 && a.totalCount == 2)

        let laterOnly = [task("a", "B", "Done", tier: "LATER"), task("b", "B", "Todo", tier: "LATER"),
                         task("c", "B", "Cut", tier: "LATER")]
        let b = FinishEngineBoard.project(named: "B", tasks: laterOnly)
        #expect(b.doneCount == 1 && b.totalCount == 2)
    }

    @Test("นิ่งเกิน 7 วันเมื่อยังมีงานเปิด · โปรเจกต์ที่ครบแล้วไม่นับว่านิ่ง")
    func stale() {
        let old = 14 * 24 * 60.0
        let open = FinishEngineBoard.project(named: "A", tasks: [task("x", "A", "Doing", edited: old)])
        #expect(open.staleDays(now: now) == 14)
        let fresh = FinishEngineBoard.project(named: "A", tasks: [task("x", "A", "Doing", edited: 6 * 24 * 60)])
        #expect(fresh.staleDays(now: now) == nil)
        let done = FinishEngineBoard.project(named: "A", tasks: [task("x", "A", "Done", edited: old)])
        #expect(done.staleDays(now: now) == nil)
        #expect(done.isComplete)
    }

    @Test("รายการ: ตัวเลือก Project ที่ยังไม่มีงานก็แสดง · มีงานเปิดเรียงตามล่าสุด ที่เหลือเรียงตามชื่อ")
    func listOrder() {
        let tasks = [
            task("x", "Slidegen", "Doing", edited: 30),
            task("y", "AI OS", "Doing", edited: 5),
            task("z", "Finish Engine", "Done", edited: 1),
        ]
        let projects = FinishEngineBoard.build(tasks: tasks, names: ["Finish Engine", "Sleep Well", "AI OS", "Slidegen"])
        #expect(projects.map(\.name) == ["AI OS", "Slidegen", "Finish Engine", "Sleep Well"])
        #expect(projects.last?.totalCount == 0 && projects.last?.remaining.isEmpty == true)
    }

    @Test("AI: เลือกไว้ > คนที่ถืองานถัดไป > ค่าเดิม")
    func aiChoice() {
        let tasks = [task("x", "Slidegen", "Doing", holder: "Codex")]
        #expect(FinishEngineBoard.project(named: "Slidegen", tasks: tasks).ai == .codex)
        #expect(FinishEngineBoard.project(named: "Slidegen", tasks: tasks, ai: .gemini).ai == .gemini)
        #expect(FinishEngineBoard.project(named: "New", tasks: []).ai == .claude)
    }

    @Test("OverlayLens แสดงเป็น StampLab แต่ค้นได้ทั้งสองชื่อ")
    func aliasAndSearch() {
        let projects = FinishEngineBoard.build(tasks: [], names: ["OverlayLens", "AI OS"])
        #expect(projects.first { $0.name == "OverlayLens" }?.displayName == "StampLab")
        #expect(FinishEngineBoard.filter(projects, query: "stamp").map(\.name) == ["OverlayLens"])
        #expect(FinishEngineBoard.filter(projects, query: "overlay").map(\.name) == ["OverlayLens"])
        #expect(FinishEngineBoard.filter(projects, query: "  ").count == 2)
        #expect(FinishEngineBoard.hasExactName(projects, "stamplab"))
        #expect(!FinishEngineBoard.hasExactName(projects, "stamp"))
    }

    @Test("ชื่อโปรเจกต์ใหม่: ห้ามว่าง ห้ามมีจุลภาค ห้ามซ้ำ")
    func newNameRules() {
        let projects = FinishEngineBoard.build(tasks: [], names: ["AI OS"])
        #expect(FinishEngineBoard.problem(withNewName: " ", existing: projects) != nil)
        #expect(FinishEngineBoard.problem(withNewName: "a,b", existing: projects) != nil)
        #expect(FinishEngineBoard.problem(withNewName: "ai os", existing: projects) == "มีโปรเจกต์ชื่อนี้แล้ว")
        #expect(FinishEngineBoard.problem(withNewName: "Sleep Well", existing: projects) == nil)
    }

    @Test("เดาโปรเจกต์: ชื่อที่ขึ้นก่อนชนะ เสมอกันเอาชื่อยาวกว่า")
    func guessFromTitle() {
        let projects = FinishEngineBoard.build(tasks: [], names: ["Finish Engine", "OverlayLens", "AI OS", "AI OS Mobile"])
        #expect(FinishEngineBoard.guess(in: "ออกแบบ Finish Engine ใน StampLab ใหม่", among: projects)?.name == "Finish Engine")
        #expect(FinishEngineBoard.guess(in: "แก้ปุ่มใน stamplab", among: projects)?.name == "OverlayLens")
        #expect(FinishEngineBoard.guess(in: "AI OS Mobile: Mac ไม่หลับ", among: projects)?.name == "AI OS Mobile")
        #expect(FinishEngineBoard.guess(in: "Claude", among: projects) == nil)
    }

    @Test("ชื่อแชตจากท้าย transcript: ใช้บรรทัด custom-title สุดท้าย ข้ามบรรทัดที่ถูกตัด")
    func transcriptTitle() {
        let lines = [
            #""type":"custom-title","customTitle":"cut off"}"#,
            #"{"type":"custom-title","customTitle":"ชื่อเก่า","sessionId":"s"}"#,
            #"{"type":"user","message":{"content":"พูดถึง \"type\":\"custom-title\" ในข้อความ"}}"#,
            #"{"type":"custom-title","customTitle":"ออกแบบ Finish Engine ใหม่","sessionId":"s"}"#,
            #"{"type":"assistant","message":{"content":"ok"}}"#,
        ]
        let data = Data(lines.joined(separator: "\n").utf8)
        #expect(FinishEngineBoard.customTitle(inTranscriptTail: data) == "ออกแบบ Finish Engine ใหม่")
        #expect(FinishEngineBoard.customTitle(inTranscriptTail: Data(lines[0].utf8)) == nil)
        #expect(FinishEngineBoard.customTitle(inTranscriptTail: Data(lines.prefix(3).joined(separator: "\n").utf8)) == "ชื่อเก่า")
    }

    @Test("สีจุดคงที่ทุกครั้งที่เปิดแอป และย่อข้อความไม่ตัดสระไทย")
    func helpers() {
        #expect(FinishEngineBoard.colorIndex(for: "Sleep Well", paletteCount: 8) == FinishEngineBoard.colorIndex(for: "Sleep Well", paletteCount: 8))
        #expect((0..<8).contains(FinishEngineBoard.colorIndex(for: "อะไรก็ได้", paletteCount: 8)))
        #expect(FinishEngineBoard.shortened("ออกแบบ Finish Engine ใน StampLab ใหม่ให้ใช้ง่าย", to: 12) == "ออกแบบ Fini…")
        #expect(FinishEngineBoard.shortened("สั้น", to: 30) == "สั้น")
    }

    @Test("คำสั่งวางแผน: บรรทัดแรกเป็นชื่อแชต ใส่ชื่อ Notion ที่ถูกต้อง และขั้นที่คิดไว้")
    func planningPrompt() {
        let empty = FinishEngineBoard.project(named: "OverlayLens", tasks: [], ai: .codex)
        let prompt = FinishEngineBoard.planningPrompt(for: empty, idea: "ร่าง Brand DNA")
        let lines = prompt.components(separatedBy: "\n")
        #expect(lines.first == "วางแผนขั้นแรก: StampLab")
        #expect(prompt.contains("Project = OverlayLens"))
        #expect(prompt.contains("ขั้นแรกที่คิดไว้: ร่าง Brand DNA"))
        #expect(prompt.contains("PENDING WRITES"))
        let done = FinishEngineBoard.project(named: "A", tasks: [task("x", "A", "Done")], ai: .claude)
        let next = FinishEngineBoard.planningPrompt(for: done)
        #expect(next.hasPrefix("วางแผนขั้นต่อไป: A"))
        #expect(!next.contains("PENDING WRITES"))
    }

    @Test("ทำต่อด้วย Claude: โฟลเดอร์ของโปรเจกต์ > _default > ไม่มี (กลับไปแชต)")
    func codeFolder() {
        let dirs: Set<String> = ["/Users/u/Claude", "/Users/u/Desktop/Code/OverlayLens"]
        func pick(_ project: String, _ map: [String: String]) -> String? {
            FinishEngineCodeLink.folder(for: project, map: map, home: "/Users/u",
                                        isDirectory: { dirs.contains($0) })
        }
        let map = ["OverlayLens": "~/Desktop/Code/OverlayLens", "_default": "~/Claude"]
        #expect(pick("OverlayLens", map) == "/Users/u/Desktop/Code/OverlayLens")
        #expect(pick("AI OS", map) == "/Users/u/Claude")
        #expect(pick("AI OS", ["OverlayLens": "/Users/u/Claude"]) == nil)
        // A folder that's gone or a relative path falls through, never opens.
        #expect(pick("Slidegen", ["Slidegen": "~/gone", "_default": "~/Claude"]) == "/Users/u/Claude")
        #expect(pick("Slidegen", ["Slidegen": "Claude"]) == nil)
    }

    @Test("ลิงก์ Claude Code: เข้ารหัสช่องว่าง ภาษาไทย & = ให้ครบ")
    func codeURL() {
        let url = FinishEngineCodeLink.url(folder: "/Users/u/งาน A&B=1")
        #expect(url?.scheme == "claude")
        #expect(url?.host == "code")
        #expect(url?.path == "/new")
        let items = URLComponents(url: url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.first { $0.name == "folder" }?.value == "/Users/u/งาน A&B=1")
        #expect(items.count == 2)
    }
}

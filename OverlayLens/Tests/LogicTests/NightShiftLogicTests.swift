import Foundation
import Testing
@testable import StampLabLogic

@Suite("กะดึก Finish Engine")
struct NightShiftLogicTests {
    private let bangkok: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Bangkok")!
        return calendar
    }()

    private func at(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    private var on: NightShiftConfig {
        var config = NightShiftConfig()
        config.enabled = true
        config.projects = ["AI OS"]
        return config
    }

    /// get_usage as the Claude desktop app returned it on 1 Nov 2026 09:20 (Pro plan).
    private func usage(fiveHour: Double = 61, fiveHourReset: String? = "2026-11-01T06:40:00.453Z",
                       weekly: Double = 66, weeklyReset: String? = "2026-11-01T20:00:00.453Z",
                       context: Double = 15) -> NightShiftUsage? {
        func reset(_ iso: String?) -> String { iso.map { "\"\($0)\"" } ?? "null" }
        let json = """
        {"plan":{"status":"ok","plan":"Pro","windows":[
          {"label":"5-hour limit","percentUsed":\(fiveHour),"resetsAt":\(reset(fiveHourReset)),"resetsIn":"4h 20m"},
          {"label":"Weekly · all models","percentUsed":\(weekly),"resetsAt":\(reset(weeklyReset)),"resetsIn":"17h 40m"}],
          "extraUsage":{"enabled":false,"percentUsed":0,"spent":"0.00","monthlyLimit":"10.00","currency":"USD"}},
         "context":{"session":"self","status":"ok","tokensUsed":145700,"contextWindow":1000000,"percentUsed":\(context)}}
        """
        return NightShiftUsage.parse(Data(json.utf8))
    }

    // MARK: get_usage

    @Test("อ่านคำตอบจริงของ get_usage ได้ครบ")
    func parsesRealAnswer() throws {
        let parsed = try #require(usage())
        #expect(parsed.fiveHour?.used == 61)
        let reset = try #require(parsed.fiveHour?.resetsAt)
        #expect(abs(reset.timeIntervalSince(at("2026-11-01T13:40:00+07:00"))) < 1)
        #expect(parsed.weekly.count == 1)
        #expect(parsed.weekly.first?.used == 66)
        #expect(parsed.contextUsed == 15)
    }

    @Test("แอปบอกว่าอ่านโควตาไม่ได้ → หยุด ไม่ทำแบบมองไม่เห็น")
    func unavailableStops() {
        let json = #"{"plan":{"status":"unavailable","note":"try later"},"context":{"status":"ok","percentUsed":3}}"#
        let parsed = NightShiftUsage.parse(Data(json.utf8))
        #expect(parsed == nil)
        let decision = NightShiftPlanner.decide(parsed, config: on, now: at("2026-11-01T23:00:00+07:00"), calendar: bangkok)
        #expect(!decision.go)
    }

    // MARK: Switch and projects

    @Test("สวิตช์ปิด → หยุดเสมอ ต่อให้โควตาเหลือเยอะ")
    func switchOffStops() {
        var config = on
        config.enabled = false
        let decision = NightShiftPlanner.decide(usage(fiveHour: 0, weekly: 10), config: config,
                                                now: at("2026-11-01T23:00:00+07:00"), calendar: bangkok)
        #expect(!decision.go)
        #expect(decision.reason.contains("ปิดอยู่"))
    }

    @Test("ยังไม่ติ๊กโปรเจกต์ → หยุด")
    func noProjectsStops() {
        var config = on
        config.projects = []
        let decision = NightShiftPlanner.decide(usage(), config: config,
                                                now: at("2026-11-01T23:00:00+07:00"), calendar: bangkok)
        #expect(!decision.go)
        #expect(decision.reason.contains("โปรเจกต์"))
    }

    @Test("ไฟล์ตั้งค่าเก่าที่ขาดบางช่อง → ใช้ค่าเริ่มต้น; ไม่มีไฟล์ = ปิด")
    func configDefaults() throws {
        let partial = #"{"enabled":true,"projects":["Slidegen"],"mode":"weird"}"#
        let config = try JSONDecoder().decode(NightShiftConfig.self, from: Data(partial.utf8))
        #expect(config.enabled)
        #expect(config.projects == ["Slidegen"])
        #expect(config.mode == .pace)
        #expect(config.fiveHourStop == 90)
        let missing = NightShiftConfig.load(from: URL(fileURLWithPath: "/nonexistent/nightshift.json"))
        #expect(!missing.enabled)
    }

    @Test("สวิตช์ในเมนูบันทึกแล้วอ่านกลับได้ค่าเดิม")
    func configRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nightshift-\(UUID().uuidString)/config.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var config = on
        config.mode = .final
        try config.save(to: url)
        #expect(NightShiftConfig.load(from: url) == config)
    }

    // MARK: Quota

    @Test("คืนวันอาทิตย์ 23:00 (รีเซ็ตรายสัปดาห์อีก 4 ชม.) สัปดาห์ 66% → ทำได้ถึง 97%")
    func sundayNightGoes() {
        let decision = NightShiftPlanner.decide(usage(fiveHour: 0, fiveHourReset: nil, weekly: 66),
                                                config: on, now: at("2026-11-01T23:00:00+07:00"), calendar: bangkok)
        #expect(decision.go)
        #expect(decision.reason.contains("66/97%"))
    }

    @Test("รอบ 5 ชม. ถึง 90% → หยุดก่อนชนลิมิต")
    func fiveHourCeilingStops() {
        let decision = NightShiftPlanner.decide(usage(fiveHour: 90, fiveHourReset: "2026-11-01T17:30:00Z"),
                                                config: on, now: at("2026-11-01T23:00:00+07:00"), calendar: bangkok)
        #expect(!decision.go)
        #expect(decision.reason.contains("5 ชม."))
    }

    @Test("ตี 4 ไม่มีรอบ 5 ชม. ค้าง → ถ้าเริ่มจะลากถึง 09:00 ทับตอนเช้า → หยุด")
    func morningGuardStops() {
        let decision = NightShiftPlanner.decide(usage(fiveHour: 0, fiveHourReset: nil, weekly: 10,
                                                      weeklyReset: "2026-11-08T20:00:00Z"),
                                                config: on, now: at("2026-11-02T04:00:00+07:00"), calendar: bangkok)
        #expect(!decision.go)
        #expect(decision.reason.contains("ตอนเช้า"))
    }

    @Test("ตี 1 เปิดรอบใหม่ได้ เพราะรีเซ็ต 06:00 ก่อนเช้า")
    func oneAMOpensWindow() {
        let decision = NightShiftPlanner.decide(usage(fiveHour: 0, fiveHourReset: nil, weekly: 66),
                                                config: on, now: at("2026-11-02T01:00:00+07:00"), calendar: bangkok)
        #expect(decision.go)
    }

    @Test("แผนรายวัน: คืนวันพฤหัส เส้นอยู่ที่ 40% (ไต่ไปถึง 65% ตอนเช้าวันอาทิตย์) ใช้ไป 60% → หยุด, 30% → ทำได้")
    func paceLine() {
        // Week: Mon 2 Nov 03:00 → Mon 9 Nov 03:00; the last day starts Sun 8 Nov 08:00 (149 h in).
        // Thu 5 Nov 23:00 is 92 h in → 65 × 92/149 = 40%.
        let now = at("2026-11-05T23:00:00+07:00")
        let over = NightShiftPlanner.decide(usage(fiveHour: 0, fiveHourReset: nil, weekly: 60,
                                                  weeklyReset: "2026-11-08T20:00:00Z"),
                                            config: on, now: now, calendar: bangkok)
        #expect(!over.go)
        #expect(over.reason.contains("40%"))
        let under = NightShiftPlanner.decide(usage(fiveHour: 0, fiveHourReset: nil, weekly: 30,
                                                   weeklyReset: "2026-11-08T20:00:00Z"),
                                             config: on, now: now, calendar: bangkok)
        #expect(under.go)
    }

    @Test("วันสุดท้ายเริ่ม 08:00 ของวันก่อนวันรีเซ็ต (รีเซ็ตจันทร์ 03:00 → อาทิตย์ 08:00)")
    func lastDayStarts() {
        let reset = at("2026-11-09T03:00:00+07:00")
        #expect(NightShiftPlanner.lastDayStart(reset: reset, config: on, calendar: bangkok) == at("2026-11-08T08:00:00+07:00"))
    }

    @Test("วันสุดท้าย: ตอบ ไม่ทำ → ใช้ได้ถึง 97% ทั้งวัน; ตอบ ทำงาน หรือยังไม่ตอบ → เก็บ 35% ไว้ให้ผู้ใช้")
    func lastDayAnswers() {
        let now = at("2026-11-01T10:00:00+07:00")   // Sunday; weekly resets Mon 2 Nov 03:00
        var free = on
        free.lastDay = "2026-11-01"
        free.lastDayAnswer = "free"
        #expect(NightShiftPlanner.decide(usage(fiveHour: 0, fiveHourReset: nil, weekly: 70),
                                         config: free, now: now, calendar: bangkok).go)
        var work = free
        work.lastDayAnswer = "work"
        let kept = NightShiftPlanner.decide(usage(fiveHour: 0, fiveHourReset: nil, weekly: 70),
                                            config: work, now: now, calendar: bangkok)
        #expect(!kept.go)
        #expect(kept.reason.contains("65%"))
        #expect(!NightShiftPlanner.decide(usage(fiveHour: 0, fiveHourReset: nil, weekly: 70),
                                          config: on, now: now, calendar: bangkok).go)
        // An answer for an older last day doesn't count.
        var stale = free
        stale.lastDay = "2026-10-25"
        #expect(!NightShiftPlanner.decide(usage(fiveHour: 0, fiveHourReset: nil, weekly: 70),
                                          config: stale, now: now, calendar: bangkok).go)
    }

    @Test("Routine กลางวันถูกบล็อก ยกเว้นวันสุดท้ายที่ผู้ใช้ตอบว่าไม่ทำ")
    func daytimeRuns() {
        let reset = at("2026-11-02T03:00:00+07:00")
        let wednesday = at("2026-10-28T15:00:00+07:00")
        #expect(NightShiftPlanner.daytimeBlocked(now: wednesday, config: on, weeklyReset: reset, calendar: bangkok))
        #expect(!NightShiftPlanner.daytimeBlocked(now: at("2026-10-28T23:00:00+07:00"), config: on,
                                                  weeklyReset: reset, calendar: bangkok))
        let sunday = at("2026-11-01T15:00:00+07:00")
        #expect(NightShiftPlanner.daytimeBlocked(now: sunday, config: on, weeklyReset: reset, calendar: bangkok))
        var free = on
        free.lastDay = "2026-11-01"
        free.lastDayAnswer = "free"
        #expect(!NightShiftPlanner.daytimeBlocked(now: sunday, config: free, weeklyReset: reset, calendar: bangkok))
        #expect(NightShiftPlanner.daytimeBlocked(now: sunday, config: free, weeklyReset: nil, calendar: bangkok))
    }

    @Test("เมนูบอกงบวันนี้เป็นภาษาคน")
    func todayPlanText() throws {
        let thursday = try #require(usage(fiveHour: 0, fiveHourReset: nil, weekly: 30, weeklyReset: "2026-11-08T20:00:00Z"))
        let plan = try #require(NightShiftPlanner.todayPlan(thursday, config: on,
                                                            now: at("2026-11-05T14:00:00+07:00"), calendar: bangkok))
        // End of Thursday = 93 h into the week → 65 × 93/149 = 40%.
        #expect(plan.hasPrefix("วันนี้ใช้ได้ถึง 40%"))
        #expect(plan.contains("ใช้ไป 30%"))
        // A reading from last week still gives today's line, without usage.
        let lastWeek = try #require(usage(weekly: 80, weeklyReset: "2026-10-25T20:00:00Z"))
        #expect(NightShiftPlanner.todayPlan(lastWeek, config: on, now: at("2026-11-05T14:00:00+07:00"),
                                            calendar: bangkok) == "วันนี้ใช้ได้ถึง 40% ของสัปดาห์")
        // Last day, not answered yet: the menu asks instead.
        let sunday = try #require(usage(weekly: 60))
        #expect(NightShiftPlanner.todayPlan(sunday, config: on,
                                            now: at("2026-11-01T10:00:00+07:00"), calendar: bangkok) == nil)
    }

    @Test("โหมดเฉพาะคืนก่อนรีเซ็ต: วันอังคาร → หยุด, คืนวันอาทิตย์ → ทำได้")
    func finalMode() {
        var config = on
        config.mode = .final
        let tuesday = NightShiftPlanner.decide(usage(fiveHour: 0, fiveHourReset: nil, weekly: 5,
                                                     weeklyReset: "2026-11-08T20:00:00Z"),
                                               config: config, now: at("2026-11-03T23:00:00+07:00"), calendar: bangkok)
        #expect(!tuesday.go)
        let sunday = NightShiftPlanner.decide(usage(fiveHour: 0, fiveHourReset: nil, weekly: 66),
                                              config: config, now: at("2026-11-01T23:00:00+07:00"), calendar: bangkok)
        #expect(sunday.go)
    }

    @Test("รอบรายสัปดาห์ยังไม่เริ่ม (ไม่มีเวลารีเซ็ต) → ไม่แตะงบทั้งสัปดาห์ของผู้ใช้")
    func freshWeekStops() {
        let decision = NightShiftPlanner.decide(usage(fiveHour: 0, fiveHourReset: nil, weekly: 0, weeklyReset: nil),
                                                config: on, now: at("2026-11-02T23:00:00+07:00"), calendar: bangkok)
        #expect(!decision.go)
    }

    @Test("แชตกะดึกใช้บริบทเกิน 50% → ปิดรอบ")
    func longChatStops() {
        let decision = NightShiftPlanner.decide(usage(fiveHour: 10, fiveHourReset: "2026-11-01T18:00:00Z", context: 55),
                                                config: on, now: at("2026-11-01T23:00:00+07:00"), calendar: bangkok)
        #expect(!decision.go)
        #expect(decision.reason.contains("บริบท"))
    }

    @Test("ด่านจับ prompt ที่แอปห่อด้วย <scheduled-task> ได้ (ของจริงจากรอบ 13:52) แต่ไม่แตะแชตอื่น")
    func recognisesRoutinePrompt() {
        let real = """
        <scheduled-task name="finish-engine-night-shift" file="/Users/stamp/.claude/scheduled-tasks/finish-engine-night-shift/SKILL.md">
        This is an automated run of a scheduled task. The user is not present to answer questions. For implementation details, execute autonomously without asking clarifying questions — make reasonable choices and note them in your output. "write" actions (e.g. MCP tools that send, post, create, update, or delete), only take them if the task file asks for that specific action. When in doubt, producing a report of what you found is the correct output.

        [FE-NIGHTSHIFT] กะดึก Finish Engine — ทำงานแทนผู้ใช้ตอนกลางคืนด้วยโควตาที่เหลือ
        """
        #expect(NightShift.isNightShiftPrompt(real))
        #expect(NightShift.isNightShiftPrompt("[FE-NIGHTSHIFT] กะดึก ทดสอบ"))
        #expect(!NightShift.isNightShiftPrompt("<scheduled-task name=\"daily-standup\" file=\"x\">\nสรุปงาน"))
        #expect(!NightShift.isNightShiftPrompt(String(repeating: "ช่วยอธิบายระบบกะดึก ", count: 30) + "[FE-NIGHTSHIFT]"))
    }

    // MARK: Report day

    @Test("ตี 1 ของวันที่ 2 ลงรายงานคืนวันที่ 1")
    func nightOfReport() {
        #expect(NightShift.night(of: at("2026-11-02T01:00:00+07:00"), morningHour: 8, calendar: bangkok) == "2026-11-01")
        #expect(NightShift.night(of: at("2026-11-01T23:00:00+07:00"), morningHour: 8, calendar: bangkok) == "2026-11-01")
        #expect(NightShift.night(of: at("2026-11-02T09:00:00+07:00"), morningHour: 8, calendar: bangkok) == "2026-11-02")
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = bangkok.timeZone
        #expect(NightShift.night(of: at("2026-11-01T23:00:00+07:00"), morningHour: 8, calendar: buddhist) == "2026-11-01")
        #expect(NightShift.entries(inReport: "# รายงาน\n- 23:05 · ทำ A\n\n- 01:10 · หยุด") == ["23:05 · ทำ A", "01:10 · หยุด"])
    }

    // MARK: Picking

    private func task(_ id: String, project: String = "AI OS", status: String = "Doing", tier: String = "MVP",
                      holder: String? = nil, heldAt: Date? = nil, edited: Date? = nil) -> FinishEngineTask {
        FinishEngineTask(id: id, task: "งาน \(id)", project: project, status: status, tier: tier, weight: 1,
                         blocker: "", holder: holder, heldAt: heldAt, lastEdited: edited)
    }

    @Test("เลือกเฉพาะโปรเจกต์ที่ติ๊ก และงานที่ยังไม่เสร็จ")
    func picksAllowedOpenWork() {
        let now = at("2026-11-01T23:00:00+07:00")
        let tasks = [task("a", project: "Slidegen"), task("b", status: "Done"), task("c", status: "Todo")]
        #expect(NightShiftPicker.pick(tasks, config: on, state: NightShiftState(), now: now)?.id == "c")
        var none = on
        none.projects = ["FORM"]
        #expect(NightShiftPicker.pick(tasks, config: none, state: NightShiftState(), now: now) == nil)
    }

    @Test("อัตโนมัติ: เลือกจากทุกโปรเจกต์ รวมโปรเจกต์ใหม่ที่ไม่เคยติ๊ก")
    func autoProjects() {
        let now = at("2026-11-01T23:00:00+07:00")
        var auto = on
        auto.projects = []
        auto.allProjects = true
        #expect(auto.hasProjects)
        let tasks = [task("form", project: "FORM", status: "Todo"), task("done", status: "Done")]
        #expect(NightShiftPicker.pick(tasks, config: auto, state: NightShiftState(), now: now)?.id == "form")
        #expect(NightShiftPlanner.decide(usage(fiveHour: 0, fiveHourReset: nil, weekly: 66),
                                         config: auto, now: now, calendar: bangkok).go)
        // A task with no Project stays out even in auto.
        #expect(NightShiftPicker.pick([task("x", project: "")], config: auto, state: NightShiftState(), now: now) == nil)
    }

    @Test("งานที่คนอื่นเพิ่งกด ทำต่อ (< 2 ชม.) → ไม่แย่ง")
    func leavesFreshlyHeldWork() {
        let now = at("2026-11-01T23:00:00+07:00")
        let tasks = [task("held", holder: "Codex", heldAt: now.addingTimeInterval(-1800)),
                     task("free", status: "Todo")]
        #expect(NightShiftPicker.pick(tasks, config: on, state: NightShiftState(), now: now)?.id == "free")
    }

    @Test("รอบ 01:00 ทำงานที่รอบ 23:00 จองไว้ต่อ ก่อนเปิดงานใหม่")
    func continuesOwnClaim() {
        let claimedAt = at("2026-11-01T23:02:00+07:00")
        let now = at("2026-11-02T01:00:00+07:00")
        let tasks = [task("new", edited: now), task("mine", status: "Doing", tier: "LATER",
                                                     holder: "Claude", heldAt: claimedAt)]
        var state = NightShiftState()
        state.claimed["mine"] = claimedAt
        #expect(NightShiftPicker.pick(tasks, config: on, state: state, now: now)?.id == "mine")
    }

    @Test("งานที่ต้องรอผู้ใช้ถูกพักไว้ จนกว่าแถวใน Tracker จะถูกแก้ทีหลัง")
    func skipsUntilEdited() {
        let skippedAt = at("2026-11-01T23:30:00+07:00")
        let now = at("2026-11-02T01:00:00+07:00")
        var state = NightShiftState()
        state.skipped["s"] = skippedAt
        let untouched = [task("s", edited: skippedAt.addingTimeInterval(-60))]
        #expect(NightShiftPicker.pick(untouched, config: on, state: state, now: now) == nil)
        let editedLater = [task("s", edited: skippedAt.addingTimeInterval(3600))]
        #expect(NightShiftPicker.pick(editedLater, config: on, state: state, now: now)?.id == "s")
    }
}

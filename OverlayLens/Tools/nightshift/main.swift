// nightshift-cli (build: deploy.sh, with OverlayLens/NightShiftLogic.swift + FinishEngineLogic.swift)
// เครื่องมือของกะดึก Finish Engine — แชตกะดึก (Routine "Finish Engine กะดึก" ในแอป Claude) เรียกใช้
// และเป็น hook UserPromptSubmit ที่บล็อกแชตกะดึกก่อนถึงโมเดลเมื่อสวิตช์ในเมนู StampLab ปิด
//
// ใช้: nightshift-cli gate                      (hook: อ่าน JSON จาก stdin; prompt อื่นผ่านเงียบ ๆ)
//      nightshift-cli check '<JSON ของ get_usage>' ทำต่อได้ไหม (exit 0 = GO, 3 = STOP)
//      nightshift-cli pick                      งานถัดไปในโปรเจกต์ที่ผู้ใช้ติ๊ก (exit 3 = ไม่มี)
//      nightshift-cli claim <id>                Status=Doing, Holder=Claude, Held At=ตอนนี้
//      nightshift-cli note <id> "<ข้อความ>"      บันทึกความคืบหน้าลง Blocker (เก็บของเดิมต่อท้าย)
//      nightshift-cli done <id> "<หลักฐาน>"      Status=Done — ใช้เมื่อทุกข้อของ DoD มีหลักฐานแล้วเท่านั้น
//      nightshift-cli skip <id> "<เหตุผล>"       พักงานที่ต้องรอผู้ใช้ จนกว่าแถวใน Tracker จะถูกแก้
//      nightshift-cli report "<ข้อความ>"         เพิ่มบรรทัดในรายงานของคืนนี้
//      nightshift-cli status                    ดูตั้งค่า + โควตาล่าสุด + รายงานคืนนี้
import Foundation

let args = Array(CommandLine.arguments.dropFirst())
let config = NightShiftConfig.load()
let now = Date()

func fail(_ message: String, code: Int32 = 4) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

func argument(_ index: Int, _ name: String) -> String {
    guard args.count > index, !args[index].isEmpty else { fail("ขาด \(name)", code: 2) }
    return args[index]
}

/// Notion page ids as Notion writes them or as a notion.so URL ends.
func pageID(_ raw: String) -> String {
    let hex = raw.split(separator: "/").last.map(String.init)?
        .components(separatedBy: CharacterSet(charactersIn: "?#")).first ?? raw
    let compact = String(hex.filter(\.isHexDigit).suffix(32))
    guard compact.count == 32 else { fail("id งานไม่ถูกต้อง: \(raw)", code: 2) }
    var id = compact
    for offset in [8, 13, 18, 23] { id.insert("-", at: id.index(id.startIndex, offsetBy: offset)) }
    return id.lowercased()
}

func clock(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm"
    return formatter.string(from: date)
}

/// "1 พ.ย. 23:05" like the notes the user and other AIs leave in Blocker.
func stamp(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "th_TH")
    formatter.dateFormat = "d MMM HH:mm"
    return formatter.string(from: date)
}

/// Notion caps one rich-text run at 2000 UTF-16 units; Thai marks count separately.
func clip(_ text: String, _ limit: Int) -> String {
    var out = ""
    var used = 0
    for character in text {
        let size = character.utf16.count
        if used + size > limit { break }
        out.append(character)
        used += size
    }
    return out
}

/// The weekly reset from the last get_usage the night chat saved, rolled
/// forward by whole weeks when that reading is older than the reset.
func lastWeeklyReset() -> Date? {
    guard let data = try? Data(contentsOf: NightShift.usageURL),
          var reset = NightShiftUsage.parse(data)?.weekly.first?.resetsAt else { return nil }
    while reset <= now { reset.addTimeInterval(NightShiftPlanner.week) }
    return reset
}

// MARK: Report

func appendReport(_ line: String) {
    let night = NightShift.night(of: now, morningHour: config.morningHour)
    let url = NightShift.reportURL(night: night)
    try? FileManager.default.createDirectory(at: NightShift.reportsFolder, withIntermediateDirectories: true)
    let entry = "- \(clock(now)) · " + line.components(separatedBy: .newlines).joined(separator: " ") + "\n"
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(Data(entry.utf8))
        try? handle.close()
    } else {
        try? ("# รายงานกะดึก คืน \(night)\n\n" + entry).write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: Notion

final class Box: @unchecked Sendable { var data: Data? }

func notion(_ method: String, _ path: String, body: [String: Any]? = nil) -> [String: Any] {
    let tokenURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".finish-engine/notion_token")
    let token = ((try? String(contentsOf: tokenURL, encoding: .utf8)) ?? "")
        .components(separatedBy: .whitespacesAndNewlines).joined()
    guard !token.isEmpty, let url = URL(string: "https://api.notion.com/v1/" + path) else {
        fail("ไม่มี Notion token (~/.finish-engine/notion_token)")
    }
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.timeoutInterval = 20
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("2025-09-03", forHTTPHeaderField: "Notion-Version")
    if let body {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
    }
    let box = Box()
    let done = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: request) { data, _, _ in
        box.data = data
        done.signal()
    }.resume()
    done.wait()
    guard let data = box.data,
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { fail("ต่อ Notion ไม่ได้ (เน็ตหรือ Notion ล่ม)") }
    if json["object"] as? String == "error" {
        fail("Notion ตอบ error: \(json["code"] as? String ?? "?") \(json["message"] as? String ?? "")")
    }
    return json
}

func property(_ page: [String: Any], _ key: String) -> [String: Any]? {
    (page["properties"] as? [String: Any])?[key] as? [String: Any]
}

func select(_ page: [String: Any], _ key: String) -> String? {
    (property(page, key)?["select"] as? [String: Any])?["name"] as? String
}

func text(_ page: [String: Any], _ key: String) -> String {
    let runs = (property(page, key)?["title"] ?? property(page, key)?["rich_text"]) as? [[String: Any]] ?? []
    return runs.compactMap { $0["plain_text"] as? String }.joined()
}

func timestamp(_ raw: String?) -> Date? {
    guard let raw else { return nil }
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = iso.date(from: raw) { return date }
    iso.formatOptions = [.withInternetDateTime]
    return iso.date(from: raw)
}

func task(from page: [String: Any]) -> FinishEngineTask {
    let title = text(page, "Task")
    return FinishEngineTask(
        id: page["id"] as? String ?? "",
        task: title.isEmpty ? "(ไม่มีชื่องาน)" : title,
        project: select(page, "Project") ?? "",
        status: select(page, "Status") ?? "Todo",
        tier: select(page, "Tier") ?? "LATER",
        weight: (property(page, "Weight")?["number"] as? NSNumber)?.doubleValue ?? 1,
        blocker: text(page, "Blocker"),
        dod: text(page, "DoD"),
        holder: select(page, "Holder"),
        heldAt: timestamp((property(page, "Held At")?["date"] as? [String: Any])?["start"] as? String),
        lastEdited: timestamp(page["last_edited_time"] as? String)
    )
}

func fetchTasks() -> [FinishEngineTask] {
    var tasks: [FinishEngineTask] = []
    var cursor: String?
    repeat {
        var body: [String: Any] = ["page_size": 100]
        if let cursor { body["start_cursor"] = cursor }
        let json = notion("POST", "data_sources/\(NightShift.trackerID)/query", body: body)
        tasks += (json["results"] as? [[String: Any]] ?? []).map(task(from:))
        cursor = json["has_more"] as? Bool == true ? json["next_cursor"] as? String : nil
    } while cursor != nil
    return tasks
}

/// Newest note first, the previous ones kept after it (Blocker is the task's running log).
func writeNote(_ id: String, _ line: String, status: String? = nil) {
    let old = text(notion("GET", "pages/\(id)"), "Blocker")
    var note = "\(stamp(now)) กะดึก: \(line)"
    if !old.isEmpty { note += " ‖ " + old }
    var properties: [String: Any] = ["Blocker": ["rich_text": [["text": ["content": clip(note, 1900)]]]]]
    if let status { properties["Status"] = ["select": ["name": status]] }
    _ = notion("PATCH", "pages/\(id)", body: ["properties": properties])
}

// MARK: Commands

switch args.first ?? "" {
case "gate":
    let input = FileHandle.standardInput.readDataToEndOfFile()
    let json = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] ?? [:]
    let prompt = json["prompt"] as? String ?? ""
    guard NightShift.isNightShiftPrompt(prompt) else { exit(0) }
    let reason: String
    if !config.enabled {
        reason = "กะดึกปิดอยู่ในเมนู StampLab"
    } else if !config.hasProjects {
        reason = "ยังไม่ได้ติ๊กโปรเจกต์ให้กะดึกในเมนู StampLab"
    } else if NightShiftPlanner.daytimeBlocked(now: now, config: config, weeklyReset: lastWeeklyReset()) {
        // The daytime slots exist for a last day the user gives away; on
        // other days they are expected to stop here, so no report line.
        let out = ["decision": "block", "reason": "กลางวันเป็นเวลาของคุณ (กะดึกทำกลางวันเฉพาะวันสุดท้ายที่คุณตอบว่าไม่ทำงาน)"]
        if let data = try? JSONSerialization.data(withJSONObject: out) { FileHandle.standardOutput.write(data) }
        exit(0)
    } else {
        exit(0)
    }
    // Daytime slots stop here on most days; only night runs go in the report.
    let hour = Calendar.current.component(.hour, from: now)
    if hour < config.morningHour || hour >= config.nightHour {
        appendReport("ข้ามรอบ: \(reason) (บล็อกก่อนถึงโมเดล ไม่เสีย token)")
    }
    let out = ["decision": "block", "reason": reason + " — เปิดได้ที่เมนู StampLab > กะดึก"]
    if let data = try? JSONSerialization.data(withJSONObject: out) {
        FileHandle.standardOutput.write(data)
    }
    exit(0)

case "check":
    let data = args.count > 1 ? Data(args[1].utf8) : FileHandle.standardInput.readDataToEndOfFile()
    let usage = NightShiftUsage.parse(data)
    if usage != nil {
        try? FileManager.default.createDirectory(at: NightShift.folder, withIntermediateDirectories: true)
        try? data.write(to: NightShift.usageURL, options: .atomic)
    }
    let decision = NightShiftPlanner.decide(usage, config: config, now: now)
    print((decision.go ? "GO: " : "STOP: ") + decision.reason)
    exit(decision.go ? 0 : 3)

case "pick":
    guard config.enabled, config.hasProjects else {
        print("NONE: กะดึกปิดอยู่หรือยังไม่ได้ติ๊กโปรเจกต์ในเมนู StampLab")
        exit(3)
    }
    let tasks = fetchTasks()
    guard let picked = NightShiftPicker.pick(tasks, config: config, state: .load(), now: now) else {
        print("NONE: ไม่มีงานที่ทำได้ตอนนี้ใน\(config.allProjects ? "ทุกโปรเจกต์" : "โปรเจกต์ที่ติ๊กไว้ (\(config.projects.joined(separator: ", ")))")")
        exit(3)
    }
    print("""
    id: \(picked.id)
    project: \(picked.project)
    task: \(picked.task)
    status: \(picked.status) · tier: \(picked.tier)
    DoD: \(picked.dod.isEmpty ? "(ไม่มี DoD — ห้ามปิด Done ทำเฉพาะขั้นที่ตรวจผลได้)" : picked.dod)
    บันทึกล่าสุด: \(picked.blocker.isEmpty ? "-" : clip(picked.blocker, 1200))
    url: https://www.notion.so/\(picked.id.replacingOccurrences(of: "-", with: ""))
    """)

case "claim":
    let id = pageID(argument(1, "id งาน"))
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime]
    iso.timeZone = .current
    _ = notion("PATCH", "pages/\(id)", body: ["properties": [
        "Status": ["select": ["name": "Doing"]],
        "Holder": ["select": ["name": NightShift.holder]],
        "Held At": ["date": ["start": iso.string(from: now)]],
    ]])
    var state = NightShiftState.load()
    state.claimed[id] = now
    state.skipped[id] = nil
    try? state.save()
    print("จองแล้ว: Status=Doing · Holder=\(NightShift.holder) · Held At=\(clock(now))")

case "note":
    let id = pageID(argument(1, "id งาน"))
    writeNote(id, argument(2, "ข้อความ"))
    print("บันทึกลง Blocker แล้ว")

case "done":
    let id = pageID(argument(1, "id งาน"))
    writeNote(id, "✓ เสร็จตาม DoD — หลักฐาน: " + argument(2, "หลักฐาน"), status: "Done")
    var state = NightShiftState.load()
    state.claimed[id] = nil
    try? state.save()
    print("ปิดงานเป็น Done แล้ว พร้อมหลักฐานใน Blocker")

case "skip":
    let id = pageID(argument(1, "id งาน"))
    let reason = argument(2, "เหตุผล")
    var state = NightShiftState.load()
    state.skipped[id] = now
    state.claimed[id] = nil
    try? state.save()
    print("พักงานนี้ไว้จนกว่าแถวใน Tracker จะถูกแก้: \(reason)")

case "report":
    appendReport(argument(1, "ข้อความ"))
    print("เพิ่มในรายงานคืน \(NightShift.night(of: now, morningHour: config.morningHour)) แล้ว")

case "status":
    let night = NightShift.night(of: now, morningHour: config.morningHour)
    print("สวิตช์: \(config.enabled ? "เปิด" : "ปิด") · โปรเจกต์: \(config.allProjects ? "อัตโนมัติ (ทุกโปรเจกต์)" : config.projects.isEmpty ? "-" : config.projects.joined(separator: ", "))")
    print("โหมด: \(config.mode.rawValue) · หยุดที่ 5 ชม. \(config.fiveHourStop)% · สัปดาห์ \(config.weeklyStop)% (\(config.finalHours) ชม.สุดท้าย \(config.finalStop)%) · เช้า \(config.morningHour):00")
    print("Routine: \(FileManager.default.fileExists(atPath: NightShift.routineURL.path) ? "ติดตั้งแล้ว" : "ยังไม่ได้ติดตั้ง")")
    if let data = try? Data(contentsOf: NightShift.usageURL), let usage = NightShiftUsage.parse(data) {
        print("โควตาล่าสุด (ตามที่แชตกะดึกเห็น): " + NightShiftPlanner.decide(usage, config: config, now: now).reason)
        if let plan = NightShiftPlanner.todayPlan(usage, config: config, now: now) { print("แผนวันนี้: " + plan) }
    }
    print("กลางวันตอนนี้: \(NightShiftPlanner.daytimeBlocked(now: now, config: config, weeklyReset: lastWeeklyReset()) ? "บล็อก" : "ทำได้")")
    let report = (try? String(contentsOf: NightShift.reportURL(night: night), encoding: .utf8)) ?? ""
    print("รายงานคืน \(night): \(NightShift.entries(inReport: report).count) รายการ · \(NightShift.reportURL(night: night).path)")

default:
    fail("ใช้: nightshift-cli <gate|check|pick|claim|note|done|skip|report|status>", code: 2)
}

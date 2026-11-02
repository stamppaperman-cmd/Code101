// ambient-hook (build: deploy.sh, with OverlayLens/ClaudeApproval.swift) — เรียกจาก Claude Code hooks เพื่อเขียนสถานะ session ลงไฟล์
// ใช้: ambient-hook <prompt|tool|ask|notify|stop|stopfail|end>  (อ่าน JSON ของ hook จาก stdin)
// ห้ามพิมพ์อะไรออก stdout เด็ดขาด เพราะ Claude อาจอ่านเข้าไปแล้วกิน token
import Foundation

let dir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/StampLab/claude-sessions")

guard CommandLine.arguments.count >= 2 else { exit(0) }
let event = CommandLine.arguments[1]

let input = FileHandle.standardInput.readDataToEndOfFile()
let json = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] ?? [:]
let sid = (json["session_id"] as? String) ?? "unknown"
let safeID = sid.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
let file = dir.appendingPathComponent((safeID.isEmpty ? "unknown" : safeID) + ".json")
let cwd = (json["cwd"] as? String) ?? ""
let label = (cwd as NSString).lastPathComponent
let now = Date().timeIntervalSince1970

try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

/// แชตที่หยุดเพราะโควตาเต็ม (StopFailure) — StampLab อ่านโฟลเดอร์นี้เพื่อบอกเวลาทำต่อ
/// และกันเครื่องหลับจนถึงเวลารีเซ็ต (ดู QuotaResume.swift) ไฟล์หายเมื่อแชตกลับมาทำงาน
let quotaDir = dir.deletingLastPathComponent().appendingPathComponent("quota")
let quotaFile = quotaDir.appendingPathComponent(file.lastPathComponent)

if event == "stopfail" {
    let error = (json["error"] as? String) ?? ""
    let text = [json["last_assistant_message"], json["error_details"]]
        .compactMap { $0 as? String }.joined(separator: " ")
    let lower = text.lowercased()
    // overloaded / server_error ไม่ใช่โควตา: แชตแค่ล้ม ไม่มีเวลารีเซ็ตให้รอ
    guard error == "rate_limit" || lower.contains("usage limit") || lower.contains("hit your") else { exit(0) }
    var record: [String: Any] = ["session": sid, "cwd": cwd, "error": error,
                                 "message": String(text.prefix(200)), "pausedAt": now, "state": "waiting"]
    if let reset = QuotaReset.parse(text) { record["resetAt"] = reset.timeIntervalSince1970 }
    if let transcript = json["transcript_path"] as? String,
       let title = QuotaReset.sessionTitle(inTranscriptTail: QuotaReset.tail(ofFile: transcript)) {
        record["title"] = title
    }
    try? FileManager.default.createDirectory(at: quotaDir, withIntermediateDirectories: true)
    if let data = try? JSONSerialization.data(withJSONObject: record) {
        try? data.write(to: quotaFile, options: .atomic)
    }
    exit(0)
}

/// แชตขยับแล้ว (Claude ทำต่อเอง หรือผู้ใช้พิมพ์ใหม่) → ไม่ต้องรอโควตาแล้ว
func clearQuota() { try? FileManager.default.removeItem(at: quotaFile) }

if event == "end" {
    try? FileManager.default.removeItem(at: file)
    clearQuota()
    exit(0)
}

var rec = (try? JSONSerialization.jsonObject(with: Data(contentsOf: file))) as? [String: Any] ?? [:]
let prev = rec["state"] as? String

/// จดงานล่าสุดของ Claude (3 อย่างล่าสุด + ตัวนับต่อประเภท) ให้หน้าจอพักแสดง
/// เก็บแค่ชื่อไฟล์/คำอธิบายสั้น ๆ ไม่เก็บเนื้อหาคำสั่งเต็ม
func recordAct() {
    let tool = (json["tool_name"] as? String) ?? ""
    let inp = (json["tool_input"] as? [String: Any]) ?? [:]
    func baseName(_ k: String) -> String { ((inp[k] as? String) ?? "").split(separator: "/").last.map(String.init) ?? "" }
    func short(_ v: String, _ n: Int) -> String {
        let t = v.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return t.count > n ? String(t.prefix(n - 1)) + "…" : t
    }
    var kind = "tool", text = ""
    switch tool {
    case "Edit", "MultiEdit", "Write": kind = "edit"; text = baseName("file_path")
    case "NotebookEdit": kind = "edit"; text = baseName("notebook_path")
    case "Read": kind = "read"; text = baseName("file_path")
    case "Bash":
        kind = "bash"
        let firstWord = ((inp["command"] as? String) ?? "").split(separator: " ").first.map(String.init) ?? ""
        text = short((inp["description"] as? String) ?? firstWord, 40)
    case "Grep", "Glob": kind = "search"; text = short((inp["pattern"] as? String) ?? "", 28)
    case "WebSearch": kind = "web"; text = short((inp["query"] as? String) ?? "", 32)
    case "WebFetch": kind = "web"; text = URL(string: (inp["url"] as? String) ?? "")?.host ?? ""
    case "Agent", "Task": kind = "agent"; text = short((inp["description"] as? String) ?? "", 36)
    case "TodoWrite", "ToolSearch": return   // งานภายใน ไม่ต้องโชว์
    default: text = tool.hasPrefix("mcp__") ? (tool.components(separatedBy: "__").last ?? tool) : tool
    }
    var acts = (rec["acts"] as? [[String]]) ?? []
    acts.insert([kind, text], at: 0)
    rec["acts"] = Array(acts.prefix(3))
    var n = (rec["n"] as? [String: Int]) ?? [:]
    n[kind, default: 0] += 1
    rec["n"] = n
}

func set(_ state: String, newStart: Bool = false) {
    if newStart || rec["start"] == nil { rec["start"] = now }
    if prev != state || newStart { rec["since"] = now }
    rec["state"] = state
}

switch event {
case "prompt":
    clearQuota()
    set("work", newStart: true)
    rec["acts"] = []          // งานใหม่ เริ่มนับใหม่
    rec["n"] = [String: Int]()
case "tool":
    // หลังเครื่องมือทำงานเสร็จ = Claude ยังทำงานอยู่ (และถ้าเพิ่งรออนุมัติ แปลว่าอนุมัติแล้ว)
    clearQuota()
    if prev == "done" { exit(0) }  // กันกรณี hook มาช้ากว่า Stop
    set("work")
    // ให้ StampLab รู้ว่าคำสั่งไหนรันแล้ว → เอาการ์ดอนุมัติของคำสั่งนั้นออก (ดู ClaudeApproval)
    rec["lastKey"] = ClaudeApproval.inputKey(tool: (json["tool_name"] as? String) ?? "",
                                             input: (json["tool_input"] as? [String: Any]) ?? [:])
    recordAct()
case "ask":
    set("wait")
case "notify":
    let type = (json["notification_type"] as? String) ?? ""
    let msg = ((json["message"] as? String) ?? "").lowercased()
    // Claude Code รอโควตาเอง (autoContinueAtUsageLimit): fired = ทำต่อแล้ว,
    // stale = เครื่องหลับนานจนต้องกด Enter, disabled = เลิกรอโดยไม่ทำต่อ
    if type.hasPrefix("quota_auto_resume_") {
        if type == "quota_auto_resume_fired" {
            clearQuota()
        } else if var record = (try? JSONSerialization.jsonObject(with: Data(contentsOf: quotaFile))) as? [String: Any] {
            record["state"] = type == "quota_auto_resume_stale" ? "stale" : "disabled"
            if let data = try? JSONSerialization.data(withJSONObject: record) {
                try? data.write(to: quotaFile, options: .atomic)
            }
        }
        exit(0)
    }
    if type == "permission_prompt" || type == "elicitation_dialog"
        || (type.isEmpty && msg.contains("permission")) {
        set("wait")
    } else {
        exit(0)
    }
case "stop":
    clearQuota()
    set("done")
default:
    exit(0)
}

rec["updated"] = now
if !label.isEmpty { rec["label"] = label }
// Local AI = Claude Code pointed at Ollama (see ~/Claude/local-ai/เปิด-Local-AI.command).
let base = ProcessInfo.processInfo.environment["ANTHROPIC_BASE_URL"] ?? ""
rec["agent"] = (json["agent"] as? String) ?? ((base.contains("localhost") || base.contains("127.0.0.1")) ? "local" : "claude")
if let data = try? JSONSerialization.data(withJSONObject: rec) {
    try? data.write(to: file, options: .atomic)
}

// เก็บกวาดไฟล์ของ session ที่เงียบไปเกิน 1 วัน ให้โฟลเดอร์เล็กเสมอ
if let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) {
    for f in files {
        let m = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let m, now - m.timeIntervalSince1970 > 86400 { try? FileManager.default.removeItem(at: f) }
    }
}
exit(0)

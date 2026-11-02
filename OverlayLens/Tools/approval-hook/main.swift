// approval-hook — Claude Code PermissionRequest hook: ส่งคำขอสิทธิ์ไปให้ StampLab
// แสดงปุ่ม อนุญาต / ปฏิเสธ / อนุญาตเสมอ แล้วรอคำตอบ (ดู OverlayLens/ClaudeApproval.swift)
// StampLab ไม่ได้เปิด / ปิดสวิตช์ไว้ / ไม่มีใครกดทันเวลา → ออกเงียบ ๆ ให้ Claude Code ถามตามปกติ
// stdout: พิมพ์เฉพาะ JSON คำตอบตามรูปแบบของ hook เท่านั้น
// ออโต้ไพลอตเปิดอยู่ + auto mode → ตอบเองทันที ไม่แสดงการ์ด (ดู OverlayLens/ClaudeAutopilot.swift)
// build: swiftc -O Tools/approval-hook/main.swift OverlayLens/ClaudeApproval.swift OverlayLens/ClaudeAutopilot.swift -o approval-hook
import AppKit

let fm = FileManager.default

let input = FileHandle.standardInput.readDataToEndOfFile()
let json = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] ?? [:]
let tool = (json["tool_name"] as? String) ?? ""
guard !tool.isEmpty else { exit(0) }
let toolInput = (json["tool_input"] as? [String: Any]) ?? [:]
let sessionID = ClaudeApproval.safeSessionID((json["session_id"] as? String) ?? "")
let cwd = (json["cwd"] as? String) ?? ""

func notify(_ text: String) {
    let script = "display notification \"\(text.replacingOccurrences(of: "\"", with: "'"))\" with title \"StampLab ออโต้ไพลอต\""
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", script]
    try? p.run()
    p.waitUntilExit()
}

// Autopilot (ClaudeAutopilot.swift): answer at once, no card. Works without
// StampLab running. Only in auto mode; otherwise warn once and fall through.
if ClaudeAutopilot.isOn {
    let mode = (json["permission_mode"] as? String) ?? ""
    let shown = ClaudeAutopilot.describe(tool: tool, input: toolInput)
    var state = ClaudeAutopilot.loadState(sessionID)
    if mode == "auto" {
        let verdict = ClaudeAutopilot.classify(tool: tool, input: toolInput)
        let interrupt = ClaudeAutopilot.record(verdict, state: &state)
        ClaudeAutopilot.saveState(state, sessionID)
        switch verdict {
        case .allow(let why): ClaudeAutopilot.log(result: "allow", shown: shown, why: why, cwd: cwd)
        case .deny(let why): ClaudeAutopilot.log(result: interrupt ? "interrupt" : "deny", shown: shown, why: why, cwd: cwd)
        }
        FileHandle.standardOutput.write(ClaudeAutopilot.decisionJSON(verdict, shown: shown, interrupt: interrupt))
        if interrupt { notify(ClaudeAutopilot.interruptNotice()) }
        exit(0)
    }
    ClaudeAutopilot.log(result: "skip", shown: shown, why: "session อยู่ในโหมด \(mode.isEmpty ? "ไม่ทราบ" : mode) ไม่ใช่ auto", cwd: cwd)
    if !state.warnedMode {
        state.warnedMode = true
        ClaudeAutopilot.saveState(state, sessionID)
        notify("ออโต้ไพลอตเปิดอยู่ แต่ session นี้อยู่ในโหมด \(mode.isEmpty ? "ไม่ทราบ" : mode) จึงไม่ตัดสินแทน เลือก Auto ในแอป Claude หรือกด Shift+Tab จนขึ้น auto mode on")
    }
}

guard ClaudeApproval.isEnabled,
      !NSRunningApplication.runningApplications(withBundleIdentifier: ClaudeApproval.appBundleID).isEmpty
else { exit(0) }
let summary = ClaudeApproval.summary(tool: tool, input: toolInput)
// What Claude Code offered to remember for this prompt. Empty for a prompt
// that suggests nothing (a file edit) or only a whole-tool rule — the card
// then shows no "อนุญาตเสมอ" button.
let suggested = ClaudeApproval.suggestedRules(json["permission_suggestions"])

let request = ClaudeApproval.Request(
    id: UUID().uuidString,
    pid: getpid(),
    session: sessionID,
    label: (cwd as NSString).lastPathComponent,
    tool: tool,
    detail: summary.detail,
    note: summary.note,
    inputKey: ClaudeApproval.inputKey(tool: tool, input: toolInput),
    created: Date().timeIntervalSince1970,
    rules: suggested,
    project: cwd
)
let requestURL = ClaudeApproval.requestURL(request.id)
let answerURL = ClaudeApproval.answerURL(request.id)

try? fm.createDirectory(at: ClaudeApproval.folder, withIntermediateDirectories: true)
guard let data = try? JSONEncoder().encode(request), (try? data.write(to: requestURL, options: .atomic)) != nil
else { exit(0) }

func cleanUp() {
    try? fm.removeItem(at: requestURL)
    try? fm.removeItem(at: answerURL)
}

// Claude Code may stop the hook once the prompt is answered in Claude itself.
nonisolated(unsafe) var requestPathC = strdup(requestURL.path)
for sig in [SIGTERM, SIGINT, SIGHUP] {
    signal(sig) { _ in
        if let p = requestPathC { unlink(p) }
        exit(0)
    }
}

let deadline = Date().addingTimeInterval(ClaudeApproval.waitSeconds)
var lastAppCheck = Date()
while Date() < deadline {
    if let raw = try? String(contentsOf: answerURL, encoding: .utf8),
       let answer = ClaudeApproval.Answer(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
        cleanUp()
        // Claude Code writes the rule itself, from updatedPermissions; this is
        // only StampLab's own note of it, for the menu to list and undo.
        if answer == .always { ClaudeApproval.recordSaved(suggested, project: cwd) }
        FileHandle.standardOutput.write(ClaudeApproval.decisionJSON(answer, rules: suggested))
        exit(0)
    }
    // StampLab removed the request: settled in Claude Code, or dismissed.
    if !fm.fileExists(atPath: requestURL.path) { exit(0) }
    if Date().timeIntervalSince(lastAppCheck) > 2 {
        lastAppCheck = Date()
        if NSRunningApplication.runningApplications(withBundleIdentifier: ClaudeApproval.appBundleID).isEmpty || !ClaudeApproval.isEnabled {
            cleanUp()
            exit(0)
        }
    }
    usleep(200_000)
}
cleanUp()
exit(0)

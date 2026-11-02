import Foundation
import Testing
@testable import StampLabLogic

@Suite("ออโต้ไพลอตตัดสินคำขอสิทธิ์")
struct ClaudeAutopilotTests {
    private func bash(_ command: String) -> ClaudeAutopilot.Verdict {
        ClaudeAutopilot.classify(tool: "Bash", input: ["command": command])
    }

    private func isAllow(_ v: ClaudeAutopilot.Verdict) -> Bool {
        if case .allow = v { return true }
        return false
    }

    @Test("คำสั่งอ่านอย่างเดียว อนุญาต", arguments: [
        "ls -la", "cat README.md", "git status", "git log --oneline -5", "git diff HEAD~1",
        "grep -n foo *.swift | head -20", "ls 2>/dev/null && pwd", "cat a.txt 2>&1 | wc -l",
        "find . -name '*.swift'", "echo 'a > b'", "git branch", "FOO=1 ls",
    ])
    func readOnlyAllowed(_ command: String) {
        #expect(isAllow(bash(command)), "\(command)")
    }

    @Test("คำสั่งที่เขียน ลบ ส่งออก หรือไม่รู้จัก ปฏิเสธ", arguments: [
        "rm -rf build", "sudo ls", "git push", "git commit -m x", "echo hi > out.txt",
        "cat a >> b", "ls &> log", "curl https://example.com", "find . -delete",
        "find . -exec rm {} \\;", "ls; rm x", "echo $(rm x)", "cat `ls`", "touch x",
        "git branch -D main", "defaults write com.x y 1", "sed -i '' s/a/b/ f", "python3 x.py",
        "echo 'unclosed", "cat <<EOF\nhello\nEOF", "ls >&out", "",
    ])
    func othersDenied(_ command: String) {
        #expect(!isAllow(bash(command)), "\(command)")
    }

    @Test("เครื่องมืออ่านไฟล์ อนุญาต แต่เขียนไฟล์และเว็บ ปฏิเสธ")
    func tools() {
        #expect(isAllow(ClaudeAutopilot.classify(tool: "Read", input: ["file_path": "/etc/hosts"])))
        #expect(isAllow(ClaudeAutopilot.classify(tool: "Grep", input: ["pattern": "x"])))
        #expect(!isAllow(ClaudeAutopilot.classify(tool: "Write", input: ["file_path": "/x"])))
        #expect(!isAllow(ClaudeAutopilot.classify(tool: "Edit", input: ["file_path": "/x"])))
        #expect(!isAllow(ClaudeAutopilot.classify(tool: "WebFetch", input: ["url": "https://x"])))
        #expect(!isAllow(ClaudeAutopilot.classify(tool: "mcp__slack__send", input: [:])))
    }

    @Test("ปฏิเสธติดกัน 3 ครั้ง = หยุดงาน แล้วนับใหม่; อนุญาตคั่น = นับใหม่")
    func streak() {
        var state = ClaudeAutopilot.SessionState()
        let deny = ClaudeAutopilot.Verdict.deny("x")
        #expect(!ClaudeAutopilot.record(deny, state: &state))
        #expect(!ClaudeAutopilot.record(deny, state: &state))
        #expect(!ClaudeAutopilot.record(.allow("y"), state: &state))
        #expect(state.denies == 0)
        #expect(!ClaudeAutopilot.record(deny, state: &state))
        #expect(!ClaudeAutopilot.record(deny, state: &state))
        #expect(ClaudeAutopilot.record(deny, state: &state))
        #expect(state.denies == 0)
    }

    @Test("คำตอบตรงรูปแบบ hook: ปฏิเสธบอกเหตุผล หยุดงานมี interrupt")
    func json() throws {
        func parse(_ data: Data) throws -> ([String: Any], [String: Any]) {
            let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            let out = try #require(root["hookSpecificOutput"] as? [String: Any])
            #expect(out["hookEventName"] as? String == "PermissionRequest")
            return (root, try #require(out["decision"] as? [String: Any]))
        }
        let (_, allow) = try parse(ClaudeAutopilot.decisionJSON(.allow("r"), shown: "Bash: ls", interrupt: false))
        #expect(allow["behavior"] as? String == "allow")
        #expect(allow["message"] == nil)

        let (root, deny) = try parse(ClaudeAutopilot.decisionJSON(.deny("เหตุผล"), shown: "Bash: rm x", interrupt: false))
        #expect(deny["behavior"] as? String == "deny")
        let message = try #require(deny["message"] as? String)
        #expect(message.contains("rm x") && message.contains("เหตุผล") && message.contains("รายงานผู้ใช้"))
        #expect(deny["interrupt"] == nil)
        #expect(root["systemMessage"] == nil)

        let (root2, stop) = try parse(ClaudeAutopilot.decisionJSON(.deny("x"), shown: "Bash: rm x", interrupt: true))
        #expect(stop["interrupt"] as? Bool == true)
        #expect((root2["systemMessage"] as? String)?.isEmpty == false)
    }

    @Test("ประวัติบันทึก เวลา ผล คำสั่ง เหตุผล")
    func logLine() {
        let line = ClaudeAutopilot.logLine(date: Date(timeIntervalSince1970: 0), result: "deny",
                                           shown: "Bash: rm x", why: "ไม่ใช่การอ่าน", cwd: "/p")
        #expect(line.contains("deny") && line.contains("Bash: rm x") && line.contains("ไม่ใช่การอ่าน") && line.contains("/p"))
        #expect(line.hasSuffix("\n"))
    }
}

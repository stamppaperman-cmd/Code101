import Foundation
import Testing
@testable import StampLabLogic

@Suite("ปุ่มอนุมัติคำขอของ Claude")
struct ClaudeApprovalTests {
    private func decision(_ data: Data) throws -> [String: Any] {
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let output = try #require(root["hookSpecificOutput"] as? [String: Any])
        #expect(output["hookEventName"] as? String == "PermissionRequest")
        return try #require(output["decision"] as? [String: Any])
    }

    @Test("คำตอบ อนุญาต ตรงรูปแบบของ Claude Code")
    func allowJSON() throws {
        let d = try decision(ClaudeApproval.decisionJSON(.allow))
        #expect(d["behavior"] as? String == "allow")
        #expect(d["message"] == nil)
    }

    @Test("คำตอบ ปฏิเสธ บอกเหตุผลให้ Claude")
    func denyJSON() throws {
        let d = try decision(ClaudeApproval.decisionJSON(.deny))
        #expect(d["behavior"] as? String == "deny")
        #expect((d["message"] as? String)?.isEmpty == false)
    }

    @Test("การ์ดแสดงคำสั่งเต็ม และคำอธิบายของ Claude")
    func bashSummary() {
        let s = ClaudeApproval.summary(tool: "Bash", input: ["command": "rm -rf build", "description": "Remove build folder"])
        #expect(s.detail == "rm -rf build")
        #expect(s.note == "Remove build folder")
    }

    @Test("แก้ไฟล์: แสดงที่อยู่ไฟล์")
    func editSummary() {
        #expect(ClaudeApproval.summary(tool: "Edit", input: ["file_path": "/a/b.swift", "old_string": "x"]).detail == "/a/b.swift")
    }

    @Test("เครื่องมือ MCP: ชื่ออ่านง่าย และแสดงค่าที่ส่งไป")
    func mcpSummary() {
        #expect(ClaudeApproval.toolLabel("mcp__claude-in-chrome__navigate") == "claude-in-chrome · navigate")
        #expect(ClaudeApproval.summary(tool: "mcp__x__y", input: ["url": "https://a.b"]).detail.contains("https:"))
    }

    @Test("รหัสคำสั่งเหมือนกันแม้ลำดับคีย์ต่างกัน และต่างกันเมื่อคำสั่งต่าง")
    func inputKeyStable() {
        let a = ClaudeApproval.inputKey(tool: "Bash", input: ["command": "ls", "description": "list"])
        let b = ClaudeApproval.inputKey(tool: "Bash", input: ["description": "list", "command": "ls"])
        let c = ClaudeApproval.inputKey(tool: "Bash", input: ["command": "ls -la", "description": "list"])
        let d = ClaudeApproval.inputKey(tool: "Read", input: ["command": "ls", "description": "list"])
        #expect(a == b)
        #expect(a != c)
        #expect(a != d)
    }

    @Test("การ์ดหายเมื่อคำสั่งนั้นรันแล้ว (อนุญาตในหน้าต่าง Claude)")
    func settledWhenThatCallRan() {
        let s = ClaudeApproval.SessionSnapshot(state: "work", updated: 105, start: 50, lastKey: "k1")
        #expect(ClaudeApproval.isSettledElsewhere(requestCreated: 100, inputKey: "k1", session: s))
    }

    @Test("เครื่องมืออื่นที่ทำงานพร้อมกันเสร็จ ไม่ทำให้การ์ดหาย")
    func parallelToolDoesNotSettle() {
        let s = ClaudeApproval.SessionSnapshot(state: "work", updated: 105, start: 50, lastKey: "other")
        #expect(!ClaudeApproval.isSettledElsewhere(requestCreated: 100, inputKey: "k1", session: s))
    }

    @Test("การ์ดหายเมื่อ Claude จบรอบ หรือเริ่มคำสั่งใหม่")
    func settledWhenTurnMovesOn() {
        let done = ClaudeApproval.SessionSnapshot(state: "done", updated: 105, start: 50, lastKey: nil)
        let newPrompt = ClaudeApproval.SessionSnapshot(state: "work", updated: 105, start: 104, lastKey: nil)
        #expect(ClaudeApproval.isSettledElsewhere(requestCreated: 100, inputKey: "k1", session: done))
        #expect(ClaudeApproval.isSettledElsewhere(requestCreated: 100, inputKey: "k1", session: newPrompt))
    }

    @Test("สถานะเก่ากว่าคำขอ หรือไม่มีข้อมูล session ต้องไม่ทำให้การ์ดหาย")
    func staleOrMissingSessionKeepsCard() {
        let old = ClaudeApproval.SessionSnapshot(state: "done", updated: 90, start: 50, lastKey: "k1")
        #expect(!ClaudeApproval.isSettledElsewhere(requestCreated: 100, inputKey: "k1", session: old))
        #expect(!ClaudeApproval.isSettledElsewhere(requestCreated: 100, inputKey: "k1", session: nil))
    }

    @Test("อ่านไฟล์สถานะของ ambient-hook ได้")
    func snapshotFromRecord() {
        let s = ClaudeApproval.SessionSnapshot(record: ["state": "wait", "updated": 12.5, "start": 3.0, "lastKey": "ab"])
        #expect(s == ClaudeApproval.SessionSnapshot(state: "wait", updated: 12.5, start: 3, lastKey: "ab"))
        #expect(ClaudeApproval.SessionSnapshot(record: ["state": "wait"]) == nil)
    }

    @Test("ชื่อไฟล์ session ใช้ตัวกรองเดียวกับ ambient-hook")
    func safeSessionID() {
        #expect(ClaudeApproval.safeSessionID("ab-12_c/../x") == "ab-12_cx")
        #expect(ClaudeApproval.safeSessionID("") == "unknown")
    }
}

@Suite("ปุ่ม อนุญาตเสมอ")
struct ClaudeAlwaysAllowTests {
    private func suggestion(
        type: String = "addRules", behavior: String = "allow",
        rules: [[String: Any]] = [["toolName": "Bash", "ruleContent": "npm run test:*"]]
    ) -> [[String: Any]] {
        [["type": type, "behavior": behavior, "destination": "localSettings", "rules": rules]]
    }

    private func decision(_ data: Data) throws -> [String: Any] {
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let output = try #require(root["hookSpecificOutput"] as? [String: Any])
        return try #require(output["decision"] as? [String: Any])
    }

    @Test("กฎที่ Claude Code แนะนำ อ่านมาแสดงบนการ์ดได้")
    func readsSuggestions() {
        let rules = ClaudeApproval.suggestedRules(suggestion())
        #expect(rules == [ClaudeApproval.Rule(toolName: "Bash", ruleContent: "npm run test:*")])
        #expect(rules.first?.display == "Bash(npm run test:*)")
    }

    @Test("ไม่มีคำแนะนำ (เช่นกรณีแก้ไฟล์) = ไม่มีกฎ ไม่ต้องโชว์ปุ่ม")
    func noSuggestionsNoButton() {
        #expect(ClaudeApproval.suggestedRules(nil).isEmpty)
        #expect(ClaudeApproval.suggestedRules([]).isEmpty)
        #expect(ClaudeApproval.suggestedRules("ไม่ใช่ลิสต์").isEmpty)
    }

    @Test("กฎที่ครอบทั้ง tool (ไม่มี ruleContent) ไม่เอามาทำปุ่ม")
    func wholeToolRuleDropped() {
        #expect(ClaudeApproval.suggestedRules(suggestion(rules: [["toolName": "Bash"]])).isEmpty)
        #expect(ClaudeApproval.suggestedRules(
            suggestion(rules: [["toolName": "Bash", "ruleContent": ""]])).isEmpty)
    }

    @Test("คำแนะนำที่ไม่ใช่ addRules/allow ไม่เอามาทำปุ่ม")
    func onlyAddAllowRules() {
        #expect(ClaudeApproval.suggestedRules(suggestion(type: "setMode")).isEmpty)
        #expect(ClaudeApproval.suggestedRules(suggestion(behavior: "deny")).isEmpty)
    }

    @Test("กฎซ้ำในคำแนะนำ นับครั้งเดียว")
    func duplicateRulesCollapse() {
        let same: [String: Any] = ["toolName": "Bash", "ruleContent": "ls:*"]
        #expect(ClaudeApproval.suggestedRules(suggestion(rules: [same, same])).count == 1)
    }

    @Test("กด อนุญาตเสมอ: ตอบ allow พร้อมส่งกฎกลับไปให้ Claude Code เขียนเอง")
    func alwaysSendsBackPermissionUpdate() throws {
        let rules = ClaudeApproval.suggestedRules(suggestion())
        let d = try decision(ClaudeApproval.decisionJSON(.always, rules: rules))
        #expect(d["behavior"] as? String == "allow")
        #expect(d["message"] == nil)
        let updates = try #require(d["updatedPermissions"] as? [[String: Any]])
        #expect(updates.count == 1)
        let update = try #require(updates.first)
        #expect(update["type"] as? String == "addRules")
        #expect(update["behavior"] as? String == "allow")
        // localSettings = Claude Code writes .claude/settings.local.json itself;
        // StampLab never edits that file to add a rule.
        #expect(update["destination"] as? String == "localSettings")
        let sent = try #require(update["rules"] as? [[String: String]])
        #expect(sent == [["toolName": "Bash", "ruleContent": "npm run test:*"]])
    }

    @Test("ไม่มีกฎ: อนุญาตเสมอ กลายเป็นอนุญาตธรรมดา ไม่ส่งกฎเปล่ากลับไป")
    func alwaysWithoutRulesIsPlainAllow() throws {
        let d = try decision(ClaudeApproval.decisionJSON(.always, rules: []))
        #expect(d["behavior"] as? String == "allow")
        #expect(d["updatedPermissions"] == nil)
    }

    @Test("อนุญาต / ปฏิเสธ ธรรมดา ไม่มีกฎติดไปด้วย")
    func plainAnswersCarryNoRules() throws {
        let rules = ClaudeApproval.suggestedRules(suggestion())
        #expect(try decision(ClaudeApproval.decisionJSON(.allow, rules: rules))["updatedPermissions"] == nil)
        let deny = try decision(ClaudeApproval.decisionJSON(.deny, rules: rules))
        #expect(deny["behavior"] as? String == "deny")
        #expect(deny["updatedPermissions"] == nil)
    }

    @Test("คำตอบ always เขียน/อ่านจากไฟล์คำตอบได้")
    func answerRoundTrip() {
        #expect(ClaudeApproval.Answer.always.rawValue == "always")
        #expect(ClaudeApproval.Answer(rawValue: "always") == .always)
    }

    @Test("คำขอที่ hook รุ่นเก่าเขียนไว้ ยังอ่านได้ และไม่มีปุ่มที่ 3")
    func oldRequestFileStillDecodes() throws {
        let old = """
        {"id":"a","pid":1,"session":"s","label":"l","tool":"Bash","detail":"ls",
         "note":"","inputKey":"k","created":1}
        """
        let request = try JSONDecoder().decode(
            ClaudeApproval.Request.self, from: Data(old.utf8))
        #expect(request.savableRules.isEmpty)
        #expect(request.project == nil)
    }

    @Test("ลบกฎ: เอาออกจาก permissions.allow เฉพาะบรรทัดนั้น ของอื่นอยู่ครบ")
    func removeOneRuleOnly() throws {
        let root: [String: Any] = [
            "permissions": ["allow": ["Bash(ls:*)", "Bash(npm run test:*)"], "deny": ["Bash(rm:*)"]],
            "hooks": ["PermissionRequest": "ของระบบอื่น ห้ามหาย"],
        ]
        let out = try #require(ClaudeApproval.settingsRemoving(rule: "Bash(npm run test:*)", from: root))
        let permissions = try #require(out["permissions"] as? [String: Any])
        #expect(permissions["allow"] as? [String] == ["Bash(ls:*)"])
        #expect(permissions["deny"] as? [String] == ["Bash(rm:*)"])
        #expect(out["hooks"] as? [String: String] == ["PermissionRequest": "ของระบบอื่น ห้ามหาย"])
    }

    @Test("ไม่มีกฎนั้นในไฟล์ = ไม่ต้องเขียนไฟล์ใหม่")
    func removeMissingRuleChangesNothing() {
        let root: [String: Any] = ["permissions": ["allow": ["Bash(ls:*)"]]]
        #expect(ClaudeApproval.settingsRemoving(rule: "Bash(npm run test:*)", from: root) == nil)
        #expect(ClaudeApproval.settingsRemoving(rule: "Bash(ls:*)", from: [:]) == nil)
        #expect(ClaudeApproval.settingsRemoving(rule: "Bash(ls:*)", from: ["permissions": [:]]) == nil)
    }

    @Test("กฎที่บันทึกไว้ รู้ว่าอยู่โปรเจกต์ไหน และซ้ำกันไม่ได้")
    func savedRuleIdentity() {
        let a = ClaudeApproval.SavedRule(
            toolName: "Bash", ruleContent: "ls:*", project: "/Users/x/Code101/OverlayLens", added: 1)
        let b = ClaudeApproval.SavedRule(
            toolName: "Bash", ruleContent: "ls:*", project: "/Users/x/Code101/OverlayLens", added: 9)
        let other = ClaudeApproval.SavedRule(
            toolName: "Bash", ruleContent: "ls:*", project: "/Users/x/other", added: 1)
        #expect(a.display == "Bash(ls:*)")
        #expect(a.projectName == "OverlayLens")
        #expect(a.id == b.id)
        #expect(a.id != other.id)
    }

    // Only the project's own settings file — never StampLab's live record,
    // which lives in the real Application Support folder.
    @Test("ลบกฎแล้วไฟล์ settings ของโปรเจกต์ไม่มีกฎนั้น และกฎอื่นอยู่ครบ")
    func removeRuleRewritesProjectSettings() throws {
        let fm = FileManager.default
        let project = fm.temporaryDirectory.appendingPathComponent("stamplab-rules-\(UUID().uuidString)")
        try fm.createDirectory(at: project.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: project) }
        let settings = ClaudeApproval.localSettingsURL(project: project.path)
        let before: [String: Any] = [
            "permissions": ["allow": ["Bash(ls:*)", "Bash(npm run test:*)"], "deny": ["Bash(rm:*)"]],
            "hooks": ["PermissionRequest": "ของระบบอื่น ห้ามหาย"],
        ]
        try JSONSerialization.data(withJSONObject: before).write(to: settings)

        #expect(ClaudeApproval.removeRuleFromSettings("Bash(npm run test:*)", project: project.path))

        let root = try #require(try JSONSerialization.jsonObject(
            with: try Data(contentsOf: settings)) as? [String: Any])
        let permissions = try #require(root["permissions"] as? [String: Any])
        #expect(permissions["allow"] as? [String] == ["Bash(ls:*)"])
        #expect(permissions["deny"] as? [String] == ["Bash(rm:*)"])
        #expect(root["hooks"] as? [String: String] == ["PermissionRequest": "ของระบบอื่น ห้ามหาย"])
    }

    @Test("ไม่มีไฟล์ settings หรือไม่มีกฎนั้น = ไม่เขียนอะไรเลย")
    func removeRuleLeavesUnrelatedFilesAlone() throws {
        let fm = FileManager.default
        let project = fm.temporaryDirectory.appendingPathComponent("stamplab-rules-\(UUID().uuidString)")
        try fm.createDirectory(at: project.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: project) }
        #expect(!ClaudeApproval.removeRuleFromSettings("Bash(ls:*)", project: project.path))
        try JSONSerialization.data(withJSONObject: ["permissions": ["allow": ["Bash(ls:*)"]]])
            .write(to: ClaudeApproval.localSettingsURL(project: project.path))
        #expect(!ClaudeApproval.removeRuleFromSettings("Bash(อื่น:*)", project: project.path))
    }

    /// Claude Code saves a session's rules at the repository root, so a
    /// session started in a subfolder has its settings file one level up.
    @Test("แชตที่รันในโฟลเดอร์ย่อย ลบกฎออกจากไฟล์ตั้งค่าของรากโปรเจกต์")
    func removeRuleReachesRepoRootSettings() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("stamplab-repo-\(UUID().uuidString)")
        let sub = root.appendingPathComponent("App")
        defer { try? fm.removeItem(at: root) }
        for folder in [root.appendingPathComponent(".git"), root.appendingPathComponent(".claude"), sub] {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let settings = root.appendingPathComponent(".claude/settings.local.json")
        try JSONSerialization.data(withJSONObject: [
            "permissions": ["allow": ["Bash(npm run *)", "Bash(ls:*)"]],
        ]).write(to: settings)

        #expect(ClaudeApproval.settingsRoot(project: sub.path).path == root.standardizedFileURL.path)
        #expect(ClaudeApproval.removeRuleFromSettings("Bash(npm run *)", project: sub.path))

        let saved = try #require(try JSONSerialization.jsonObject(
            with: try Data(contentsOf: settings)) as? [String: Any])
        let permissions = try #require(saved["permissions"] as? [String: Any])
        #expect(permissions["allow"] as? [String] == ["Bash(ls:*)"])
    }

    @Test("โฟลเดอร์ที่ไม่ได้อยู่ใน repo ยังใช้ไฟล์ของตัวเองเหมือนเดิม")
    func settingsRootFallsBackToTheFolder() throws {
        let fm = FileManager.default
        let project = fm.temporaryDirectory.appendingPathComponent("stamplab-plain-\(UUID().uuidString)")
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: project) }
        #expect(ClaudeApproval.settingsRoot(project: project.path).path == project.standardizedFileURL.path)
    }
}

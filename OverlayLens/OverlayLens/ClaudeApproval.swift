import Foundation

/// Claude Code permission requests answered from StampLab.
///
/// `approval-hook` (Tools/approval-hook, a PermissionRequest hook) writes one
/// request file per prompt into `folder` and waits for `<id>.answer`. StampLab
/// shows the request with Deny / Allow / Allow always and writes the answer.
/// "Allow always" hands Claude Code's own rule suggestion back to it so it
/// saves the rule and stops asking (see `decisionJSON`). Claude Code's own
/// prompt stays up meanwhile — whichever is answered first wins; a request that
/// was settled in Claude Code is spotted from the session's ambient-hook record
/// and its file is removed, which ends the hook's wait.
///
/// Foundation only: compiled into both the app and the hook.
enum ClaudeApproval {
    static let support = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/StampLab")
    static let folder = support.appendingPathComponent("approvals")
    /// Present = switched off in StampLab settings; the hook then exits at once.
    static let offFlag = support.appendingPathComponent("approvals-off")
    static let sessionsFolder = support.appendingPathComponent("claude-sessions")
    /// Rules saved with "อนุญาตเสมอ", so the menu can list and undo them.
    /// Claude Code owns the rules themselves (in each project's
    /// `.claude/settings.local.json`); this is only StampLab's own record.
    static let rulesURL = support.appendingPathComponent("approval-rules.json")
    static let appBundleID = "com.overlaylens.OverlayLens"
    /// The hook gives up a little before its 120 s hook timeout.
    static let waitSeconds: Double = 110

    /// One permission rule Claude Code offered to save for this request, e.g.
    /// `Bash(npm run test:*)`. Only rules that name what they match: a
    /// suggestion without `ruleContent` covers the whole tool (every Bash
    /// command ever) and is too broad to offer on a card.
    struct Rule: Codable, Equatable, Hashable {
        let toolName: String
        let ruleContent: String

        /// Claude Code's own rule syntax — what lands in the settings file.
        var display: String { "\(toolName)(\(ruleContent))" }
    }

    struct Request: Codable, Equatable, Identifiable {
        let id: String
        /// The hook process; gone = Claude Code stopped waiting.
        let pid: Int32
        /// Safe session id — matches the ambient-hook record file name.
        let session: String
        let label: String
        let tool: String
        /// What exactly would run: the command, file, URL…
        let detail: String
        /// Claude's own one-line description, when it gave one.
        let note: String
        /// `inputKey` of the tool call — ambient-hook records the same key
        /// when that call has run.
        let inputKey: String
        let created: Double
        /// Rules Claude Code suggested saving; empty = no "อนุญาตเสมอ" button.
        /// Optional so a request file written by an older hook still decodes.
        let rules: [Rule]?
        /// Project folder the prompt came from — where Claude Code writes an
        /// accepted rule, and so where undoing it has to remove it.
        let project: String?

        var savableRules: [Rule] { rules ?? [] }
    }

    /// The fields of an ambient-hook session record that tell whether a
    /// prompt has been settled.
    struct SessionSnapshot: Equatable {
        var state: String
        var updated: Double
        var start: Double
        /// `inputKey` of the last tool call that ran (PostToolUse).
        var lastKey: String?

        init(state: String, updated: Double, start: Double, lastKey: String?) {
            self.state = state
            self.updated = updated
            self.start = start
            self.lastKey = lastKey
        }

        init?(record: [String: Any]) {
            guard let state = record["state"] as? String,
                  let updated = record["updated"] as? Double else { return nil }
            self.init(state: state, updated: updated, start: (record["start"] as? Double) ?? 0,
                      lastKey: record["lastKey"] as? String)
        }
    }

    enum Answer: String {
        case allow, deny
        /// Allow, and hand Claude Code the rule to save so it stops asking.
        case always
    }

    static func requestURL(_ id: String) -> URL { folder.appendingPathComponent(id + ".json") }
    static func answerURL(_ id: String) -> URL { folder.appendingPathComponent(id + ".answer") }

    static var isEnabled: Bool { !FileManager.default.fileExists(atPath: offFlag.path) }

    static func setEnabled(_ on: Bool) {
        let fm = FileManager.default
        if on {
            try? fm.removeItem(at: offFlag)
        } else {
            try? fm.createDirectory(at: support, withIntermediateDirectories: true)
            try? Data("ปิดจาก StampLab \(Date())\n".utf8).write(to: offFlag)
        }
    }

    /// Same filter ambient-hook uses for its record file names.
    static func safeSessionID(_ raw: String) -> String {
        let s = raw.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return s.isEmpty ? "unknown" : s
    }

    /// The part of the request a person has to read before allowing it.
    static func summary(tool: String, input: [String: Any]) -> (detail: String, note: String) {
        func str(_ k: String) -> String { (input[k] as? String) ?? "" }
        func clip(_ s: String, _ n: Int) -> String { s.count > n ? String(s.prefix(n - 1)) + "…" : s }
        switch tool {
        case "Bash":
            return (clip(str("command"), 2000), clip(str("description"), 200))
        case "Edit", "MultiEdit", "Write":
            return (str("file_path"), "")
        case "NotebookEdit":
            return (str("notebook_path"), "")
        case "Read":
            return (str("file_path"), "")
        case "WebFetch":
            return (str("url"), clip(str("prompt"), 200))
        case "WebSearch":
            return (str("query"), "")
        default:
            let data = (try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])) ?? Data()
            return (clip(String(decoding: data, as: UTF8.self), 600), "")
        }
    }

    /// Readable tool name: "mcp__claude-in-chrome__navigate" → "claude-in-chrome · navigate".
    static func toolLabel(_ tool: String) -> String {
        guard tool.hasPrefix("mcp__") else { return tool }
        let parts = tool.components(separatedBy: "__").dropFirst().filter { !$0.isEmpty }
        return parts.joined(separator: " · ")
    }

    /// The rules Claude Code offered to save for this prompt, from the
    /// `permission_suggestions` the hook was given. Only `addRules` /
    /// `allow` entries, and only rules that say what they match.
    static func suggestedRules(_ suggestions: Any?) -> [Rule] {
        guard let entries = suggestions as? [[String: Any]] else { return [] }
        var out: [Rule] = []
        for entry in entries
        where entry["type"] as? String == "addRules" && entry["behavior"] as? String == "allow" {
            for raw in (entry["rules"] as? [[String: Any]]) ?? [] {
                guard let tool = raw["toolName"] as? String, !tool.isEmpty,
                      let content = raw["ruleContent"] as? String, !content.isEmpty else { continue }
                let rule = Rule(toolName: tool, ruleContent: content)
                if !out.contains(rule) { out.append(rule) }
            }
        }
        return out
    }

    /// The hook's stdout, per the PermissionRequest decision-control format.
    /// `.always` allows and sends the rules back as a permission update bound
    /// for `localSettings`, so Claude Code writes them into the project's
    /// `.claude/settings.local.json` itself — StampLab never edits that file
    /// to add a rule.
    static func decisionJSON(_ answer: Answer, rules: [Rule] = []) -> Data {
        var decision: [String: Any] = ["behavior": answer == .deny ? "deny" : "allow"]
        switch answer {
        case .deny:
            decision["message"] = "The user denied this from StampLab."
        case .allow:
            break
        case .always where !rules.isEmpty:
            decision["updatedPermissions"] = [[
                "type": "addRules",
                "behavior": "allow",
                "destination": "localSettings",
                "rules": rules.map { ["toolName": $0.toolName, "ruleContent": $0.ruleContent] },
            ]]
        case .always:
            break
        }
        let out: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": decision,
            ],
        ]
        return (try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])) ?? Data()
    }

    /// Identifies one tool call across hooks: PermissionRequest and PostToolUse
    /// get the same tool name and input. FNV-1a over the sorted-key JSON.
    static func inputKey(tool: String, input: [String: Any]) -> String {
        let json = (try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])) ?? Data()
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in Data(tool.utf8) + json {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    /// True once the prompt was settled in Claude Code itself, so the card
    /// goes: that exact call has run (allowed there), the turn ended, or a new
    /// prompt started. Other tools finishing in parallel don't count — they
    /// used to take the card down while it was still waiting.
    static func isSettledElsewhere(requestCreated: Double, inputKey: String, session: SessionSnapshot?) -> Bool {
        guard let session, session.updated > requestCreated else { return false }
        return session.lastKey == inputKey
            || session.state == "done"
            || session.start > requestCreated
    }

    // MARK: - Rules saved with "อนุญาตเสมอ"

    /// One accepted rule, as StampLab remembers it. Claude Code holds the
    /// rule itself; this is the record the menu lists and undoes.
    struct SavedRule: Codable, Equatable, Identifiable {
        let toolName: String
        let ruleContent: String
        /// The project folder, so the undo knows which settings file to edit.
        let project: String
        let added: Double

        var rule: Rule { Rule(toolName: toolName, ruleContent: ruleContent) }
        var display: String { rule.display }
        var projectName: String { (project as NSString).lastPathComponent }
        /// One rule per project: saving it twice is the same entry.
        var id: String { project + "|" + display }
    }

    static func savedRules() -> [SavedRule] {
        guard let data = try? Data(contentsOf: rulesURL),
              let list = try? JSONDecoder().decode([SavedRule].self, from: data) else { return [] }
        return list.sorted { $0.added > $1.added }
    }

    private static func writeSaved(_ list: [SavedRule]) {
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(list) else { return }
        try? data.write(to: rulesURL, options: .atomic)
    }

    /// Called by the hook right after it answers `.always`.
    static func recordSaved(_ rules: [Rule], project: String) {
        guard !rules.isEmpty else { return }
        var list = savedRules()
        let now = Date().timeIntervalSince1970
        for rule in rules {
            let entry = SavedRule(
                toolName: rule.toolName, ruleContent: rule.ruleContent, project: project, added: now)
            list.removeAll { $0.id == entry.id }
            list.append(entry)
        }
        writeSaved(list)
    }

    /// `root` without `rule` in `permissions.allow`; nil when it isn't there.
    /// Only that one entry goes — every other rule and key is left as it was,
    /// since the file holds settings of Claude Code's own too.
    static func settingsRemoving(rule: String, from root: [String: Any]) -> [String: Any]? {
        guard var permissions = root["permissions"] as? [String: Any],
              let allow = permissions["allow"] as? [Any] else { return nil }
        let kept = allow.filter { ($0 as? String) != rule }
        guard kept.count != allow.count else { return nil }
        permissions["allow"] = kept
        var out = root
        out["permissions"] = permissions
        return out
    }

    /// Where Claude Code keeps the local settings in force for a session run
    /// in `project`: the root of the repository the folder belongs to, not the
    /// folder the session started in. A session started in a subfolder saves
    /// its rules one or more levels up, so an undo that only looks at the
    /// folder itself edits a file that isn't the one in force — and the rule
    /// stays allowed. Falls back to the folder when it is in no repository.
    static func settingsRoot(project: String) -> URL {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.standardizedFileURL
        let start = URL(fileURLWithPath: project).standardizedFileURL
        var dir = start
        while true {
            if fm.fileExists(atPath: dir.appendingPathComponent(".git").path) { return dir }
            let parent = dir.deletingLastPathComponent().standardizedFileURL
            if parent.path == dir.path || dir.path == home.path { return start }
            dir = parent
        }
    }

    static func localSettingsURL(project: String) -> URL {
        settingsRoot(project: project).appendingPathComponent(".claude/settings.local.json")
    }

    /// Takes the rule out of the project's `.claude/settings.local.json`,
    /// which is what makes Claude Code ask about that command again. True when
    /// the file was rewritten.
    @discardableResult
    static func removeRuleFromSettings(_ rule: String, project: String) -> Bool {
        let url = localSettingsURL(project: project)
        guard let data = try? Data(contentsOf: url),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let updated = settingsRemoving(rule: rule, from: root),
              let out = try? JSONSerialization.data(
                  withJSONObject: updated, options: [.prettyPrinted, .sortedKeys])
        else { return false }
        return (try? out.write(to: url, options: .atomic)) != nil
    }

    /// Drops the rule from StampLab's record and from the project's settings.
    static func forget(_ entry: SavedRule) {
        var list = savedRules()
        list.removeAll { $0.id == entry.id }
        writeSaved(list)
        removeRuleFromSettings(entry.display, project: entry.project)
    }
}

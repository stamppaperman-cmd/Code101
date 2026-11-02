import Foundation

/// Autopilot: approval-hook answers Claude Code's permission prompts by itself.
///
/// In auto mode Claude's own classifier already approves routine work, so the
/// prompts that still reach the hook are the leftovers. Autopilot answers them
/// at once, no card, no click:
///   read-only (Read/Glob/Grep, read-only shell commands) → allow
///   anything else → deny, telling Claude why and to find another way or
///   report it to the user at the end
///   `maxDenies` denials in a row in one session → deny + interrupt (stop the turn)
/// Outside auto mode every command would reach it, so it stays out of the way
/// (the Allow / Deny cards take over) and warns once per session.
/// Every decision goes to `logURL`.
///
/// Foundation only: compiled into both the app and the hook.
enum ClaudeAutopilot {
    /// Present = autopilot on. Off by default.
    static let onFlag = ClaudeApproval.support.appendingPathComponent("autopilot-on")
    static let stateFolder = ClaudeApproval.support.appendingPathComponent("autopilot")
    static let logURL = ClaudeApproval.support.appendingPathComponent("autopilot.log")
    static let maxDenies = 3

    static var isOn: Bool { FileManager.default.fileExists(atPath: onFlag.path) }

    static func setOn(_ on: Bool) {
        let fm = FileManager.default
        if on {
            try? fm.createDirectory(at: ClaudeApproval.support, withIntermediateDirectories: true)
            try? Data("เปิดจาก StampLab \(Date())\n".utf8).write(to: onFlag)
        } else {
            try? fm.removeItem(at: onFlag)
        }
    }

    // MARK: - Deciding

    enum Verdict: Equatable {
        case allow(String)
        case deny(String)
    }

    static let readTools: Set<String> = ["Read", "Glob", "Grep", "LS", "NotebookRead"]

    static func classify(tool: String, input: [String: Any]) -> Verdict {
        if readTools.contains(tool) { return .allow("อ่านอย่างเดียว") }
        switch tool {
        case "Bash":
            let command = (input["command"] as? String) ?? ""
            return isReadOnly(command)
                ? .allow("คำสั่งอ่านอย่างเดียว")
                : .deny("คำสั่งนี้ไม่ใช่การอ่านอย่างเดียว และ auto mode ยังส่งมาถามผู้ใช้")
        case "Edit", "MultiEdit", "Write", "NotebookEdit":
            return .deny("เป็นการเขียนไฟล์ที่ระบบป้องกันไว้ หรืออยู่นอกโฟลเดอร์งาน")
        default:
            return .deny("เครื่องมือนี้ไม่อยู่ในรายการที่ออโต้ไพลอตอนุญาตได้เอง")
        }
    }

    // MARK: - Read-only shell commands (conservative: anything unknown = no)

    static let readOnlyCommands: Set<String> = [
        "ls", "cat", "head", "tail", "wc", "pwd", "echo", "printf", "grep", "egrep", "fgrep", "rg",
        "tree", "stat", "file", "du", "df", "which", "whoami", "date", "uname", "basename",
        "dirname", "realpath", "readlink", "sort", "uniq", "cut", "tr", "diff", "cmp", "nl",
        "true", "false", "test", "[", "cd", "type", "jq", "column", "md5", "md5sum", "shasum",
        "sha256sum", "xxd", "hexdump", "otool", "codesign", "defaults", "plutil", "sw_vers", "id", "find",
    ]
    static let gitRead: Set<String> = [
        "status", "log", "diff", "show", "rev-parse", "ls-files", "blame", "describe",
        "shortlog", "grep", "reflog", "cat-file", "ls-tree", "merge-base",
    ]
    /// Flags that turn an otherwise read-only command into a writer.
    static let writeFlags: [String: Set<String>] = [
        "find": ["-delete", "-exec", "-execdir", "-ok", "-okdir", "-fprint", "-fprint0", "-fprintf", "-fls"],
        "defaults": ["write", "delete", "import", "rename"],
        "codesign": ["-s", "--sign", "--remove-signature", "-f", "--force"],
        "plutil": ["-convert", "-insert", "-replace", "-remove", "-o"],
        "sort": ["-o", "--output"],
    ]

    static func isReadOnly(_ command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !["$(", "`", "<(", ">("].contains(where: { trimmed.contains($0) }),
              let parsed = parse(trimmed), !parsed.writesFile, !parsed.segments.isEmpty
        else { return false }
        for raw in parsed.segments {
            var seg = raw
            while let first = seg.first, first.range(of: #"^[A-Za-z_][A-Za-z0-9_]*="#, options: .regularExpression) != nil {
                seg.removeFirst()
            }
            guard let first = seg.first else { continue }
            let name = (first as NSString).lastPathComponent
            let args = Array(seg.dropFirst())
            if name == "git" {
                let sub = args.first { !$0.hasPrefix("-") } ?? ""
                if sub == "branch" {
                    let rest = args.drop { $0 != sub }.dropFirst()
                    if rest.contains(where: { !$0.hasPrefix("-") || ["-d", "-D", "-m", "-M", "-c", "-C", "--delete", "--move"].contains($0) }) {
                        return false
                    }
                    continue
                }
                if sub == "config" {
                    if !args.contains(where: { ["--get", "--list", "-l", "--get-all"].contains($0) }) { return false }
                    continue
                }
                if !gitRead.contains(sub) { return false }
                continue
            }
            guard readOnlyCommands.contains(name) else { return false }
            if !Set(args).isDisjoint(with: writeFlags[name] ?? []) { return false }
        }
        return true
    }

    /// Splits a shell command into simple commands (words, quotes removed).
    /// `writesFile`: an output redirect to anything but /dev/null.
    /// nil = unbalanced quotes, can't tell.
    static func parse(_ command: String) -> (segments: [[String]], writesFile: Bool)? {
        var segments: [[String]] = [[]]
        var word = ""
        var inWord = false
        var writes = false
        /// Next word is a redirect target: "out" = file written, "in" = read.
        var pending: String? = nil
        let chars = Array(command)
        var i = 0

        func flush() {
            guard inWord else { return }
            switch pending {
            case "out": if word != "/dev/null" { writes = true }
            case "in": break
            default: segments[segments.count - 1].append(word)
            }
            pending = nil
            word = ""
            inWord = false
        }
        func endSegment() {
            flush()
            if !(segments.last?.isEmpty ?? true) { segments.append([]) }
        }

        while i < chars.count {
            let c = chars[i]
            switch c {
            case "'":
                guard let close = chars[(i + 1)...].firstIndex(of: "'") else { return nil }
                word += String(chars[(i + 1)..<close])
                inWord = true
                i = close
            case "\"":
                var j = i + 1
                var closed = false
                while j < chars.count {
                    if chars[j] == "\\", j + 1 < chars.count { word.append(chars[j + 1]); j += 2; continue }
                    if chars[j] == "\"" { closed = true; break }
                    word.append(chars[j])
                    j += 1
                }
                guard closed else { return nil }
                inWord = true
                i = j
            case "\\":
                if i + 1 < chars.count {
                    if chars[i + 1] != "\n" { word.append(chars[i + 1]); inWord = true }
                    i += 1
                }
            case " ", "\t":
                flush()
            case ">":
                // "2>file": the fd number is not a word.
                if inWord, word.allSatisfy(\.isNumber), pending == nil { word = ""; inWord = false } else { flush() }
                var j = i + 1
                if j < chars.count, chars[j] == ">" || chars[j] == "|" { j += 1 }
                if j < chars.count, chars[j] == "&" {
                    // ">&2" duplicates a descriptor; ">&file" writes a file.
                    var k = j + 1
                    while k < chars.count, chars[k].isNumber { k += 1 }
                    if k > j + 1 || (k < chars.count && chars[k] == "-") {
                        i = (k < chars.count && chars[k] == "-") ? k : k - 1
                        break
                    }
                    j += 1
                }
                pending = "out"
                i = j - 1
            case "<":
                flush()
                var j = i + 1
                while j < chars.count, chars[j] == "<" || chars[j] == "&" { j += 1 }
                pending = "in"
                i = j - 1
            case "&":
                if i + 1 < chars.count, chars[i + 1] == ">" {
                    flush()  // "&>file" = stdout and stderr to file
                } else {
                    endSegment()
                }
            case ";", "|", "(", ")", "\n":
                endSegment()
            default:
                word.append(c)
                inWord = true
            }
            i += 1
        }
        flush()
        if pending == "out" { writes = true }  // "> " with no target: be safe
        return (segments.filter { !$0.isEmpty }, writes)
    }

    // MARK: - Per-session state: consecutive denials, mode warning

    struct SessionState: Codable, Equatable {
        var denies = 0
        var warnedMode = false
    }

    static func stateURL(_ session: String) -> URL { stateFolder.appendingPathComponent(session + ".json") }

    static func loadState(_ session: String) -> SessionState {
        guard let data = try? Data(contentsOf: stateURL(session)),
              let state = try? JSONDecoder().decode(SessionState.self, from: data) else { return SessionState() }
        return state
    }

    static func saveState(_ state: SessionState, _ session: String) {
        try? FileManager.default.createDirectory(at: stateFolder, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(state) { try? data.write(to: stateURL(session), options: .atomic) }
    }

    /// Counts one more decision. Returns whether this deny should stop the
    /// turn; the counter starts over after an allow or an interrupt.
    static func record(_ verdict: Verdict, state: inout SessionState) -> Bool {
        guard case .deny = verdict else { state.denies = 0; return false }
        state.denies += 1
        if state.denies >= maxDenies {
            state.denies = 0
            return true
        }
        return false
    }

    // MARK: - Output

    static func describe(tool: String, input: [String: Any]) -> String {
        let raw = ["command", "file_path", "url", "pattern"].lazy
            .compactMap { input[$0] as? String }.first { !$0.isEmpty } ?? ""
        let detail = raw.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        let clipped = detail.count > 120 ? String(detail.prefix(119)) + "…" : detail
        return clipped.isEmpty ? ClaudeApproval.toolLabel(tool) : "\(ClaudeApproval.toolLabel(tool)): \(clipped)"
    }

    static func denyMessage(shown: String, why: String) -> String {
        "ออโต้ไพลอตของ StampLab ปฏิเสธอัตโนมัติ (\(shown)): \(why) ห้ามอ้อมด้วยคำสั่งหรือเครื่องมืออื่น "
            + "ให้หาทางทำงานต่อโดยไม่ต้องใช้สิ่งนี้ ถ้าจำเป็นจริง ให้จดไว้แล้วรายงานผู้ใช้ตอนจบงานว่าผู้ใช้ต้องทำอะไรเอง"
    }

    static func interruptNotice() -> String {
        "ออโต้ไพลอตปฏิเสธติดกัน \(maxDenies) ครั้ง จึงหยุดงานไว้ให้คุณดู (ประวัติ: \(logURL.path))"
    }

    /// The hook's stdout, per the PermissionRequest decision-control format.
    static func decisionJSON(_ verdict: Verdict, shown: String, interrupt: Bool) -> Data {
        var decision: [String: Any]
        switch verdict {
        case .allow:
            decision = ["behavior": "allow"]
        case .deny(let why):
            decision = ["behavior": "deny", "message": denyMessage(shown: shown, why: why)]
            if interrupt { decision["interrupt"] = true }
        }
        var out: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": decision,
            ],
        ]
        if interrupt { out["systemMessage"] = interruptNotice() }
        return (try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])) ?? Data()
    }

    static func logLine(date: Date, result: String, shown: String, why: String, cwd: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return "\(f.string(from: date))  \(result.padding(toLength: 9, withPad: " ", startingAt: 0))  \(shown)  — \(why)  (cwd=\(cwd))\n"
    }

    static func log(result: String, shown: String, why: String, cwd: String) {
        let line = Data(logLine(date: Date(), result: result, shown: shown, why: why, cwd: cwd).utf8)
        try? FileManager.default.createDirectory(at: ClaudeApproval.support, withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        } else {
            try? line.write(to: logURL)
        }
    }
}

import Foundation

/// One row of the Finish Engine Project Tracker in Notion.
/// Foundation only (like everything in this file) so the rules below run in
/// `swift test --package-path Tests` without a window or Notion.
struct FinishEngineTask: Identifiable, Equatable, Codable {
    let id: String
    let task: String
    let project: String
    /// Todo / Doing / Done / Cut. `var` so ✓ can flip it before Notion answers.
    var status: String
    let tier: String
    let weight: Double
    /// Tracker.Blocker — in practice the latest progress note, not a problem.
    var blocker: String
    /// Tracker.DoD — copied into the ทำต่อ handoff so any AI knows the finish line.
    var dod: String = ""
    /// Which AI last pressed ทำต่อ on this task (Tracker.Holder) and when
    /// (Tracker."Held At"). Used to warn before a second AI picks it up.
    var holder: String? = nil
    var heldAt: Date? = nil
    /// Notion's last_edited_time: orders open work and dates a project's last
    /// activity (for "นิ่ง N วัน").
    var lastEdited: Date? = nil
}

struct FinishEngineProject: Identifiable, Equatable {
    var id: String { name }
    /// The Tracker's Project select value — what Notion and status.json use.
    let name: String
    var ai: FinishEngineAI
    /// Widget Display row for this project (nil when the project has no row).
    let displayPageID: String?
    /// Weighted MVP % / FULL %, synced to Widget Display for other tools.
    let mvp: Int
    let full: Int
    /// Open tasks in work order: Doing before Todo, MVP before LATER, most
    /// recently edited first. The first one is "ขั้นต่อไป".
    var remaining: [FinishEngineTask]
    let doneWeight: Double
    let mvpWeight: Double
    /// Title of the next open task ("" when nothing is open).
    let next: String
    /// Latest Done task titles (newest last) for the ทำต่อ handoff.
    var recentDone: [String] = []
    /// "เสร็จ 6 จาก 8": counted over MVP tasks when the project has any,
    /// otherwise over every task that wasn't cut.
    var doneCount: Int = 0
    var totalCount: Int = 0
    var lastActivity: Date? = nil

    var displayName: String { FinishEngineBoard.displayName(name) }
    var nextTask: FinishEngineTask? { remaining.first }
    /// Every task is Done (and there was at least one).
    var isComplete: Bool { remaining.isEmpty && totalCount > 0 }

    /// Days without an edit while work is still open; nil when not stale.
    func staleDays(now: Date = Date()) -> Int? {
        guard !remaining.isEmpty, let lastActivity else { return nil }
        let idle = now.timeIntervalSince(lastActivity)
        guard idle > FinishEngineBoard.staleAfter else { return nil }
        return Int(idle / 86_400)
    }
}

/// A project archived via 📦 (Widget Display.เสร็จแล้ว = YES). Only the old
/// floating panel used it; kept so that file still builds.
struct FinishEngineArchived: Identifiable, Equatable {
    var id: String { name }
    let name: String
    let mvp: Int
}

/// Add a case here (plus its routing in continueInChat) and the same option
/// in Widget Display.AI to offer another AI in the picker.
enum FinishEngineAI: String, CaseIterable, Codable {
    case claude = "Claude"
    /// Chat in the installed ChatGPT app.
    case chatgpt = "ChatGPT"
    /// Codex thread in the ChatGPT app (codex:// link) — works on local files.
    case codex = "Codex"
    /// Backup when Claude/ChatGPT tokens run out — Gemini on the web
    /// (no Notion access, so the handoff asks for PENDING WRITES).
    case gemini = "Gemini"

    /// Widget Display.AI value → case. Legacy "GPT" meant the codex:// route.
    init?(notion raw: String) {
        if raw == "GPT" { self = .codex } else { self.init(rawValue: raw) }
    }

    static func fallback(for project: String) -> Self {
        project == "AI OS" ? .codex : .claude
    }

    var host: String {
        switch self {
        case .claude: return "claude.ai"
        case .gemini: return "gemini.google.com"
        case .chatgpt, .codex: return "chatgpt.com"
        }
    }

    /// Only Claude has the Notion connector; others must hand writes back.
    var writesNotion: Bool { self == .claude }

    /// Keys tried in links-by-ai.json (older files only have "GPT").
    var linkKeys: [String] {
        switch self {
        case .claude: return ["Claude"]
        case .chatgpt: return ["ChatGPT", "GPT"]
        case .codex: return ["Codex", "GPT"]
        case .gemini: return ["Gemini"]
        }
    }

    /// Rule of thumb from the task title: code / files on this Mac → Codex,
    /// Notion or multi-tool chores → Claude, thinking & writing → ChatGPT.
    /// nil = no clear signal (the card's AI is used).
    static func suggested(for title: String) -> Self? {
        let t = title.lowercased()
        func has(_ words: [String]) -> Bool { words.contains { t.contains($0) } }
        if has(["codex", "โค้ด", "code", "build", "deploy", "swift", "xcode", "script",
                "สคริปต์", "overlaylens", "ui", "ux", "ปุ่ม", "หน้าต่าง", "widget",
                "แอป", "การ์ด", "เมนู"]) { return .codex }
        if has(["claude", "notion", "tracker", "connector", "drive", "calendar",
                "gmail", "slack", "ปิดงาน", "ผู้ถืองาน", "กัน ai", "หลายเครื่องมือ"]) { return .claude }
        if has(["chatgpt", "gpt", "คำสั่ง", "instruction", "prompt", "เขียน", "สรุป",
                "วางแผน", "คิด", "ใช้ ", "ใช้v", "evolve"]) { return .chatgpt }
        return nil
    }
}

/// ทำต่อ with Claude opens a Claude Code session in the project's folder
/// (files, tests, hooks, autopilot) instead of a plain chat.
/// ~/.finish-engine/folders.json maps project → folder; "_default" covers the
/// rest. No usable folder → nil, and the caller falls back to the chat link.
enum FinishEngineCodeLink {
    static func folder(for project: String, map: [String: String], home: String,
                       isDirectory: (String) -> Bool) -> String? {
        for key in [project, "_default"] {
            guard var raw = map[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else { continue }
            if raw == "~" { raw = home } else if raw.hasPrefix("~/") { raw = home + raw.dropFirst(1) }
            if raw.hasPrefix("/"), isDirectory(raw) { return raw }
        }
        return nil
    }

    /// Same link as the desktop app's own "New Claude Code Session Here"
    /// Finder service. Only ASCII letters, digits and /-._~ stay as they are,
    /// so spaces, Thai names, & and = survive the trip.
    static func url(folder: String) -> URL? {
        let safe = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789/-._~")
        guard let encoded = folder.addingPercentEncoding(withAllowedCharacters: safe) else { return nil }
        return URL(string: "claude://code/new?folder=\(encoded)&source=finish_engine")
    }
}

/// The rules behind the Finish Engine box: which projects exist, what's next
/// in each, how far along they are, and which one the user is probably
/// looking at. No AppKit, no network — FinishEngineModel feeds it Notion rows.
enum FinishEngineBoard {
    /// Open work with no edit for longer than this shows "นิ่ง N วัน".
    static let staleAfter: TimeInterval = 7 * 86_400

    /// Notion keeps the old name; the box shows the name the user says.
    /// Display only — search and the guess match both.
    static let aliases = ["OverlayLens": "StampLab"]

    static func displayName(_ name: String) -> String { aliases[name] ?? name }

    // MARK: Projects

    /// Every project in `names` (the Tracker's Project options, so one with
    /// no tasks yet still shows) plus any project a task names, sorted for
    /// the list. `ai` holds explicit picks; otherwise the AI holding the next
    /// task, otherwise the old per-project default.
    static func build(tasks: [FinishEngineTask], names: [String],
                      ai: [String: FinishEngineAI] = [:],
                      pageIDs: [String: String] = [:]) -> [FinishEngineProject] {
        var all: [String] = []
        for name in names + tasks.map(\.project) where !name.isEmpty && !all.contains(name) {
            all.append(name)
        }
        return sorted(all.map { name in
            project(named: name, tasks: tasks, ai: ai[name], pageID: pageIDs[name])
        })
    }

    static func project(named name: String, tasks all: [FinishEngineTask],
                        ai picked: FinishEngineAI? = nil, pageID: String? = nil) -> FinishEngineProject {
        let everything = all.filter { $0.project == name }
        let mine = everything.filter { $0.status != "Cut" }
        let mvpSet = mine.filter { $0.tier == "MVP" }
        func sum(_ xs: [FinishEngineTask]) -> Double { xs.reduce(0) { $0 + $1.weight } }
        func pct(_ done: [FinishEngineTask], _ all: [FinishEngineTask]) -> Int {
            sum(all) > 0 ? Int((sum(done) / sum(all) * 100).rounded()) : 0
        }
        let mvpDone = mvpSet.filter { $0.status == "Done" }
        let open = ordered(mine.filter { $0.status != "Done" })
        let counted = mvpSet.isEmpty ? mine : mvpSet
        let holderAI = open.first?.holder.flatMap { FinishEngineAI(notion: $0) }
        return FinishEngineProject(
            name: name,
            ai: picked ?? holderAI ?? .fallback(for: name),
            displayPageID: pageID,
            mvp: pct(mvpDone, mvpSet),
            full: pct(mine.filter { $0.status == "Done" }, mine),
            remaining: open,
            doneWeight: sum(mvpDone),
            mvpWeight: sum(mvpSet),
            next: open.first?.task ?? "",
            recentDone: Array(mine.filter { $0.status == "Done" }.suffix(3).map(\.task)),
            doneCount: counted.filter { $0.status == "Done" }.count,
            totalCount: counted.count,
            lastActivity: everything.compactMap(\.lastEdited).max()
        )
    }

    /// Doing before Todo, MVP before LATER, most recently edited first;
    /// ties keep tracker order (Notion edit times are only minute-precise).
    static func ordered(_ open: [FinishEngineTask]) -> [FinishEngineTask] {
        func rank(_ t: FinishEngineTask) -> Int {
            (t.status == "Doing" ? 0 : 2) + (t.tier == "MVP" ? 0 : 1)
        }
        return open.enumerated().sorted { a, b in
            let (ra, rb) = (rank(a.element), rank(b.element))
            if ra != rb { return ra < rb }
            let (da, db) = (a.element.lastEdited ?? .distantPast, b.element.lastEdited ?? .distantPast)
            if da != db { return da > db }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// Projects with open work, most recently touched first; then finished
    /// and empty ones by name.
    static func sorted(_ projects: [FinishEngineProject]) -> [FinishEngineProject] {
        func byName(_ a: FinishEngineProject, _ b: FinishEngineProject) -> Bool {
            a.displayName.localizedStandardCompare(b.displayName) == .orderedAscending
        }
        let active = projects.filter { !$0.remaining.isEmpty }.sorted { a, b in
            let (da, db) = (a.lastActivity ?? .distantPast, b.lastActivity ?? .distantPast)
            return da != db ? da > db : byName(a, b)
        }
        return active + projects.filter { $0.remaining.isEmpty }.sorted(by: byName)
    }

    // MARK: Search and create

    static func names(of project: FinishEngineProject) -> [String] {
        project.displayName == project.name ? [project.name] : [project.displayName, project.name]
    }

    /// Case-insensitive on purpose but not diacritic-insensitive: that would
    /// drop Thai tone marks and match the wrong words.
    static func filter(_ projects: [FinishEngineProject], query: String) -> [FinishEngineProject] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return projects }
        return projects.filter { p in
            names(of: p).contains { $0.range(of: q, options: .caseInsensitive) != nil }
        }
    }

    static func hasExactName(_ projects: [FinishEngineProject], _ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return projects.contains { p in
            names(of: p).contains { $0.compare(q, options: .caseInsensitive) == .orderedSame }
        }
    }

    /// Why `name` can't become a new project, or nil when it can. Notion
    /// select options can't hold commas and stop at 100 characters.
    static func problem(withNewName name: String, existing: [FinishEngineProject]) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "พิมพ์ชื่อโปรเจกต์ในช่องด้านบน" }
        if trimmed.contains(",") { return "ชื่อโปรเจกต์ใส่เครื่องหมาย , ไม่ได้ (ข้อจำกัดของ Notion)" }
        if trimmed.count > 100 { return "ชื่อยาวเกิน 100 ตัวอักษร" }
        if hasExactName(existing, trimmed) { return "มีโปรเจกต์ชื่อนี้แล้ว" }
        return nil
    }

    // MARK: Guessing the current project

    /// The project named earliest in `text` (a chat or window title); a tie
    /// goes to the longer name. Matches display and Notion names.
    static func guess(in text: String, among projects: [FinishEngineProject]) -> FinishEngineProject? {
        var best: (offset: Int, length: Int, project: FinishEngineProject)?
        for project in projects {
            for name in names(of: project) where !name.isEmpty {
                guard let range = text.range(of: name, options: .caseInsensitive) else { continue }
                let offset = text.distance(from: text.startIndex, to: range.lowerBound)
                if let current = best,
                   offset > current.offset || (offset == current.offset && name.count <= current.length) {
                    continue
                }
                best = (offset, name.count, project)
            }
        }
        return best?.project
    }

    /// The chat title from the end of a Claude Code transcript: the last
    /// `"type":"custom-title"` line carries `customTitle`. Only the tail is
    /// read (transcripts reach tens of MB), so a cut-off first line is skipped.
    static func customTitle(inTranscriptTail data: Data) -> String? {
        let marker = Data(#""type":"custom-title""#.utf8)
        var end = data.endIndex
        while let found = data.range(of: marker, options: .backwards, in: data.startIndex..<end) {
            let lineStart = data[data.startIndex..<found.lowerBound].lastIndex(of: 0x0A).map { $0 + 1 } ?? data.startIndex
            let lineEnd = data[found.upperBound..<data.endIndex].firstIndex(of: 0x0A) ?? data.endIndex
            if let line = try? JSONSerialization.jsonObject(with: data.subdata(in: lineStart..<lineEnd)) as? [String: Any],
               line["type"] as? String == "custom-title",
               let title = (line["customTitle"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !title.isEmpty {
                return title
            }
            end = found.lowerBound
        }
        return nil
    }

    // MARK: Small helpers

    /// Palette slot that stays the same across launches (`hashValue` is
    /// reseeded every launch, so it can't be used): FNV-1a over the UTF-8.
    static func colorIndex(for name: String, paletteCount: Int) -> Int {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in name.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return Int(hash % UInt64(max(paletteCount, 1)))
    }

    /// Cuts on whole characters, so Thai vowels and tone marks stay attached.
    static func shortened(_ text: String, to limit: Int) -> String {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count > limit, limit > 1 else { return clean }
        return String(clean.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Copied by "ให้ AI วางแผนขั้นแรก" for a project with nothing open. Line 1
    /// alone becomes the new chat's title (and contains the project name, so
    /// the next ⌃⌥⌘F can guess it from that chat).
    static func planningPrompt(for project: FinishEngineProject, idea: String? = nil) -> String {
        let label = project.displayName == project.name
            ? project.name
            : "\(project.displayName) (ใน Notion ชื่อ \(project.name))"
        var lines: [String] = []
        if project.isComplete {
            lines.append("วางแผนขั้นต่อไป: \(project.displayName)")
            lines.append("โปรเจกต์ \(label) ทำครบทุกขั้นใน Finish Engine แล้ว")
            if !project.recentDone.isEmpty {
                lines.append("ทำไปแล้ว (Done ล่าสุด): " + project.recentDone.joined(separator: " · "))
            }
            lines.append("ช่วยเสนอ 3–5 ขั้นต่อไปที่ทำให้โปรเจกต์นี้ดีขึ้นจริง เรียงตามลำดับ แต่ละขั้นมี DoD (เกณฑ์เสร็จที่ตรวจได้) หนึ่งประโยค")
        } else {
            lines.append("วางแผนขั้นแรก: \(project.displayName)")
            lines.append("โปรเจกต์ใหม่ใน Finish Engine: \(label) ยังไม่มีขั้นตอน")
            if let idea = idea?.trimmingCharacters(in: .whitespacesAndNewlines), !idea.isEmpty {
                lines.append("ขั้นแรกที่คิดไว้: \(idea)")
            }
            lines.append("ช่วยแบ่งเป็น 3–5 ขั้นแรกที่ทำได้จริง เรียงตามลำดับ แต่ละขั้นมี DoD (เกณฑ์เสร็จที่ตรวจได้) หนึ่งประโยค")
        }
        lines.append("แล้วบันทึกลง Finish Engine (Notion: Project Tracker) ทีละขั้น: Task = ชื่อขั้น, Project = \(project.name), Status = Todo, Tier = MVP, Weight = 1–3 ตามขนาดงาน, DoD = เกณฑ์เสร็จ")
        if !project.ai.writesNotion {
            lines.append("ถ้าเขียน Notion ไม่ได้ ให้จบคำตอบด้วยตาราง PENDING WRITES (DB | Task | Field | New value)")
        }
        lines.append("ถ้าข้อมูลไม่พอให้ถามสั้น ๆ ก่อน แล้วลงมือในแชทนี้เลย ไม่ต้องส่งไปแชทอื่น")
        return lines.joined(separator: "\n")
    }
}

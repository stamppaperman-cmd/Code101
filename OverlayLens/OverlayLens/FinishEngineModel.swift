import AppKit
import Foundation

/// Mirror of the Finish Engine Notion workspace (Project Tracker + Pain Log).
/// Lists every project in the Tracker — including Project options with no
/// tasks yet, so a project made in the box shows straight away — with its
/// open work in order (rules in FinishEngineBoard). Widget Display only
/// supplies each project's AI and receives the weighted MVP %/FULL % that
/// other tools read; ~/.finish-engine/status.json gets every project with
/// open work.
@MainActor
final class FinishEngineModel: ObservableObject {
    @Published private(set) var projects: [FinishEngineProject] = []
    /// Projects ticked เสร็จแล้ว in Widget Display (only the old panel showed them).
    @Published private(set) var archived: [FinishEngineArchived] = []
    @Published private(set) var painsOpen: Int?
    /// Open (not Fixed) Pain Log rows per project.
    @Published private(set) var painsByProject: [String: Int] = [:]
    @Published private(set) var errorCode: String?
    @Published private(set) var lastSync: Date?
    @Published private(set) var isLoading = false

    /// UserDefaults: the project last picked in the box (reopen + menu row).
    static let selectedKey = "FinishEngineSelected"
    /// UserDefaults: AI picks for projects without a Widget Display row.
    private static let localAIKey = "FinishEngineLocalAI"

    private static let trackerID = "05acc1d9-892a-47a5-80dd-32cfc2208e2f"
    private static let painLogID = "a8e8cdba-5b27-430e-8786-d693c14987e6"
    /// Widget Display: one row per project — Project (title), Show and
    /// เสร็จแล้ว (checkboxes), Order, AI, MVP %, and FULL %.
    private static let displayID = "60dca0b9-524a-435d-9633-888a8788cb0a"
    private static let folder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".finish-engine")
    /// Last good sync, so a fresh launch shows projects before Notion answers.
    private static let cacheURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("StampLab", isDirectory: true)
        .appendingPathComponent("finish-engine.json")
    /// Always on, box open or not, so the menu row and status.json stay fresh.
    private static let refreshInterval: TimeInterval = 10 * 60
    /// Opening the box re-syncs only when the last sync is older than this.
    static let freshFor: TimeInterval = 60

    private var timer: Timer?

    // `projects` is always derived from these (see rebuild()).
    private var tasks: [FinishEngineTask] = []
    /// The Tracker's Project select options, in Notion's order.
    private var projectNames: [String] = []
    private var displayCache: [DisplayProject]?
    private var localAI: [String: FinishEngineAI] = [:]

    /// Writes Notion hasn't confirmed by a later refresh: a refresh that
    /// started before a write settled must not flip the screen back.
    private struct Pending<Value> {
        var value: Value
        let generation: Int
        var settledAt: Date?
    }
    private var pendingAI: [String: Pending<FinishEngineAI>] = [:]
    private var pendingStatus: [String: Pending<String>] = [:]
    /// 📦 archive / restore from the old panel (project → wanted เสร็จแล้ว).
    private var pendingFinished: [String: Bool] = [:]
    /// Projects created here, until a refresh that started later lists them.
    private var createdAt: [String: Date] = [:]
    private var writeGeneration = 0
    /// Status writes run one after another, so an undo can't overtake the
    /// Done it undoes.
    private var statusWrites: Task<Void, Never>?

    init() {
        let saved = UserDefaults.standard.dictionary(forKey: Self.localAIKey) as? [String: String] ?? [:]
        localAI = saved.compactMapValues { FinishEngineAI(rawValue: $0) }
        loadCache()
    }

    func start() {
        refresh()
        timer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer.tolerance = 30
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Opening the box shows the cache at once and re-syncs in the background
    /// only when it's more than a minute old.
    func refreshIfStale() {
        if let lastSync, Date().timeIntervalSince(lastSync) < Self.freshFor { return }
        refresh()
    }

    func refresh() {
        guard !isLoading else { return }
        isLoading = true
        let started = Date()
        Task {
            defer { isLoading = false }
            do {
                let token = try Self.readToken()
                async let taskRows = Self.queryAll(Self.trackerID, token: token)
                async let painRows = Self.queryAll(Self.painLogID, token: token)
                async let display = Self.displayList(token: token)
                async let options = Self.projectOptions(token: token)
                let (rows, pains, displayRows, names) = try await (taskRows, painRows, display, options)

                tasks = rows.map(Self.task(from:)).map { task in
                    var task = task
                    if let pending = pendingStatus[task.id] {
                        if let settled = pending.settledAt, settled < started {
                            pendingStatus[task.id] = nil
                        } else {
                            task.status = pending.value
                        }
                    }
                    return task
                }
                if var names {
                    for (name, created) in createdAt {
                        if names.contains(name) || created < started {
                            createdAt[name] = nil
                        } else {
                            names.append(name)
                        }
                    }
                    projectNames = names
                }
                var merged = displayRows
                if merged != nil {
                    for index in merged!.indices {
                        let name = merged![index].name
                        if let pending = pendingAI[name],
                           pending.value == merged![index].ai || (pending.settledAt.map { $0 < started } ?? false) {
                            pendingAI[name] = nil
                        }
                        guard let wanted = pendingFinished[name] else { continue }
                        if merged![index].finished == wanted {
                            pendingFinished[name] = nil
                        } else {
                            merged![index].finished = wanted
                            if !wanted { merged![index].shown = true }
                        }
                    }
                }
                displayCache = merged
                rebuild()

                let openPains = pains.filter { Self.select($0, "Status") != "Fixed" }
                painsOpen = openPains.count
                painsByProject = Dictionary(grouping: openPains) { Self.select($0, "Project") ?? "" }
                    .mapValues(\.count)
                errorCode = nil
                let now = Date()
                lastSync = now
                writeSnapshot(at: now)
                saveCache()
                if let displayRows {
                    try await Self.syncPercentages(projects, display: displayRows, token: token)
                }
            } catch let error as FinishEngineError {
                // Keep showing the last good numbers underneath the warning.
                errorCode = error.code
            } catch {
                errorCode = "NETWORK"
            }
        }
    }

    /// Recomputes `projects` (and the old 📦 list) from tasks, Project
    /// options, Widget Display and the picks Notion hasn't confirmed yet.
    /// AI: pending pick > Widget Display > local pick > the AI holding the
    /// next task > the old per-project default.
    private func rebuild() {
        var picks = localAI
        var pageIDs: [String: String] = [:]
        for row in displayCache ?? [] {
            picks[row.name] = row.ai
            if let pageID = row.pageID { pageIDs[row.name] = pageID }
        }
        for (name, pending) in pendingAI { picks[name] = pending.value }
        projects = FinishEngineBoard.build(tasks: tasks, names: projectNames, ai: picks, pageIDs: pageIDs)
        archived = (displayCache ?? []).filter(\.finished).map { row in
            FinishEngineArchived(name: row.name, mvp: projects.first { $0.name == row.name }?.mvp ?? 0)
        }
    }

    /// The project the menu row shows: the one last picked in the box while
    /// it still has open work, otherwise the most recently active one.
    func headline(selected: String?) -> FinishEngineProject? {
        if let selected, let picked = projects.first(where: { $0.name == selected }), !picked.remaining.isEmpty {
            return picked
        }
        return projects.first { !$0.remaining.isEmpty } ?? projects.first
    }

    /// 📦 เก็บเข้าคลัง (finished=true) or ดึงกลับ (false) from the old panel:
    /// Widget Display.เสร็จแล้ว (and Show on restore) is written. Reverts and
    /// shows NO_ARCHIVE if Notion refuses.
    func setFinished(_ finished: Bool, for name: String) {
        guard var rows = displayCache,
              let index = rows.firstIndex(where: { $0.name == name }),
              let pageID = rows[index].pageID else {
            errorCode = "NO_DISPLAY_ROW"
            return
        }
        let before = rows[index]
        rows[index].finished = finished
        if !finished { rows[index].shown = true }
        displayCache = rows
        pendingFinished[name] = finished
        rebuild()
        Task {
            do {
                let token = try Self.readToken()
                var props: [String: Any] = ["เสร็จแล้ว": ["checkbox": finished]]
                if !finished { props["Show"] = ["checkbox": true] }
                try await Self.patchPage(pageID, properties: props, token: token)
                errorCode = nil
            } catch {
                pendingFinished[name] = nil
                if var current = displayCache,
                   let i = current.firstIndex(where: { $0.name == name }) {
                    current[i].finished = before.finished
                    current[i].shown = before.shown
                    displayCache = current
                    rebuild()
                }
                errorCode = "NO_ARCHIVE"
            }
        }
    }

    private static func patchPage(_ pageID: String, properties: [String: Any], token: String) async throws {
        var request = URLRequest(url: URL(string: "https://api.notion.com/v1/pages/\(pageID)")!)
        request.httpMethod = "PATCH"
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("2025-09-03", forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["properties": properties])
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FinishEngineError(code: "BAD_OUTPUT")
        }
        if json["object"] as? String == "error" {
            throw FinishEngineError(code: json["code"] as? String ?? "NOTION_ERROR")
        }
    }

    /// AI picker: shows the new AI at once, then writes Widget Display.AI so
    /// ทำต่อ and every other reader follow it. Reverts if Notion refuses.
    /// A project without a Widget Display row (e.g. one made in the box)
    /// keeps the pick on this Mac instead of failing.
    func setAI(_ ai: FinishEngineAI, for name: String) {
        guard let project = projects.first(where: { $0.name == name }), project.ai != ai else { return }
        guard let pageID = project.displayPageID else {
            localAI[name] = ai
            UserDefaults.standard.set(localAI.mapValues(\.rawValue), forKey: Self.localAIKey)
            rebuild()
            return
        }
        writeGeneration += 1
        let generation = writeGeneration
        pendingAI[name] = Pending(value: ai, generation: generation)
        rebuild()
        Task {
            do {
                let token = try Self.readToken()
                try await Self.writeAI(ai, pageID: pageID, token: token)
                if pendingAI[name]?.generation == generation {
                    pendingAI[name]?.settledAt = Date()
                }
                if let i = displayCache?.firstIndex(where: { $0.name == name }) {
                    displayCache?[i].ai = ai
                }
                errorCode = nil
            } catch {
                if pendingAI[name]?.generation == generation {
                    pendingAI[name] = nil
                    rebuild()
                }
                errorCode = (error as? FinishEngineError)?.code ?? "NETWORK"
            }
        }
    }

    private static func writeAI(_ ai: FinishEngineAI, pageID: String, token: String) async throws {
        var request = URLRequest(url: URL(string: "https://api.notion.com/v1/pages/\(pageID)")!)
        request.httpMethod = "PATCH"
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("2025-09-03", forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "properties": ["AI": ["select": ["name": ai.rawValue]]],
        ])
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FinishEngineError(code: "BAD_OUTPUT")
        }
        if json["object"] as? String == "error" {
            let code = json["code"] as? String ?? "NOTION_ERROR"
            throw FinishEngineError(code: code == "restricted_resource" ? "NO_WRITE" : code)
        }
    }

    /// ✓ / ⌘D and its ย้อนกลับ: the change shows at once and the project's
    /// next step moves up; a refused write puts the old status back.
    func setStatus(_ task: FinishEngineTask, to status: String) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        let before = tasks[index]
        guard before.status != status else { return }
        tasks[index].status = status
        tasks[index].lastEdited = Date()
        writeGeneration += 1
        let generation = writeGeneration
        pendingStatus[task.id] = Pending(value: status, generation: generation)
        rebuild()
        let earlier = statusWrites
        statusWrites = Task {
            await earlier?.value
            do {
                let token = try Self.readToken()
                try await Self.patchPage(task.id, properties: ["Status": ["select": ["name": status]]], token: token)
                if pendingStatus[task.id]?.generation == generation {
                    pendingStatus[task.id]?.settledAt = Date()
                }
                writeSnapshot(at: Date())
                saveCache()
            } catch {
                // A newer change to this task (e.g. ย้อนกลับ) owns it now.
                guard pendingStatus[task.id]?.generation == generation else { return }
                pendingStatus[task.id] = nil
                if let i = tasks.firstIndex(where: { $0.id == task.id }) {
                    tasks[i].status = before.status
                    tasks[i].lastEdited = before.lastEdited
                }
                rebuild()
                errorCode = "NO_STATUS"
            }
        }
    }

    /// Result of the box's "สร้าง"; messages are ready to show.
    enum CreateOutcome: Equatable {
        case created
        /// The project exists, but its first step couldn't be saved.
        case stepNotSaved(String)
        case failed(String)
    }

    /// New project = a new option in the Tracker's Project select (so it
    /// lists with no tasks yet), then the optional first step as a Todo ·
    /// MVP · Weight 1 task. Saving the step needs the integration's "Insert
    /// content" capability; without it the project still stays.
    func createProject(name rawName: String, firstStep rawStep: String) async -> CreateOutcome {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let step = rawStep.trimmingCharacters(in: .whitespacesAndNewlines)
        var projectName = name
        if let existing = projects.first(where: { project in
            FinishEngineBoard.names(of: project).contains { $0.compare(name, options: .caseInsensitive) == .orderedSame }
        }) {
            projectName = existing.name
        } else {
            if let problem = FinishEngineBoard.problem(withNewName: name, existing: projects) {
                return .failed(problem)
            }
            do {
                let token = try Self.readToken()
                try await Self.addProjectOption(name, token: token)
            } catch {
                let code = (error as? FinishEngineError)?.code ?? "NETWORK"
                return .failed(Self.message(for: code == "restricted_resource" ? "NO_SCHEMA" : code))
            }
            createdAt[name] = Date()
            if !projectNames.contains(name) { projectNames.append(name) }
            rebuild()
            saveCache()
        }
        guard !step.isEmpty else { return .created }
        if let code = await addTask(step, to: projectName) {
            return .stepNotSaved(Self.message(for: code))
        }
        return .created
    }

    /// Saves a Todo · MVP · Weight 1 task. Returns an error code for
    /// message(for:), or nil once saved.
    func addTask(_ title: String, to project: String) async -> String? {
        do {
            let token = try Self.readToken()
            let page = try await Self.notion("POST", "pages", body: [
                "parent": ["type": "data_source_id", "data_source_id": Self.trackerID],
                "properties": [
                    "Task": ["title": [["text": ["content": title]]]],
                    "Project": ["select": ["name": project]],
                    "Status": ["select": ["name": "Todo"]],
                    "Tier": ["select": ["name": "MVP"]],
                    "Weight": ["number": 1],
                ],
            ], token: token)
            tasks.append(Self.task(from: page))
            rebuild()
            writeSnapshot(at: Date())
            saveCache()
            return nil
        } catch let error as FinishEngineError {
            return error.code == "restricted_resource" ? "NO_INSERT" : error.code
        } catch {
            return "NETWORK"
        }
    }

    /// Adds `name` to the Tracker's Project select. Notion replaces the whole
    /// option list on PATCH, so every existing option (id, name, color) goes
    /// back with the new one — leaving one out would delete it. If the list
    /// can't be read, nothing is sent.
    private static func addProjectOption(_ name: String, token: String) async throws {
        let source = try await notion("GET", "data_sources/\(trackerID)", token: token)
        let options = try projectOptionList(in: source)
        if options.contains(where: { ($0["name"] as? String)?.compare(name, options: .caseInsensitive) == .orderedSame }) {
            return
        }
        let kept: [[String: Any]] = options.map { option in
            var copy: [String: Any] = [:]
            for key in ["id", "name", "color"] { copy[key] = option[key] }
            return copy
        }
        _ = try await notion("PATCH", "data_sources/\(trackerID)", body: [
            "properties": ["Project": ["select": ["options": kept + [["name": name]]]]],
        ], token: token)
    }

    /// The Tracker's Project options in Notion's order; nil when unreadable
    /// (the last known list is kept).
    private static func projectOptions(token: String) async -> [String]? {
        guard let source = try? await notion("GET", "data_sources/\(trackerID)", token: token),
              let options = try? projectOptionList(in: source) else { return nil }
        return options.compactMap { ($0["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func projectOptionList(in source: [String: Any]) throws -> [[String: Any]] {
        guard let props = source["properties"] as? [String: Any],
              let project = props["Project"] as? [String: Any],
              let select = project["select"] as? [String: Any],
              let options = select["options"] as? [[String: Any]] else {
            throw FinishEngineError(code: "BAD_OUTPUT")
        }
        return options
    }

    /// One Notion call; Notion's own error code (e.g. restricted_resource)
    /// is thrown as FinishEngineError.
    private static func notion(_ method: String, _ path: String, body: [String: Any]? = nil,
                               token: String) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://api.notion.com/v1/\(path)")!)
        request.httpMethod = method
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("2025-09-03", forHTTPHeaderField: "Notion-Version")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FinishEngineError(code: "BAD_OUTPUT")
        }
        if json["object"] as? String == "error" {
            throw FinishEngineError(code: json["code"] as? String ?? "NOTION_ERROR")
        }
        return json
    }

    /// Use the exact percentages already calculated for the list. A project
    /// whose work is all done still gets refreshed.
    private static func syncPercentages(_ projects: [FinishEngineProject], display: [DisplayProject], token: String) async throws {
        for project in projects {
            guard let row = display.first(where: { $0.name == project.name }),
                  let pageID = row.pageID else { continue }
            let mvp = Double(project.mvp) / 100
            let full = Double(project.full) / 100
            guard row.mvpPercent == nil || row.fullPercent == nil ||
                    abs(row.mvpPercent! - mvp) > 0.00001 ||
                    abs(row.fullPercent! - full) > 0.00001 else { continue }

            var request = URLRequest(url: URL(string: "https://api.notion.com/v1/pages/\(pageID)")!)
            request.httpMethod = "PATCH"
            request.timeoutInterval = 15
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("2025-09-03", forHTTPHeaderField: "Notion-Version")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "properties": [
                    "MVP %": ["number": mvp],
                    "FULL %": ["number": full],
                ],
            ])
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw FinishEngineError(code: "BAD_OUTPUT")
            }
            if json["object"] as? String == "error" {
                let code = json["code"] as? String ?? "NOTION_ERROR"
                throw FinishEngineError(code: code == "restricted_resource" ? "NO_WRITE" : code)
            }
        }
    }

    // MARK: - Holder (one AI per task)

    /// A different AI pressing ทำต่อ within this window gets a warning first.
    static let holdWindow: TimeInterval = 2 * 60 * 60

    /// ทำต่อ entry point: warns if another AI holds the task (< 2 h), then
    /// opens the chat and claims the task (Status=Doing, Holder, Held At).
    /// A completed task on a stale card is refreshed instead of reopened.
    func claimAndContinue(project: String, ai: FinishEngineAI, task: FinishEngineTask,
                          onContinue: @escaping () -> Void) {
        if task.status == "Done" { refresh(); return }
        let now = Date()
        if let holder = task.holder, holder != ai.rawValue,
           let heldAt = task.heldAt, now.timeIntervalSince(heldAt) < Self.holdWindow {
            let minutes = max(1, Int(now.timeIntervalSince(heldAt) / 60))
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "งานนี้ \(holder) ถืออยู่"
            alert.informativeText = "\(task.task)\n\n\(holder) กด ทำต่อ ไว้เมื่อ \(Self.clock(heldAt)) (\(minutes) นาทีที่แล้ว). ถ้าเปิดด้วย \(ai.rawValue) ตอนนี้ อาจทำซ้ำหรือเขียนทับกัน"
            alert.addButton(withTitle: "ยกเลิก")
            alert.addButton(withTitle: "เปิดด้วย \(ai.rawValue) แทน")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertSecondButtonReturn else { return }
        }

        let context = projects.first(where: { $0.name == project })
        Task {
            // Re-read this task's row first so the handoff never carries a
            // stale Blocker/DoD from the last sync (falls back to the cache).
            var fresh = task
            var canClaim = false
            if let token = try? Self.readToken(),
               let page = try? await Self.fetchPage(task.id, token: token) {
                if Self.select(page, "Status") == "Done" {
                    self.refresh()
                    return
                }
                canClaim = true
                fresh.blocker = Self.text(page, "Blocker")
                fresh.dod = Self.text(page, "DoD")
                if let i = self.tasks.firstIndex(where: { $0.id == task.id }) {
                    self.tasks[i].blocker = fresh.blocker
                    self.tasks[i].dod = fresh.dod
                    self.tasks[i].holder = ai.rawValue
                    self.tasks[i].heldAt = now
                    self.tasks[i].status = "Doing"
                    self.tasks[i].lastEdited = now
                    self.rebuild()
                }
            }
            Self.continueInChat(project: project, ai: ai, task: fresh, context: context)
            onContinue()
            guard canClaim else { errorCode = "NO_FRESH_STATUS"; return }
            do {
                let token = try Self.readToken()
                try await Self.writeClaim(ai, at: now, pageID: task.id, token: token)
            } catch {
                errorCode = "NO_CLAIM"
            }
        }
    }

    /// One page from Notion with a short timeout (ทำต่อ waits on it).
    private static func fetchPage(_ pageID: String, token: String) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://api.notion.com/v1/pages/\(pageID)")!)
        request.timeoutInterval = 3
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("2025-09-03", forHTTPHeaderField: "Notion-Version")
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["object"] as? String == "page" else {
            throw FinishEngineError(code: "BAD_OUTPUT")
        }
        return json
    }

    static func clock(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "d/M HH:mm"
        return f.string(from: date)
    }

    private static func writeClaim(_ ai: FinishEngineAI, at date: Date, pageID: String, token: String) async throws {
        var request = URLRequest(url: URL(string: "https://api.notion.com/v1/pages/\(pageID)")!)
        request.httpMethod = "PATCH"
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("2025-09-03", forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        iso.timeZone = .current
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "properties": [
                "Status": ["select": ["name": "Doing"]],
                "Holder": ["select": ["name": ai.rawValue]],
                "Held At": ["date": ["start": iso.string(from: date)]],
            ],
        ])
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FinishEngineError(code: "BAD_OUTPUT")
        }
        if json["object"] as? String == "error" {
            throw FinishEngineError(code: json["code"] as? String ?? "NOTION_ERROR")
        }
    }

    /// Widget Display.AI selects the provider. Codex uses native-links.json
    /// to reach a local task; Claude uses links-by-ai.json.
    private static let claudeApp = "com.anthropic.claudefordesktop"
    private static let chatGPTApp = "com.openai.codex"

    /// Copies a ready-to-paste instruction for `task` (if any), then opens the
    /// chat where `project` is worked on.
    static func continueInChat(project: String, ai: FinishEngineAI, task: FinishEngineTask? = nil,
                               context: FinishEngineProject? = nil) {
        if let task {
            // Line 1 is the task name alone so the new chat gets titled after
            // the task (not "Finish Engine project"); the last line tells the
            // AI to act here instead of routing to another chat.
            var lines = [task.task,
                         "ทำงานนี้ต่อให้เสร็จ · โปรเจกต์: \(project) · สถานะ: \(statusTH[task.status] ?? task.status) · W\(weightText(task.weight))"]
            if let c = context {
                let filled = max(0, min(10, c.mvp / 10))
                lines.append("Snapshot: [\(project)] MVP \(String(repeating: "▓", count: filled))\(String(repeating: "░", count: 10 - filled)) \(c.mvp)% | FULL \(c.full)% | Next: \(c.next)")
                if !c.recentDone.isEmpty {
                    lines.append("ทำไปแล้ว (Done ล่าสุด): " + c.recentDone.joined(separator: " · "))
                }
            }
            if !task.dod.isEmpty { lines.append("DoD (เกณฑ์เสร็จ): \(task.dod)") }
            if !task.blocker.isEmpty { lines.append("ล่าสุด/ติดอยู่ที่: \(task.blocker)") }
            lines.append("Tracker: https://www.notion.so/\(task.id.replacingOccurrences(of: "-", with: ""))")
            if !ai.writesNotion {
                lines.append("กติกา: ทำทีละขั้น ≤7 ขั้น เลือกทางลัดก่อน (Cut → Borrow → ทำมือ → Fake → Simplify). งานนี้ต่อยอดระบบที่มีอยู่แล้ว — ถ้าไม่รู้ว่าระบบจริงทำด้วยอะไร ให้ถามก่อน ห้ามเดาหรือออกแบบใหม่. ห้ามคำนวณ % เอง และห้ามเปลี่ยนเป็น Done ถ้ายังไม่มีหลักฐานตาม DoD. จบคำตอบด้วยตาราง PENDING WRITES (DB | Task | Field | New value) ใช้ได้เฉพาะช่อง Status / Blocker")
            }
            lines.append("บอกสั้นๆ ว่างานนี้ทำอะไรไปแล้ว แล้วลงมือขั้นถัดไปในแชทนี้เลย ไม่ต้องส่งไปแชทอื่น")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        }

        if ai == .codex {
            if let native = nativeLink(for: project),
               let handler = NSWorkspace.shared.urlForApplication(toOpen: native),
               Bundle(url: handler)?.bundleIdentifier == chatGPTApp {
                NSWorkspace.shared.open(native)
                return
            }
            openChatGPTApp()
            return
        }

        if ai == .chatgpt {
            // Project URLs from links-by-ai.json open in the default browser.
            // ChatGPT.app does not expose a Project deep link, so open the app.
            openChatGPTApp()
            return
        }

        if ai == .gemini {
            let url = link(for: project, ai: .gemini) ?? URL(string: "https://gemini.google.com/app")!
            NSWorkspace.shared.open(url)
            return
        }

        if let code = codeLink(for: project),
           let handler = NSWorkspace.shared.urlForApplication(toOpen: code),
           Bundle(url: handler)?.bundleIdentifier == claudeApp {
            NSWorkspace.shared.open(code)
            return
        }

        if let web = link(for: project, ai: ai) {
            // The desktop app routes claude://claude.ai/<path> to that page.
            var deep = URLComponents(url: web, resolvingAgainstBaseURL: false)
            deep?.scheme = "claude"
            if let deepURL = deep?.url, NSWorkspace.shared.urlForApplication(toOpen: deepURL) != nil {
                NSWorkspace.shared.open(deepURL)
                return
            }
            NSWorkspace.shared.open(web)
            return
        }

        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: claudeApp) {
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
        } else if let web = URL(string: "https://claude.ai") {
            NSWorkspace.shared.open(web)
        }
    }

    private static func openChatGPTApp() {
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: chatGPTApp) {
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    static func hasLink(for project: String, ai: FinishEngineAI) -> Bool {
        ai == .codex ? nativeLink(for: project) != nil : link(for: project, ai: ai) != nil
    }

    private static func nativeLink(for project: String) -> URL? {
        let file = folder.appendingPathComponent("native-links.json")
        guard let data = try? Data(contentsOf: file),
              let links = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let raw = links[project],
              let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "codex", parts.user == nil, parts.password == nil,
              parts.port == nil, parts.fragment == nil
        else { return nil }

        if parts.host == "threads" {
            let id = String(parts.path.dropFirst())
            return parts.path.hasPrefix("/") && UUID(uuidString: id) != nil &&
                parts.queryItems == nil ? url : nil
        }
        if parts.host == "new", parts.path.isEmpty || parts.path == "/",
           let items = parts.queryItems, items.count == 1,
           items[0].name == "path", let path = items[0].value,
           (path as NSString).isAbsolutePath,
           FileManager.default.fileExists(atPath: path) {
            return url
        }
        return nil
    }

    /// claude://code/new for the project's folder in folders.json, or nil.
    private static func codeLink(for project: String) -> URL? {
        let file = folder.appendingPathComponent("folders.json")
        guard let data = try? Data(contentsOf: file),
              let map = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let dir = FinishEngineCodeLink.folder(
                  for: project, map: map,
                  home: FileManager.default.homeDirectoryForCurrentUser.path,
                  isDirectory: { path in
                      var isDir: ObjCBool = false
                      return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
                  })
        else { return nil }
        return FinishEngineCodeLink.url(folder: dir)
    }

    private static func link(for project: String, ai: FinishEngineAI) -> URL? {
        let byAI = folder.appendingPathComponent("links-by-ai.json")
        if let data = try? Data(contentsOf: byAI),
           let links = try? JSONSerialization.jsonObject(with: data) as? [String: [String: String]] {
            for key in ai.linkKeys {
                if let raw = links[project]?[key], let url = validLink(raw, ai: ai) { return url }
            }
        }

        let legacy = folder.appendingPathComponent("links.json")
        if let data = try? Data(contentsOf: legacy),
           let links = try? JSONSerialization.jsonObject(with: data) as? [String: String],
           let raw = links[project],
           let url = validLink(raw, ai: ai) {
            return url
        }

        if let data = try? Data(contentsOf: byAI),
           let links = try? JSONSerialization.jsonObject(with: data) as? [String: [String: String]] {
            for key in ai.linkKeys {
                if let raw = links["_default"]?[key], let url = validLink(raw, ai: ai) { return url }
            }
        }
        return nil
    }

    private static func validLink(_ raw: String, ai: FinishEngineAI) -> URL? {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https",
              let host = url.host?.lowercased(),
              host == ai.host || host.hasSuffix(".\(ai.host)")
        else { return nil }
        return url
    }

    static let statusTH = ["Doing": "กำลังทำ", "Todo": "ยังไม่เริ่ม", "Done": "เสร็จแล้ว"]

    static func weightText(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }

    static func message(for code: String) -> String {
        switch code {
        case "NO_TOKEN": return "ยังไม่มี Notion token: ใส่ไว้ที่ ~/.finish-engine/notion_token"
        case "unauthorized": return "Notion token ใช้ไม่ได้: สร้าง token ใหม่แล้ววางทับไฟล์เดิม"
        case "object_not_found": return "Integration ยังเข้าถึง Tracker ไม่ได้: เพิ่ม Connection ที่หน้า Finish Engine ใน Notion"
        case "restricted_resource": return "Integration ไม่มีสิทธิ์อ่าน: เปิดสิทธิ์ Read content"
        case "rate_limited": return "Notion จำกัดจำนวนครั้ง: จะลองใหม่รอบถัดไป"
        case "NETWORK": return "เชื่อม Notion ไม่ได้: จะลองใหม่อัตโนมัติ"
        case "BAD_OUTPUT": return "อ่านข้อมูลจาก Notion ไม่ได้"
        case "NO_WRITE": return "สลับ AI ไม่สำเร็จ: เปิดสิทธิ์ Update content ให้ Integration ใน Notion"
        case "NO_CLAIM": return "เปิดแชทแล้ว แต่บันทึกผู้ถืองานลง Notion ไม่สำเร็จ: เช็กสิทธิ์ Update content ของ Project Tracker"
        case "NO_FRESH_STATUS": return "เปิดแชทแล้ว แต่ไม่เปลี่ยนสถานะงาน เพราะอ่าน Status ล่าสุดจาก Notion ไม่ได้"
        case "NO_ARCHIVE": return "เก็บเข้าคลัง/ดึงกลับไม่สำเร็จ: เช็กสิทธิ์ Update content ของตาราง Widget Display"
        case "NO_DISPLAY_ROW": return "ยังอ่านตาราง Widget Display ไม่ได้ (สลับ AI / เก็บเข้าคลังไม่ได้)"
        case "NO_STATUS": return "บันทึกสถานะงานลง Notion ไม่สำเร็จ จึงย้อนกลับให้แล้ว: เช็กสิทธิ์ Update content ของ Project Tracker"
        case "NO_INSERT": return "สร้างโปรเจกต์แล้ว แต่บันทึกขั้นแรกไม่ได้: เปิดสิทธิ์ Insert content ให้ Finish Engine Widget bot"
        case "NO_SCHEMA": return "สร้างโปรเจกต์ไม่สำเร็จ: เปิดสิทธิ์ Update content ให้ Finish Engine Widget bot"
        default: return "Notion ตอบกลับว่า \(code)"
        }
    }

    // MARK: - Notion

    private static func readToken() throws -> String {
        let url = folder.appendingPathComponent("notion_token")
        let raw = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let token = raw.components(separatedBy: .whitespacesAndNewlines).joined()
        guard !token.isEmpty else { throw FinishEngineError(code: "NO_TOKEN") }
        return token
    }

    private static func queryAll(_ dataSource: String, token: String) async throws -> [[String: Any]] {
        var rows: [[String: Any]] = []
        var cursor: String?
        repeat {
            var request = URLRequest(url: URL(string: "https://api.notion.com/v1/data_sources/\(dataSource)/query")!)
            request.httpMethod = "POST"
            request.timeoutInterval = 15
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("2025-09-03", forHTTPHeaderField: "Notion-Version")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            var body: [String: Any] = ["page_size": 100]
            if let cursor { body["start_cursor"] = cursor }
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw FinishEngineError(code: "BAD_OUTPUT")
            }
            if json["object"] as? String == "error" {
                throw FinishEngineError(code: json["code"] as? String ?? "NOTION_ERROR")
            }
            guard let results = json["results"] as? [[String: Any]] else {
                throw FinishEngineError(code: "BAD_OUTPUT")
            }
            rows += results
            cursor = (json["has_more"] as? Bool == true) ? json["next_cursor"] as? String : nil
        } while cursor != nil
        return rows
    }

    private static func properties(_ page: [String: Any]) -> [String: Any] {
        page["properties"] as? [String: Any] ?? [:]
    }

    private static func select(_ page: [String: Any], _ key: String) -> String? {
        let prop = properties(page)[key] as? [String: Any]
        return (prop?["select"] as? [String: Any])?["name"] as? String
    }

    private static func text(_ page: [String: Any], _ key: String) -> String {
        let prop = properties(page)[key] as? [String: Any]
        let runs = (prop?["title"] ?? prop?["rich_text"]) as? [[String: Any]] ?? []
        return runs.compactMap { $0["plain_text"] as? String }.joined()
    }

    private static func number(_ page: [String: Any], _ key: String) -> Double? {
        (properties(page)[key] as? [String: Any])?["number"] as? Double
    }

    private static func date(_ page: [String: Any], _ key: String) -> Date? {
        let prop = properties(page)[key] as? [String: Any]
        return timestamp((prop?["date"] as? [String: Any])?["start"] as? String)
    }

    private static func timestamp(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: raw) { return d }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: raw)
    }

    private static func checkbox(_ page: [String: Any], _ key: String) -> Bool {
        (properties(page)[key] as? [String: Any])?["checkbox"] as? Bool ?? false
    }

    /// A Tracker row. A task without a Project stays off the board (there's
    /// no project to list it under).
    private static func task(from page: [String: Any]) -> FinishEngineTask {
        let title = text(page, "Task")
        return FinishEngineTask(
            id: page["id"] as? String ?? UUID().uuidString,
            task: title.isEmpty ? "(ไม่มีชื่องาน)" : title,
            project: select(page, "Project") ?? "",
            status: select(page, "Status") ?? "Todo",
            tier: select(page, "Tier") ?? "LATER",
            weight: number(page, "Weight") ?? 1,
            blocker: text(page, "Blocker"),
            dod: text(page, "DoD"),
            holder: select(page, "Holder"),
            heldAt: date(page, "Held At"),
            lastEdited: timestamp(page["last_edited_time"] as? String)
        )
    }

    private struct DisplayProject: Codable {
        let name: String
        var ai: FinishEngineAI
        var pageID: String? = nil
        var shown = true
        var finished = false
        var mvpPercent: Double? = nil
        var fullPercent: Double? = nil
    }

    /// All Widget Display projects, sorted by Order (blank Order goes last,
    /// ties keep table order). nil = table unreadable.
    private static func displayList(token: String) async -> [DisplayProject]? {
        guard let rows = try? await queryAll(displayID, token: token) else { return nil }
        let picked = rows.enumerated().compactMap { (index, page) -> (Double, Int, DisplayProject)? in
            let name = text(page, "Project").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            let ai = select(page, "AI").flatMap { FinishEngineAI(notion: $0) }
                ?? FinishEngineAI.fallback(for: name)
            return (number(page, "Order") ?? .greatestFiniteMagnitude, index,
                    DisplayProject(name: name, ai: ai, pageID: page["id"] as? String,
                                   shown: checkbox(page, "Show"),
                                   finished: checkbox(page, "เสร็จแล้ว"),
                                   mvpPercent: number(page, "MVP %"),
                                   fullPercent: number(page, "FULL %")))
        }
        var projects: [DisplayProject] = []
        for (_, _, project) in picked.sorted(by: { ($0.0, $0.1) < ($1.0, $1.1) })
        where !projects.contains(where: { $0.name == project.name }) {
            projects.append(project)
        }
        return projects
    }

    // MARK: - Cache and snapshot

    private struct Cache: Codable {
        var names: [String]
        var tasks: [FinishEngineTask]
        var display: [DisplayProject]?
    }

    private func loadCache() {
        guard let data = try? Data(contentsOf: Self.cacheURL),
              let cache = try? JSONDecoder().decode(Cache.self, from: data) else { return }
        tasks = cache.tasks
        projectNames = cache.names
        displayCache = cache.display
        rebuild()
    }

    private func saveCache() {
        guard let data = try? JSONEncoder().encode(Cache(names: projectNames, tasks: tasks, display: displayCache)) else { return }
        try? FileManager.default.createDirectory(at: Self.cacheURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: Self.cacheURL, options: .atomic)
    }

    /// Same shape the Übersicht widget wrote, so tools reading it keep
    /// working; now every project with open work (MVP tasks under
    /// remaining_mvp, as before).
    private func writeSnapshot(at date: Date) {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let snapshot: [String: Any] = [
            "source": "Notion Project Tracker (read-only snapshot by OverlayLens Finish Engine)",
            "updated": iso.string(from: date),
            "pain_log_open": painsOpen ?? 0,
            "projects": projects.filter { !$0.remaining.isEmpty }.map { p in
                [
                    "name": p.name,
                    "mvp_percent": p.mvp,
                    "full_percent": p.full,
                    "next": p.next,
                    "remaining_mvp": p.remaining.filter { $0.tier == "MVP" }.map { t in
                        [
                            "task": t.task,
                            "weight": t.weight,
                            "status": t.status,
                            "blocker": t.blocker.isEmpty ? NSNull() : t.blocker,
                        ] as [String: Any]
                    },
                ] as [String: Any]
            },
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: snapshot, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else { return }
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        try? data.write(to: Self.folder.appendingPathComponent("status.json"), options: .atomic)
    }
}

struct FinishEngineError: Error {
    let code: String
}

import Foundation

/// กะดึก Finish Engine: Claude quota that would otherwise reset unused goes to
/// Finish Engine work while the user is away. Foundation only (like
/// FinishEngineLogic.swift), so StampLab's menu, the `nightshift-cli` helper the
/// night chat calls, and `swift test --package-path Tests` share one set of rules.
///
/// How the pieces meet:
/// - The menu row (NightShift.swift) writes `config.json`: the user's switch and
///   the projects the night chat may touch. Nothing else turns it on.
/// - A Routine in the Claude desktop app opens the night chat on a schedule; its
///   prompt starts with `marker` (source: Tools/nightshift/routine-prompt.md).
/// - `nightshift-cli gate` (a UserPromptSubmit hook) blocks that prompt before it
///   reaches the model while the switch is off, so an off switch costs no tokens.
/// - The chat reads the real plan usage with the app's get_usage tool and asks
///   `nightshift-cli check` whether to go on (`NightShiftPlanner`). StampLab can't
///   read the quota itself: its Claude Code login in the keychain is months stale
///   and the desktop app never runs the statusline that used to cache it.
/// - What the chat did goes to `reports/<night>.md`, which the menu opens.
enum NightShift {
    /// The Routine's prompt starts with this; the gate only ever touches such prompts.
    static let marker = "[FE-NIGHTSHIFT]"
    /// The Routine's task id in the Claude desktop app.
    static let routineID = "finish-engine-night-shift"
    /// Tracker.Holder value the night chat writes when it claims a task.
    static let holder = "Claude"
    /// Finish Engine Project Tracker (same data source as FinishEngineModel).
    static let trackerID = "05acc1d9-892a-47a5-80dd-32cfc2208e2f"

    static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/StampLab/nightshift")
    }
    static var configURL: URL { folder.appendingPathComponent("config.json") }
    /// The last get_usage answer the night chat saw (the menu shows its numbers).
    static var usageURL: URL { folder.appendingPathComponent("usage.json") }
    static var stateURL: URL { folder.appendingPathComponent("state.json") }
    static var reportsFolder: URL { folder.appendingPathComponent("reports") }

    /// The Routine's file in the Claude desktop app; present = installed.
    static var routineURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/scheduled-tasks/\(routineID)/SKILL.md")
    }

    /// Is this the night chat's opening prompt? The app wraps a Routine's
    /// prompt as `<scheduled-task name="…" file="…">` plus ~500 characters of
    /// "automated run" preamble before the task text, so the wrapper is what
    /// identifies a scheduled run; the marker near the start covers a pasted copy.
    /// A chat that merely mentions the marker later on is left alone.
    static func isNightShiftPrompt(_ prompt: String) -> Bool {
        let opening = String(prompt.prefix(300))
        return opening.contains("<scheduled-task name=\"\(routineID)\"") || opening.contains(marker)
    }

    /// A run after midnight belongs to the night before: 01:00 on the 2nd
    /// reports into the 1st's file, so one night is one report.
    static func night(of date: Date, morningHour: Int, calendar: Calendar = .current) -> String {
        let hour = calendar.component(.hour, from: date)
        let day = hour < morningHour ? calendar.date(byAdding: .day, value: -1, to: date) ?? date : date
        // File names stay Gregorian even on a Mac set to the Buddhist calendar (2569).
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: day)
    }

    /// yyyy-MM-dd in the Gregorian calendar (this Mac uses the Buddhist one).
    static func day(of date: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func reportURL(night: String) -> URL {
        reportsFolder.appendingPathComponent(night + ".md")
    }

    /// The "- HH:mm · …" entries of a report file.
    static func entries(inReport text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .filter { $0.hasPrefix("- ") }
            .map { String($0.dropFirst(2)) }
    }

    static func clock(_ date: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "th_TH")
        formatter.dateFormat = calendar.isDate(date, inSameDayAs: Date()) ? "HH:mm" : "EEE HH:mm"
        return formatter.string(from: date)
    }
}

/// The user's choices, written only by the StampLab menu.
struct NightShiftConfig: Codable, Equatable {
    /// The switch. Off until the user turns it on.
    var enabled = false
    /// Tracker Project names the night chat may work on (focus).
    var projects: [String] = []
    /// อัตโนมัติ: any project in the Tracker, including ones added later —
    /// until the user narrows it to the projects they want to focus on.
    var allProjects = false

    /// The night chat has somewhere to work.
    var hasProjects: Bool { allProjects || !projects.isEmpty }

    func allows(_ project: String) -> Bool {
        allProjects ? !project.isEmpty : projects.contains(project)
    }
    var mode: Mode = .pace
    /// Weekly share kept for the user's own work until the last day before the
    /// weekly reset (the plan in `.pace` mode).
    var reserve = 35
    /// The last day before the weekly reset (yyyy-MM-dd) and the user's answer
    /// to "วันนี้จะใช้ Claude ทำงานไหม": "work" keeps the reserve for them,
    /// "free" gives the whole day to the night shift.
    var lastDay = ""
    var lastDayAnswer = ""
    /// Scheduled runs before this hour (and after `morningHour`) are the user's
    /// day: blocked unless the user gave the last day away.
    var nightHour = 22
    /// Stop when the 5-hour window reaches this many percent.
    var fiveHourStop = 90
    var weeklyStop = 90
    /// In the last hours before the weekly reset, whatever is left would be lost anyway.
    var finalHours = 4
    var finalStop = 97
    /// The 5-hour window the night chat spends must reset by this hour, so the
    /// user's morning starts with a fresh window instead of the chat's leftovers.
    var morningHour = 8
    /// Wrap up once the night chat's own context is this full; the next run starts clean.
    var contextStop = 50
    /// When the Routine fires, shown in the menu (the Routine itself holds the schedule).
    var schedule = "23:00 และ 01:00"

    /// Weekly budget rule.
    enum Mode: String, Codable, CaseIterable {
        /// The plan: a daily line climbing to 100 − `reserve` by the last day,
        /// so the user always keeps `reserve`; on the last day, the user's
        /// answer decides.
        case pace
        /// Only the last `finalHours` before the weekly reset.
        case final
        /// Up to `weeklyStop` any night.
        case max
    }

    init() {}

    /// Keys missing from an older file fall back to the defaults above.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = NightShiftConfig()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        projects = try c.decodeIfPresent([String].self, forKey: .projects) ?? d.projects
        allProjects = try c.decodeIfPresent(Bool.self, forKey: .allProjects) ?? d.allProjects
        mode = ((try? c.decodeIfPresent(Mode.self, forKey: .mode)) ?? nil) ?? d.mode
        reserve = try c.decodeIfPresent(Int.self, forKey: .reserve) ?? d.reserve
        lastDay = try c.decodeIfPresent(String.self, forKey: .lastDay) ?? d.lastDay
        lastDayAnswer = try c.decodeIfPresent(String.self, forKey: .lastDayAnswer) ?? d.lastDayAnswer
        nightHour = try c.decodeIfPresent(Int.self, forKey: .nightHour) ?? d.nightHour
        fiveHourStop = try c.decodeIfPresent(Int.self, forKey: .fiveHourStop) ?? d.fiveHourStop
        weeklyStop = try c.decodeIfPresent(Int.self, forKey: .weeklyStop) ?? d.weeklyStop
        finalHours = try c.decodeIfPresent(Int.self, forKey: .finalHours) ?? d.finalHours
        finalStop = try c.decodeIfPresent(Int.self, forKey: .finalStop) ?? d.finalStop
        morningHour = try c.decodeIfPresent(Int.self, forKey: .morningHour) ?? d.morningHour
        contextStop = try c.decodeIfPresent(Int.self, forKey: .contextStop) ?? d.contextStop
        schedule = try c.decodeIfPresent(String.self, forKey: .schedule) ?? d.schedule
    }

    /// A missing or unreadable file means off.
    static func load(from url: URL = NightShift.configURL) -> NightShiftConfig {
        guard let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(NightShiftConfig.self, from: data)
        else { return NightShiftConfig() }
        return config
    }

    func save(to url: URL = NightShift.configURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

/// Plan limits as the Claude desktop app's get_usage tool reports them — the
/// same numbers as the app's usage card.
struct NightShiftUsage: Equatable {
    struct Window: Equatable {
        var label: String
        var used: Double
        var resetsAt: Date?
    }

    var fiveHour: Window?
    /// "Weekly · all models" plus any per-model weekly window.
    var weekly: [Window] = []
    /// How full the asking chat's own context is (get_usage `context.percentUsed`).
    var contextUsed: Double?

    /// nil when the plan limits weren't readable ("unavailable"): the night chat
    /// then stops rather than spend blind.
    static func parse(_ data: Data) -> NightShiftUsage? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let plan = root["plan"] as? [String: Any],
              plan["status"] as? String == "ok",
              let windows = plan["windows"] as? [[String: Any]]
        else { return nil }
        var usage = NightShiftUsage()
        for raw in windows {
            guard let label = raw["label"] as? String,
                  let used = (raw["percentUsed"] as? NSNumber)?.doubleValue
            else { continue }
            let window = Window(label: label, used: used, resetsAt: timestamp(raw["resetsAt"]))
            let lower = label.lowercased()
            if lower.contains("week") {
                usage.weekly.append(window)
            } else if lower.contains("hour") || lower.contains("session") {
                usage.fiveHour = window
            }
        }
        if let context = root["context"] as? [String: Any], context["status"] as? String == "ok" {
            usage.contextUsed = (context["percentUsed"] as? NSNumber)?.doubleValue
        }
        guard usage.fiveHour != nil || !usage.weekly.isEmpty else { return nil }
        return usage
    }

    private static func timestamp(_ raw: Any?) -> Date? {
        guard let text = raw as? String else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: text) { return date }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: text)
    }
}

struct NightShiftDecision: Equatable {
    var go: Bool
    var reason: String
}

/// May the night chat spend more right now? Asked before every step, so it
/// stops a step short of each ceiling instead of running into the limit.
enum NightShiftPlanner {
    static let week: TimeInterval = 7 * 86_400

    static func decide(_ usage: NightShiftUsage?, config: NightShiftConfig,
                       now: Date = Date(), calendar: Calendar = .current) -> NightShiftDecision {
        func stop(_ reason: String) -> NightShiftDecision { NightShiftDecision(go: false, reason: reason) }
        func clock(_ date: Date) -> String { NightShift.clock(date, calendar: calendar) }

        guard config.enabled else { return stop("กะดึกปิดอยู่ในเมนู StampLab") }
        guard config.hasProjects else { return stop("ยังไม่ได้ติ๊กโปรเจกต์ให้กะดึกในเมนู StampLab") }
        guard let usage else { return stop("อ่านโควตาไม่ได้ จึงไม่เสี่ยงทำต่อ") }
        if let context = usage.contextUsed, context >= Double(config.contextStop) {
            return stop("แชตนี้ใช้บริบทไป \(Int(context))% แล้ว ปิดรอบให้รอบหน้าเริ่มแชตใหม่")
        }

        // 5-hour window: the one in use, or the one the next message would open.
        var parts: [String] = []
        let windowEnd: Date
        if let five = usage.fiveHour, let reset = five.resetsAt, reset > now {
            if five.used >= Double(config.fiveHourStop) {
                return stop("โควตา 5 ชม. ใช้ไป \(Int(five.used))% ถึงจุดหยุด \(config.fiveHourStop)% (รีเซ็ต \(clock(reset)))")
            }
            windowEnd = reset
            parts.append("5 ชม. \(Int(five.used))/\(config.fiveHourStop)%")
        } else {
            windowEnd = now.addingTimeInterval(5 * 3600)
            parts.append("เปิดรอบ 5 ชม. ใหม่ถึง \(clock(windowEnd))")
        }
        let morning = calendar.nextDate(after: now, matching: DateComponents(hour: config.morningHour, minute: 0),
                                        matchingPolicy: .nextTime) ?? now.addingTimeInterval(86_400)
        if windowEnd > morning {
            return stop("รอบโควตา 5 ชม. นี้ลากไปถึง \(clock(windowEnd)) ทับตอนเช้า (\(config.morningHour):00) จึงเก็บไว้ให้คุณ")
        }

        for window in usage.weekly {
            guard let reset = window.resetsAt, reset > now else {
                // No reset time: the week's window hasn't started, so there is
                // no leftover yet — only the user's whole week ahead.
                if config.mode == .max {
                    if window.used >= Double(config.weeklyStop) {
                        return stop("\(window.label) ใช้ไป \(Int(window.used))% ถึงเพดาน \(config.weeklyStop)%")
                    }
                    continue
                }
                return stop("รอบรายสัปดาห์ยังไม่เริ่ม ยังไม่มีโควตาเหลือทิ้ง")
            }
            switch weeklyCap(reset: reset, config: config, now: now, calendar: calendar) {
            case .failure(let why):
                return stop(why.reason)
            case .success(let cap):
                if window.used >= Double(cap) {
                    return stop("\(window.label) ใช้ไป \(Int(window.used))% ถึงเพดานตอนนี้ \(cap)%")
                }
                parts.append("สัปดาห์ \(Int(window.used))/\(cap)%")
            }
        }
        return NightShiftDecision(go: true, reason: "ทำต่อได้ · " + parts.joined(separator: " · "))
    }
}

struct NightShiftRefusal: Error, Equatable {
    let reason: String
}

extension NightShiftPlanner {
    /// The last day before the weekly reset starts on the morning of the day
    /// before the reset's day (reset Mon 03:00 → Sun 08:00).
    static func lastDayStart(reset: Date, config: NightShiftConfig, calendar: Calendar = .current) -> Date {
        let dayBefore = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: reset)) ?? reset
        return calendar.date(bySettingHour: config.morningHour, minute: 0, second: 0, of: dayBefore) ?? dayBefore
    }

    static func isLastDay(now: Date, reset: Date, config: NightShiftConfig, calendar: Calendar = .current) -> Bool {
        now >= lastDayStart(reset: reset, config: config, calendar: calendar) && now < reset
    }

    /// "work" / "free" when the user answered for the last day before `reset`.
    static func lastDayAnswer(reset: Date, config: NightShiftConfig, calendar: Calendar = .current) -> String? {
        let day = NightShift.day(of: lastDayStart(reset: reset, config: config, calendar: calendar), calendar: calendar)
        return config.lastDay == day && !config.lastDayAnswer.isEmpty ? config.lastDayAnswer : nil
    }

    /// The weekly ceiling (percent) right now, or why nothing may be spent.
    static func weeklyCap(reset: Date, config: NightShiftConfig, now: Date,
                          calendar: Calendar = .current) -> Result<Int, NightShiftRefusal> {
        // 5 minutes of slack: resets come as "20:00:00.453Z" and the Routine
        // fires on the hour, so 23:00 is "4 h 0.45 s" before a 03:00 reset.
        let left = reset.timeIntervalSince(now) - 300
        let final = left <= Double(config.finalHours) * 3600
        switch config.mode {
        case .max:
            return .success(final ? config.finalStop : config.weeklyStop)
        case .final:
            return final ? .success(config.finalStop)
                : .failure(NightShiftRefusal(reason: "ตั้งให้ทำเฉพาะ \(config.finalHours) ชม.สุดท้ายก่อนรีเซ็ตรายสัปดาห์ (\(NightShift.clock(reset, calendar: calendar)))"))
        case .pace:
            let keep = 100 - config.reserve
            if isLastDay(now: now, reset: reset, config: config, calendar: calendar) {
                switch lastDayAnswer(reset: reset, config: config, calendar: calendar) {
                case "free": return .success(config.finalStop)
                case "work": return .success(left <= 2 * 3600 ? config.finalStop : keep)
                default: return .success(final ? config.finalStop : keep)
                }
            }
            return .success(min(config.weeklyStop, planLine(at: now, reset: reset, config: config, calendar: calendar)))
        }
    }

    /// The plan's line: climbs evenly from 0 at the start of the week to
    /// 100 − reserve when the last day begins.
    static func planLine(at date: Date, reset: Date, config: NightShiftConfig, calendar: Calendar = .current) -> Int {
        let start = reset.addingTimeInterval(-week)
        let span = lastDayStart(reset: reset, config: config, calendar: calendar).timeIntervalSince(start)
        guard span > 0 else { return 100 - config.reserve }
        let fraction = min(1, max(0, date.timeIntervalSince(start) / span))
        return Int((Double(100 - config.reserve) * fraction).rounded(.down))
    }

    /// Scheduled runs in the user's day are blocked, except on a last day the
    /// user gave away. The reset comes from the last usage the night chat saw.
    static func daytimeBlocked(now: Date, config: NightShiftConfig, weeklyReset: Date?,
                               calendar: Calendar = .current) -> Bool {
        let hour = calendar.component(.hour, from: now)
        guard hour >= config.morningHour, hour < config.nightHour else { return false }
        guard config.mode == .pace, let reset = weeklyReset,
              isLastDay(now: now, reset: reset, config: config, calendar: calendar)
        else { return true }
        return lastDayAnswer(reset: reset, config: config, calendar: calendar) != "free"
    }

    /// Today's budget in plain words for the menu, from the last usage seen.
    /// nil on the last day before the user answers (the menu asks instead).
    static func todayPlan(_ usage: NightShiftUsage, config: NightShiftConfig, now: Date = Date(),
                          calendar: Calendar = .current) -> String? {
        guard config.mode == .pace, let weekly = usage.weekly.first, var reset = weekly.resetsAt else { return nil }
        // A reading from before the last reset still gives the week's timing,
        // but not this week's usage.
        var known = true
        while reset <= now {
            reset.addTimeInterval(week)
            known = false
        }
        let used = known ? " (ใช้ไป \(Int(weekly.used))%)" : ""
        if isLastDay(now: now, reset: reset, config: config, calendar: calendar) {
            switch lastDayAnswer(reset: reset, config: config, calendar: calendar) {
            case "free": return "วันสุดท้ายก่อนรีเซ็ต · กะดึกใช้ได้ถึง \(config.finalStop)%\(used)"
            case "work": return "วันสุดท้ายก่อนรีเซ็ต · เก็บไว้ให้คุณ\(used)"
            default: return nil
            }
        }
        let endOfToday = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        let todayCap = planLine(at: min(endOfToday, lastDayStart(reset: reset, config: config, calendar: calendar)),
                                reset: reset, config: config, calendar: calendar)
        return known ? "วันนี้ใช้ได้ถึง \(todayCap)% · ใช้ไป \(Int(weekly.used))%" : "วันนี้ใช้ได้ถึง \(todayCap)% ของสัปดาห์"
    }
}

/// What the night chat claimed or set aside, so the next run continues or skips it.
struct NightShiftState: Codable, Equatable {
    var claimed: [String: Date] = [:]
    /// Needs the user (a login, a look at the real screen, a taste call).
    var skipped: [String: Date] = [:]

    static func load(from url: URL = NightShift.stateURL) -> NightShiftState {
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(NightShiftState.self, from: data)
        else { return NightShiftState() }
        return state
    }

    func save(to url: URL = NightShift.stateURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}

/// Which Tracker task the night chat works on.
enum NightShiftPicker {
    /// Someone else pressed ทำต่อ this recently (FinishEngineModel.holdWindow): leave it.
    static let holdWindow: TimeInterval = 2 * 60 * 60
    /// A set-aside task comes back once its row changes afterwards, or after a week.
    static let skipFor: TimeInterval = 7 * 86_400

    static func pick(_ tasks: [FinishEngineTask], config: NightShiftConfig,
                     state: NightShiftState, now: Date = Date()) -> FinishEngineTask? {
        func ours(_ task: FinishEngineTask) -> Bool {
            guard let claimed = state.claimed[task.id] else { return false }
            // Nobody claimed it after the night shift did.
            return (task.heldAt ?? .distantPast) <= claimed.addingTimeInterval(120)
        }
        let usable = tasks.filter { task in
            guard config.allows(task.project),
                  task.status == "Doing" || task.status == "Todo" else { return false }
            if let skipped = state.skipped[task.id], now.timeIntervalSince(skipped) < skipFor,
               (task.lastEdited ?? .distantPast) <= skipped.addingTimeInterval(180) {
                return false
            }
            if ours(task) { return true }
            if let held = task.heldAt, now.timeIntervalSince(held) < holdWindow { return false }
            return true
        }
        // Finish what an earlier night run started before opening new work.
        return FinishEngineBoard.ordered(usable.filter(ours)).first
            ?? FinishEngineBoard.ordered(usable).first
    }
}

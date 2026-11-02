import AppKit
import SwiftUI

/// กะดึก Finish Engine — switched from the menu's quota row (QuotaMenu.swift)
/// together with ทำต่ออัตโนมัติ, or alone in Settings › โควตา Claude.
/// The rules and the files involved are described in NightShiftLogic.swift.
@MainActor
final class NightShiftController: ObservableObject {
    static let shared = NightShiftController()

    struct Report: Equatable {
        let night: String
        let url: URL
        let entries: [String]
    }

    @Published private(set) var config = NightShiftConfig.load()
    @Published private(set) var usage: NightShiftUsage?
    @Published private(set) var usageAt: Date?
    @Published private(set) var report: Report?
    @Published private(set) var routineInstalled = false

    private var timer: Timer?

    private init() {}

    func start() {
        reload()
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    func reload() {
        config = .load()
        routineInstalled = FileManager.default.fileExists(atPath: NightShift.routineURL.path)
        if let data = try? Data(contentsOf: NightShift.usageURL) {
            usage = .parse(data)
            usageAt = (try? NightShift.usageURL.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
        } else {
            usage = nil
            usageAt = nil
        }
        report = Self.latestReport()
        askAboutLastDayIfNeeded()
    }

    func setEnabled(_ on: Bool) { update { $0.enabled = on } }

    func toggle(project: String) {
        update { config in
            if let i = config.projects.firstIndex(of: project) {
                config.projects.remove(at: i)
            } else {
                config.projects.append(project)
            }
        }
    }

    func setReserve(_ percent: Int) { update { $0.reserve = percent } }

    func setAllProjects(_ on: Bool) { update { $0.allProjects = on } }

    /// The weekly reset from the last usage the night chat saw, rolled forward
    /// by whole weeks if that snapshot is older than the reset.
    var weeklyReset: Date? {
        guard var reset = usage?.weekly.first?.resetsAt else { return nil }
        while reset <= Date() { reset.addTimeInterval(NightShiftPlanner.week) }
        return reset
    }

    /// The last day before the weekly reset, not answered yet.
    var lastDayPending: Bool {
        guard config.enabled, config.mode == .pace, let reset = weeklyReset else { return false }
        return NightShiftPlanner.isLastDay(now: Date(), reset: reset, config: config)
            && NightShiftPlanner.lastDayAnswer(reset: reset, config: config) == nil
    }

    /// "วันนี้ใช้ได้ถึง 40% · ใช้ไป 30%", with the time of that reading when it's old.
    var todayPlan: String? {
        guard config.enabled, let usage, var plan = NightShiftPlanner.todayPlan(usage, config: config) else { return nil }
        // The reading's time matters only when the line quotes this week's usage.
        if plan.contains("ใช้ไป"), let at = usageAt, Date().timeIntervalSince(at) > 30 * 60 {
            plan += " (ข้อมูล \(NightShift.clock(at)))"
        }
        return plan
    }

    /// The user's answer for today's last day: free = the night shift may use
    /// the whole day with the best model; work = the reserve stays theirs.
    func answerLastDay(free: Bool) {
        guard let reset = weeklyReset else { return }
        let day = NightShift.day(of: NightShiftPlanner.lastDayStart(reset: reset, config: config))
        update {
            $0.lastDay = day
            $0.lastDayAnswer = free ? "free" : "work"
        }
    }

    private static let askedKey = "NightShiftLastDayAsked"

    /// Once per last day, ask in a dialog as well (the menu row asks too).
    private func askAboutLastDayIfNeeded() {
        guard lastDayPending, let reset = weeklyReset else { return }
        let day = NightShift.day(of: NightShiftPlanner.lastDayStart(reset: reset, config: config))
        guard UserDefaults.standard.string(forKey: Self.askedKey) != day else { return }
        UserDefaults.standard.set(day, forKey: Self.askedKey)
        let used = Int(usage?.weekly.first?.used ?? 0)
        DispatchQueue.main.async { [weak self] in
            let alert = NSAlert()
            alert.messageText = "วันนี้วันสุดท้ายก่อนโควตารายสัปดาห์รีเซ็ต"
            alert.informativeText = "รีเซ็ต \(NightShift.clock(reset)) · ใช้ไปแล้ว \(used)%\n\nวันนี้จะใช้ Claude ทำงานไหม? ถ้าไม่ กะดึกจะใช้โควตาที่เหลือทำงานในโปรเจกต์ที่เลือกไว้ได้ทั้งวัน ด้วยโมเดลที่ดีที่สุด แล้วหยุดเองก่อนชนลิมิต"
            alert.addButton(withTitle: "ทำงาน (เก็บโควตาไว้)")
            alert.addButton(withTitle: "ไม่ทำ ให้กะดึกใช้ได้เต็มที่")
            NSApp.activate(ignoringOtherApps: true)
            self?.answerLastDay(free: alert.runModal() == .alertSecondButtonReturn)
        }
    }

    /// "ใช้เกือบหมด" also lets the 5-hour window run closer to its limit.
    func setMode(_ mode: NightShiftConfig.Mode) {
        update { config in
            config.mode = mode
            config.fiveHourStop = mode == .max ? 95 : 90
        }
    }

    /// Re-reads the file first so a change made elsewhere isn't overwritten.
    private func update(_ change: (inout NightShiftConfig) -> Void) {
        var next = NightShiftConfig.load()
        change(&next)
        try? next.save()
        reload()
    }

    static func modeName(_ mode: NightShiftConfig.Mode) -> String {
        switch mode {
        case .pace: "ตามแผนรายวัน"
        case .final: "เฉพาะคืนก่อนรีเซ็ต"
        case .max: "ใช้เกือบหมด"
        }
    }

    static func modeHelp(_ config: NightShiftConfig) -> String {
        switch config.mode {
        case .pace: "แบ่งโควตารายสัปดาห์เป็นงบรายวัน เก็บ \(config.reserve)% ไว้ให้คุณจนถึงวันสุดท้ายก่อนรีเซ็ต · วันนั้นถามคุณก่อน: ไม่ทำงาน = กะดึกใช้ได้ทั้งวัน"
        case .final: "ทำเฉพาะ \(config.finalHours) ชม.สุดท้ายก่อนรีเซ็ตรายสัปดาห์ ไม่กระทบโควตาวันอื่น"
        case .max: "หยุดที่ 5 ชม. 95% / สัปดาห์ 90% งานเดินเร็วสุด แต่ปลายสัปดาห์อาจเหลือน้อย"
        }
    }

    /// Worth showing in the menu: the night it covers ended no more than a day ago.
    static func isRecent(_ report: Report, now: Date = Date()) -> Bool {
        let parse = DateFormatter()
        parse.calendar = Calendar(identifier: .gregorian)
        parse.locale = Locale(identifier: "en_US_POSIX")
        parse.dateFormat = "yyyy-MM-dd"
        guard let night = parse.date(from: report.night), !report.entries.isEmpty else { return false }
        return now.timeIntervalSince(night) < 42 * 3600
    }

    func openReport() {
        guard let url = report?.url else { return }
        NSWorkspace.shared.open(url)
    }

    private static func latestReport() -> Report? {
        let files = (try? FileManager.default.contentsOfDirectory(at: NightShift.reportsFolder,
                                                                   includingPropertiesForKeys: nil)) ?? []
        guard let url = files.filter({ $0.pathExtension == "md" })
            .max(by: { $0.lastPathComponent < $1.lastPathComponent }),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        return Report(night: url.deletingPathExtension().lastPathComponent, url: url,
                      entries: NightShift.entries(inReport: text))
    }

    /// "2026-11-01" → "1 พ.ย."
    static func nightLabel(_ night: String) -> String {
        let parse = DateFormatter()
        parse.calendar = Calendar(identifier: .gregorian)
        parse.locale = Locale(identifier: "en_US_POSIX")
        parse.dateFormat = "yyyy-MM-dd"
        guard let date = parse.date(from: night) else { return night }
        let show = DateFormatter()
        show.locale = Locale(identifier: "th_TH")
        show.dateFormat = "d MMM"
        return show.string(from: date)
    }
}

import AppKit
import IOKit.pwr_mgt
import WebKit

/// Claude ambient screen: when the user steps away while a Claude Code session
/// is still working (or waiting for approval), show a dim full-screen mascot
/// instead of letting the display go dark. Local only — no AI calls, no tokens.
///
/// Session state comes from Claude Code hooks running `ambient-hook`
/// (source in Tools/ambient-hook/main.swift, installed by deploy.sh), which writes
/// one JSON file per session into `claudeSessionsDir`.
@MainActor
final class ClaudeAmbientController: NSObject, WKNavigationDelegate {
    static let enabledKey = "claudeAmbientEnabled"
    static let sessionsDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/StampLab/claude-sessions")

    /// After a session finishes, keep showing "done" this long, then let the display sleep.
    private static let doneHold: TimeInterval = 300
    /// No hook activity this long means the session died without a Stop.
    private static let staleAfter: TimeInterval = 1800

    struct Session {
        let state: String; let start: Double; let since: Double; let updated: Double; let label: String; let agent: String
        var acts: [[String]] = []          // งานล่าสุดของ Claude [ประเภท, ข้อความ]
        var counts: [String: Int] = [:]    // จำนวนครั้งต่อประเภทในงานนี้
    }
    /// `agents`: who is on screen — "claude" (laptop mascot) and/or "local" (gem mascot).
    struct Summary {
        let state: String; let label: String; let t0: Double; let frozen: Double?; let doneUntil: Double; let agents: [String]
        var acts: [[String]] = []
        var counts: [String: Int] = [:]
    }

    private var panels: [(NSPanel, WKWebView)] = []
    private var showing = false
    private var forced = false
    private var shownAt = Date()
    /// การ์ดสรุปตอนกลับมา: ขยับครั้งแรกขึ้นการ์ดแทนการปิดทันที
    private var recapMode = false
    private var recapUntil = Date()
    private var awayStart: Double = 0
    private var keyMonitor: Any?
    private var assertion: IOPMAssertionID = 0
    /// Held while any Claude or local AI session is working, so an idle Mac
    /// doesn't sleep and cut the job off. Display sleep is unaffected.
    private var awakeAssertion: IOPMAssertionID = 0
    private var previousApp: NSRunningApplication?
    private var threshold: Double = 570
    private var lastPayload = ""
    private var pendingPayload = ""
    private var ticks = 0
    /// Local image generation (slidegen / mflux) seen running — it isn't a
    /// Claude Code session, so it's detected from the process list instead.
    /// โควตา Claude: ใช้ค่าจริงจาก statusline cache ถ้ามี ไม่งั้นประมาณจากบันทึกในเครื่อง
    /// (ClaudeUsageTracker ใช้ ~12 วินาที จึงคำนวณเบื้องหลังทุก 10 นาที เฉพาะตอนมีงาน)
    private var quota: [String: Any]?
    private var quotaAt: Date = .distantPast
    private var quotaBusy = false
    private var genSince: Double?
    private var genDone: (start: Double, at: Double)?
    private var timer: Timer?

    override init() {
        super.init()
        UserDefaults.standard.register(defaults: [Self.enabledKey: true])
        refreshThreshold()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        // For testing from Terminal: post "com.stamp.StampLab.ambientPreview".
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.stamp.StampLab.ambientPreview"), object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.preview() }
        }
        // ทดสอบการ์ดสรุป: post "com.stamp.StampLab.ambientRecap" (จำลองว่าไม่อยู่ 42 นาที)
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.stamp.StampLab.ambientRecap"), object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.testRecap() }
        }
    }

    private var enabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }

    // MARK: - State

    static func readSessions() -> [Session] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil) else { return [] }
        let now = Date().timeIntervalSince1970
        return files.compactMap { f in
            guard f.pathExtension == "json",
                  let d = try? Data(contentsOf: f),
                  let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                  let state = o["state"] as? String else { return nil }
            return Session(state: state,
                           start: o["start"] as? Double ?? now,
                           since: o["since"] as? Double ?? now,
                           updated: o["updated"] as? Double ?? now,
                           label: o["label"] as? String ?? "",
                           agent: o["agent"] as? String ?? "claude",
                           acts: o["acts"] as? [[String]] ?? [],
                           counts: o["n"] as? [String: Int] ?? [:])
        }
    }

    static func summarize(_ all: [Session], now: Double = Date().timeIntervalSince1970) -> Summary? {
        let live = all.filter { now - $0.updated < staleAfter }
        let waits = live.filter { $0.state == "wait" }
        let works = live.filter { $0.state == "work" }
        let dones = all.filter { $0.state == "done" && now - $0.since < doneHold }
        func label(_ s: [Session]) -> String { s.count > 1 ? "\(s.count) งาน" : (s.first?.label ?? "") }
        func agents(_ s: [Session]) -> [String] { ["claude", "local"].filter { a in s.contains { $0.agent == a } } }
        // งานล่าสุดที่โชว์ มาจาก session ที่ขยับล่าสุดในกลุ่มนั้น
        func latest(_ s: [Session]) -> Session? { s.max { $0.updated < $1.updated } }
        if let w = waits.min(by: { $0.since < $1.since }), let l = latest(waits) {
            return Summary(state: "wait", label: label(waits), t0: w.since, frozen: nil, doneUntil: 0, agents: agents(waits), acts: l.acts, counts: l.counts)
        }
        if let w = works.min(by: { $0.start < $1.start }), let l = latest(works) {
            return Summary(state: "work", label: label(works), t0: w.start, frozen: nil, doneUntil: 0, agents: agents(works), acts: l.acts, counts: l.counts)
        }
        if let d = dones.max(by: { $0.since < $1.since }) {
            return Summary(state: "done", label: label(dones), t0: d.start, frozen: d.since - d.start, doneUntil: d.since + doneHold, agents: agents(dones), acts: d.acts, counts: d.counts)
        }
        return nil
    }

    private func idleSeconds() -> Double {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    /// Show 30 s before the system would blank the display; 5 min if it never does.
    private func refreshThreshold() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["-g"]
        let pipe = Pipe()
        p.standardOutput = pipe
        guard (try? p.run()) != nil else { return }
        p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: " ")
            if parts.count >= 2, parts[0] == "displaysleep", let m = Int(parts[1]) {
                threshold = m == 0 ? 300 : max(30, Double(m * 60) - 30)
            }
        }
    }

    /// Something else (a video, a presentation) is already keeping the display on.
    private func othersKeepDisplayOn() -> Bool {
        var dict: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsStatus(&dict) == kIOReturnSuccess,
              let d = dict?.takeRetainedValue() as? [String: Int] else { return false }
        return (d["PreventUserIdleDisplaySleep"] ?? 0) > 0
    }

    // MARK: - Loop

    private func tick() {
        ticks += 1
        if ticks % 600 == 0 { refreshThreshold() }   // every 5 min
        let now = Date().timeIntervalSince1970
        if ticks % 4 == 1 { pollImageGen(now: now) }   // every 2 s
        let sessions = allSessions(now: now)
        // Any job still running — even if another one waits for approval.
        keepAwake(enabled && sessions.contains { $0.state == "work" && now - $0.updated < Self.staleAfter })
        let current = Self.summarize(sessions, now: now)
        if current != nil || showing { refreshQuotaIfStale() }
        let idle = idleSeconds()
        if showing {
            // The user is back (ignore the first 1.5 s so the screen doesn't close itself):
            // the first touch turns the screen into a short recap card instead of closing it.
            if idle < 0.4 && Date().timeIntervalSince(shownAt) > 1.5 && !recapMode {
                if forced { hide() } else { enterRecap() }
                return
            }
            if recapMode {
                if Date() >= recapUntil { hide() }
                return
            }
            if let current { push(current) } else if !forced {
                // งานจบครบ 5 นาทีแล้ว และผู้ใช้ยังไม่กลับมา: ปิดหน้าจอพักแล้วดับจอทันทีเหมือนพักเครื่องจริง
                hide(returnFocus: false)
                if idle >= threshold { sleepDisplayNow() }
            }
        } else if enabled, idle >= threshold, let sum = current, !othersKeepDisplayOn() {
            show(sum)
        }
    }

    private func refreshQuotaIfStale() {
        guard !quotaBusy, Date().timeIntervalSince(quotaAt) > 600 else { return }
        quotaBusy = true
        Task.detached(priority: .utility) {
            var q: [String: Any]?
            if let real = ClaudeQuotaFetcher.cachedOnly(), let s = real.session {
                q = ["u": Int(s.utilization.rounded()), "r": (s.resetsAt?.timeIntervalSince1970 ?? 0) * 1000, "est": false]
                if let w = real.weekly.first(where: { $0.name.isEmpty }) ?? real.weekly.first { q?["w"] = Int(w.window.utilization.rounded()) }
            } else {
                let u = ClaudeUsageTracker.compute()
                if u.blockEnd != nil {
                    q = ["u": 100 - u.remainingPercent, "r": (u.blockEnd?.timeIntervalSince1970 ?? 0) * 1000, "est": true]
                } else {
                    q = ["u": 0, "r": 0, "est": true]   // ยังไม่ได้ใช้ในรอบนี้ = เต็ม
                }
            }
            let result = q
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.quota = result
                self.quotaAt = Date()
                self.quotaBusy = false
                self.lastPayload = ""   // ให้หน้าจอได้ค่าใหม่รอบถัดไป
            }
        }
    }

    private func allSessions(now: Double) -> [Session] {
        Self.readSessions() + imageGenSessions(now: now)
    }

    private func pollImageGen(now: Double) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-f", "/slidegen/slidegen|mflux-generate"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return }
        p.waitUntilExit()
        if p.terminationStatus == 0 {
            if genSince == nil { genSince = now }
            genDone = nil
        } else if let start = genSince {
            genSince = nil
            genDone = (start, now)
        }
    }

    private func imageGenSessions(now: Double) -> [Session] {
        if let s = genSince {
            return [Session(state: "work", start: s, since: s, updated: now, label: "สร้างภาพ", agent: "local")]
        }
        if let d = genDone, now - d.at < Self.doneHold {
            return [Session(state: "done", start: d.start, since: d.at, updated: d.at, label: "สร้างภาพ", agent: "local")]
        }
        return []
    }

    private func sleepDisplayNow() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["displaysleepnow"]
        try? p.run()
    }

    private func keepAwake(_ on: Bool) {
        if on, awakeAssertion == 0 {
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                        IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                        "StampLab: AI job still running" as CFString, &awakeAssertion)
        } else if !on, awakeAssertion != 0 {
            IOPMAssertionRelease(awakeAssertion)
            awakeAssertion = 0
        }
    }

    /// Settings "preview" button: show now with the live state, or a sample.
    func preview() {
        forced = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            let now = Date().timeIntervalSince1970
            self.show(Self.summarize(self.allSessions(now: now), now: now)
                      ?? Summary(state: "work", label: "ตัวอย่าง", t0: now - 724, frozen: nil, doneUntil: 0, agents: ["claude"]))
        }
    }

    // MARK: - Welcome-back recap

    private func enterRecap() {
        let now = Date().timeIntervalSince1970
        let sessions = allSessions(now: now)
        let live = sessions.filter { now - $0.updated < Self.staleAfter }
        let done = sessions.filter { $0.state == "done" && $0.since >= awayStart }
        let wait = live.filter { $0.state == "wait" }
        let work = live.filter { $0.state == "work" }
        guard !(done.isEmpty && wait.isEmpty && work.isEmpty) else { hide(); return }
        recapMode = true
        recapUntil = Date().addingTimeInterval(4.5)
        let o: [String: Any] = ["away": max(0, now - awayStart), "done": done.map(\.label), "wait": wait.map(\.label), "work": work.count]
        guard let d = try? JSONSerialization.data(withJSONObject: o), let js = String(data: d, encoding: .utf8) else { return }
        for (_, web) in panels { web.evaluateJavaScript("recap(\(js))") }
    }

    /// Enter บนการ์ด: ปิดหน้าจอพักแล้วเปิดแอป Claude
    private func jumpToWork() {
        hide(returnFocus: false)
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    private func testRecap() {
        let now = Date().timeIntervalSince1970
        if !showing {
            show(Self.summarize(allSessions(now: now), now: now)
                 ?? Summary(state: "work", label: "ตัวอย่าง", t0: now - 724, frozen: nil, doneUntil: 0, agents: ["claude"]))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, self.showing else { return }
            self.awayStart = Date().timeIntervalSince1970 - 42 * 60
            self.enterRecap()
        }
    }

    private func payload(_ s: Summary) -> String {
        let o: [String: Any] = ["state": s.state, "label": s.label, "t0": s.t0 * 1000, "agents": s.agents,
                                "acts": s.acts, "n": s.counts, "q": quota ?? NSNull(),
                                "frozen": s.frozen ?? NSNull(), "doneUntil": s.doneUntil * 1000]
        guard let d = try? JSONSerialization.data(withJSONObject: o) else { return "{}" }
        return String(data: d, encoding: .utf8) ?? "{}"
    }

    private func push(_ s: Summary) {
        let p = payload(s)
        guard p != lastPayload else { return }
        lastPayload = p
        for (_, web) in panels { web.evaluateJavaScript("update(\(p))") }
    }

    private func show(_ s: Summary) {
        if showing { push(s); return }
        guard let html = Bundle.main.url(forResource: "ambient", withExtension: "html") else { return }
        showing = true
        shownAt = Date()
        recapMode = false
        awayStart = Date().timeIntervalSince1970 - idleSeconds()
        // ปุ่มบนหน้าจอพัก: แตะครั้งแรก = ขึ้นการ์ดสรุป, Enter = ไปที่งาน, ปุ่มอื่น/คลิก = ปิด
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self] e in
            guard let self, self.showing else { return e }
            if self.forced { self.hide(); return nil }
            if !self.recapMode { self.enterRecap(); return nil }
            if e.type == .keyDown && (e.keyCode == 36 || e.keyCode == 76) { self.jumpToWork() } else { self.hide() }
            return nil
        }
        lastPayload = ""
        pendingPayload = payload(s)
        previousApp = NSWorkspace.shared.frontmostApplication
        IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                    IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                    "StampLab: ambient screen" as CFString, &assertion)
        for screen in NSScreen.screens {
            let panel = KeyablePanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                     backing: .buffered, defer: false)
            panel.level = .screenSaver
            panel.backgroundColor = .black
            panel.isOpaque = true
            panel.hasShadow = false
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            panel.setFrame(screen.frame, display: true)
            let web = WKWebView(frame: panel.contentView!.bounds)
            web.autoresizingMask = [.width, .height]
            web.setValue(false, forKey: "drawsBackground")
            web.navigationDelegate = self
            web.loadFileURL(html, allowingReadAccessTo: html.deletingLastPathComponent())
            panel.contentView!.addSubview(web)
            panel.orderFrontRegardless()
            panels.append((panel, web))
        }
        // Take key focus so a key press that dismisses the screen doesn't type into the app underneath.
        NSApp.activate(ignoringOtherApps: true)
        panels.first?.0.makeKey()
        NSCursor.setHiddenUntilMouseMoves(true)
    }

    private func hide(returnFocus: Bool = true) {
        guard showing else { return }
        showing = false
        forced = false
        recapMode = false
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        for (p, web) in panels {
            web.navigationDelegate = nil
            p.orderOut(nil)
        }
        panels.removeAll()
        if assertion != 0 { IOPMAssertionRelease(assertion); assertion = 0 }
        if returnFocus { previousApp?.activate() }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            webView.evaluateJavaScript("update(\(self.pendingPayload))")
            self.lastPayload = self.pendingPayload
        }
    }
}

private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

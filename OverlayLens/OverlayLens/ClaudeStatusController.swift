import AppKit
import UserNotifications

/// Menu bar item showing an orange blocky robot mascot (drawn as pixel art)
/// with a soft orange glow. The robot scuttles — legs alternating — while
/// any Claude process is actively using CPU, sits still while Claude is
/// open but idle, and dims to a faint ghost when no Claude process is
/// running. Clicking it opens a menu with the current state and how many
/// tokens remain in the 5-hour block.
@MainActor
final class ClaudeStatusController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private var pollTimer: Timer?
    private var animationTimer: Timer?
    private var frameIndex = 0

    private enum ClaudeState {
        case notRunning
        case idle
        case busy
    }

    private var state: ClaudeState = .notRunning
    private var lastCPU: Double = 0

    // Token usage is parsed from multi-MB transcript files (~seconds), so
    // it's computed off the main thread — periodically for the icon's bar
    // and low-token tint, and on demand when the menu opens.
    private var cachedUsage: ClaudeUsage?
    private var cachedUsageAt: Date?
    private var usageTimer: Timer?
    private var lastScheduledReset: Date?

    // Real quota percentages from the claude.ai usage endpoint; nil when the
    // fetch fails (offline, logged out) — then the local estimate is shown.
    private var cachedQuota: ClaudeQuota?

    /// Remaining % for the icon bar / warning tint: real session number when
    /// available, otherwise the local estimate.
    private var remainingPercent: Int? {
        if let session = cachedQuota?.session {
            return max(0, 100 - Int(session.utilization.rounded()))
        }
        return cachedUsage?.remainingPercent
    }

    /// When the current 5-hour window resets (real value preferred).
    private var resetDate: Date? {
        cachedQuota?.session?.resetsAt ?? cachedUsage?.blockEnd
    }

    /// Out of tokens: the dog sleeps until the window resets. A reset time
    /// in the past means the data is stale, not that we're still limited.
    private var isLimited: Bool {
        guard let remaining = remainingPercent, remaining <= 0 else { return false }
        if let reset = resetDate, reset <= Date() { return false }
        return true
    }

    /// Claude brand orange (Crail).
    private static let orange = NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1.0)

    /// CPU% (summed over all claude processes) above which the crab walks.
    private static let busyThreshold: Double = 5.0

    // Pixel grids: "#" body, "E" eye, "." transparent. Two frames that
    // differ only in the legs so the robot looks like it's scuttling.
    private static let frames: [[String]] = [
        [
            ".##############.",
            ".##############.",
            ".###EE####EE###.",
            "####EE####EE####",
            "################",
            ".##############.",
            ".##############.",
            "..##.##..##.##..",
            "..##.##..##.##..",
        ],
        [
            ".##############.",
            ".##############.",
            ".###EE####EE###.",
            "####EE####EE####",
            "################",
            ".##############.",
            ".##############.",
            ".##..##..##..##.",
            ".##..##..##..##.",
        ],
    ]

    /// Eyes-closed frame shown while sleeping (limit reached).
    private static let sleepFrame: [String] = [
        ".##############.",
        ".##############.",
        ".##############.",
        "####EE####EE####",
        "################",
        ".##############.",
        ".##############.",
        "..##.##..##.##..",
        "..##.##..##.##..",
    ]

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu

        render()

        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        poll()

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        usageTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshUsage() }
        }
        refreshUsage()
    }

    deinit {
        pollTimer?.invalidate()
        animationTimer?.invalidate()
        usageTimer?.invalidate()
    }

    // MARK: - Claude process detection

    private func poll() {
        Task.detached(priority: .utility) {
            let sample = Self.sampleClaude()
            await MainActor.run { [weak self] in
                self?.apply(running: sample.running, cpu: sample.cpu)
            }
        }
    }

    private func apply(running: Bool, cpu: Double) {
        lastCPU = cpu
        let newState: ClaudeState = !running ? .notRunning
            : (cpu >= Self.busyThreshold ? .busy : .idle)
        guard newState != state else { return }
        state = newState

        if state == .busy && !isLimited {
            startAnimating()
        } else {
            stopAnimating()
        }
        render()
    }

    /// Sums CPU% across every process whose name contains "claude"
    /// (Claude.app, its helpers, and the claude CLI).
    nonisolated private static func sampleClaude() -> (running: Bool, cpu: Double) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-axo", "%cpu=,comm="]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
        } catch {
            return (false, 0)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return (false, 0) }

        var running = false
        var cpu: Double = 0
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let space = trimmed.firstIndex(of: " ") else { continue }
            let name = (String(trimmed[trimmed.index(after: space)...])
                .trimmingCharacters(in: .whitespaces) as NSString)
                .lastPathComponent.lowercased()
            guard name.contains("claude") else { continue }
            running = true
            cpu += Double(trimmed[..<space]) ?? 0
        }
        return (running, cpu)
    }

    // MARK: - Animation

    private func startAnimating() {
        guard animationTimer == nil else { return }
        animationTimer = Timer.scheduledTimer(withTimeInterval: 0.28, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.frameIndex = (self.frameIndex + 1) % Self.frames.count
                self.render()
            }
        }
    }

    private func stopAnimating() {
        animationTimer?.invalidate()
        animationTimer = nil
        frameIndex = 0
    }

    // MARK: - Drawing

    private func render() {
        let sleeping = isLimited
        let dimmed = state == .notRunning || sleeping
        let remaining = remainingPercent
        statusItem.button?.image = Self.makeRobotImage(
            rows: sleeping ? Self.sleepFrame : Self.frames[frameIndex],
            dimmed: dimmed,
            remaining: remaining,
            sleeping: sleeping
        )
        var tip: String
        if sleeping {
            tip = "น้องหมาหลับอยู่ — ติดลิมิตแล้ว"
            if let reset = resetDate {
                tip += " ใช้ได้ใหม่\(Self.resetPhrase(reset))"
            }
        } else {
            tip = switch state {
            case .notRunning: "Claude ไม่ได้เปิดอยู่"
            case .idle: "Claude เปิดอยู่ (ว่าง)"
            case .busy: "Claude กำลังทำงาน"
            }
            if let remaining {
                tip += cachedQuota != nil
                    ? " — โทเคนเหลือ \(remaining)%"
                    : " — โทเคนเหลือ ≈\(remaining)%"
            }
        }
        statusItem.button?.toolTip = tip
    }

    /// "ตอน 12:00 น. (อีก 3 ชม. 24 นาที)"
    private static func resetPhrase(_ reset: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        let minutes = max(0, Int(reset.timeIntervalSinceNow / 60))
        let hours = minutes / 60
        let mins = minutes % 60
        let dur = hours > 0 && mins > 0 ? "\(hours) ชม. \(mins) นาที"
            : hours > 0 ? "\(hours) ชม." : "\(mins) นาที"
        return "ตอน \(fmt.string(from: reset)) น. (อีก \(dur))"
    }

    // MARK: - Usage refresh + reset notification

    private func refreshUsage(completion: (@MainActor () -> Void)? = nil) {
        Task.detached(priority: .utility) {
            async let quota = ClaudeQuotaFetcher.fetch()
            let usage = ClaudeUsageTracker.compute()
            let fetchedQuota = await quota
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.cachedUsage = usage
                if let fetchedQuota {
                    self.cachedQuota = fetchedQuota
                    self.quotaRetryDelay = 60
                } else if self.cachedQuota == nil {
                    // Usage endpoint rate-limits aggressively; keep retrying
                    // with backoff until the first real reading lands so the
                    // icon bar can stop showing the rough estimate.
                    self.scheduleQuotaRetry()
                }
                self.cachedUsageAt = Date()
                self.render()
                self.scheduleResetNotification(
                    at: self.cachedQuota?.session?.resetsAt ?? usage.blockEnd
                )
                completion?()
            }
        }
    }

    private var quotaRetryTimer: Timer?
    private var quotaRetryDelay: TimeInterval = 60

    private func scheduleQuotaRetry() {
        guard quotaRetryTimer == nil else { return }
        quotaRetryTimer = Timer.scheduledTimer(withTimeInterval: quotaRetryDelay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.quotaRetryTimer = nil
                self?.refreshUsage()
            }
        }
        quotaRetryDelay = min(quotaRetryDelay * 1.5, 300)
    }

    /// Posts a local notification the moment the current 5-hour block ends.
    private func scheduleResetNotification(at end: Date?) {
        guard let end, end != lastScheduledReset else { return }
        lastScheduledReset = end
        let interval = end.timeIntervalSinceNow
        guard interval > 1 else { return }

        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ["token-reset"])
        let content = UNMutableNotificationContent()
        content.title = "โทเคน Claude รีเซ็ตแล้ว 🎉"
        content.body = "รอบ 5 ชั่วโมงใหม่เริ่มแล้ว ใช้งานได้เต็มที่เลย"
        content.sound = .default
        center.add(UNNotificationRequest(
            identifier: "token-reset",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        ))
    }

    /// Soft light-orange halo drawn around the robot (skipped while dimmed).
    private static let glow = NSColor(srgbRed: 1.0, green: 0.72, blue: 0.5, alpha: 0.85)

    /// Below this remaining-% the robot turns red as a low-token warning.
    private static let lowThreshold = 15

    private static func makeRobotImage(
        rows: [String],
        dimmed: Bool,
        remaining: Int?,
        sleeping: Bool = false
    ) -> NSImage {
        let cell: CGFloat = 1.5
        let glowMargin: CGFloat = 4
        let cols = rows[0].count
        let gridWidth = CGFloat(cols) * cell
        let gridHeight = CGFloat(rows.count) * cell
        let size = NSSize(width: gridWidth + glowMargin * 2, height: 22)

        let low = (remaining ?? 100) <= lowThreshold
        let bodyBase = low ? NSColor.systemRed : orange
        let body = dimmed ? bodyBase.withAlphaComponent(0.3) : bodyBase
        let eye = dimmed ? NSColor.black.withAlphaComponent(0.3) : NSColor.black
        let glowColor = low ? NSColor.systemRed.withAlphaComponent(0.7) : glow

        let image = NSImage(size: size, flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            // Sit the robot slightly high so the token bar fits underneath.
            let top: CGFloat = remaining == nil ? (rect.height - gridHeight) / 2 : 2.5

            func cellRect(_ x: Int, _ y: Int) -> NSRect {
                NSRect(
                    x: glowMargin + CGFloat(x) * cell,
                    y: top + CGFloat(y) * cell,
                    width: cell,
                    height: cell
                )
            }

            // Glow: fill the whole silhouette once with a blurred shadow so a
            // soft light-orange halo forms around the body's outline.
            if !dimmed {
                let silhouette = CGMutablePath()
                for (y, row) in rows.enumerated() {
                    for (x, ch) in row.enumerated() where ch != "." {
                        silhouette.addRect(cellRect(x, y))
                    }
                }
                ctx.saveGState()
                ctx.setShadow(offset: .zero, blur: 5, color: glowColor.cgColor)
                ctx.addPath(silhouette)
                ctx.setFillColor(body.cgColor)
                ctx.fillPath()
                ctx.restoreGState()
            }

            ctx.setShouldAntialias(false)
            for (y, row) in rows.enumerated() {
                for (x, ch) in row.enumerated() {
                    guard ch != "." else { continue }
                    (ch == "E" ? eye : body).setFill()
                    cellRect(x, y).fill()
                }
            }

            // "Zz" floating by the head while sleeping.
            if sleeping {
                ctx.setShouldAntialias(true)
                let zz = NSAttributedString(
                    string: "z",
                    attributes: [
                        .font: NSFont.boldSystemFont(ofSize: 7),
                        .foregroundColor: NSColor.labelColor.withAlphaComponent(0.8),
                    ]
                )
                zz.draw(at: NSPoint(x: glowMargin + gridWidth - 3, y: -1))
            }

            // Token bar under the robot: fill width = remaining percent.
            if let remaining {
                ctx.setShouldAntialias(true)
                let barY = top + gridHeight + 1.5
                let track = NSRect(x: glowMargin, y: barY, width: gridWidth, height: 2)
                NSColor.labelColor.withAlphaComponent(0.18).setFill()
                NSBezierPath(roundedRect: track, xRadius: 1, yRadius: 1).fill()

                var fill = track
                fill.size.width = gridWidth * CGFloat(remaining) / 100
                let fillColor: NSColor = remaining > 40 ? .systemGreen
                    : remaining > lowThreshold
                        ? NSColor(srgbRed: 0.80, green: 0.55, blue: 0.02, alpha: 1.0)
                        : .systemRed
                fillColor.withAlphaComponent(dimmed ? 0.35 : 0.95).setFill()
                NSBezierPath(roundedRect: fill, xRadius: 1, yRadius: 1).fill()
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    // MARK: - Dropdown menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let header = NSMenuItem()
        let title: String
        if isLimited {
            title = "Claude — นอนพัก 😴"
        } else {
            title = switch state {
            case .notRunning: "Claude — ไม่ได้เปิดอยู่"
            case .idle: "Claude — เปิดอยู่ (ว่าง)"
            case .busy: "Claude — กำลังทำงาน 🔥"
            }
        }
        header.attributedTitle = NSAttributedString(
            string: title,
            attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)]
        )
        header.isEnabled = true
        menu.addItem(header)

        if isLimited {
            menu.addItem(Self.infoItem("ติดลิมิตการใช้งานแล้ว น้องหมาขอหลับก่อน"))
            if let reset = resetDate {
                menu.addItem(Self.infoItem("⏰ ใช้ได้ใหม่\(Self.resetPhrase(reset))"))
            }
        } else {
            menu.addItem(Self.infoItem(
                state == .busy
                    ? "น้องหมาจะโยกหัวไปเรื่อยๆ จนกว่า Claude จะทำงานเสร็จ"
                    : "น้องหมาจะขยับเมื่อ Claude เริ่มทำงาน"
            ))
        }
    }

    private static func infoItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = true
        return item
    }
}

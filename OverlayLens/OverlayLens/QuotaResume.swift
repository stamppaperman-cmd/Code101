import AppKit
import IOKit.ps
import IOKit.pwr_mgt
import SwiftUI

/// ทำต่ออัตโนมัติเมื่อโควตารีเซ็ต — switched from the menu's quota row
/// (QuotaMenu.swift) together with กะดึก, or alone in Settings › โควตา Claude.
///
/// On/off is Claude Code's own `autoContinueAtUsageLimit` in ~/.claude/settings.json:
/// a chat stopped by a claude.ai usage limit waits in place and continues at the
/// reset. StampLab adds what Claude Code can't do by itself: ambient-hook's
/// `stopfail` writes .../StampLab/quota/<session>.json, so the menu can list the
/// chats waiting and when they continue, and StampLab keeps the Mac awake until
/// then — after more than ~30 minutes of sleep Claude Code waits for Enter instead.
@MainActor
final class QuotaResume: ObservableObject {
    static let shared = QuotaResume()

    struct Paused: Identifiable, Equatable {
        let id: String
        let title: String
        let pausedAt: Date
        let resetAt: Date?
        /// waiting · stale (slept too long, needs Enter) · disabled (Claude gave up)
        let state: String

        /// When to stop waiting for this chat: the reset plus slack, or the
        /// 5-hour window when the message carried no reset time.
        var deadline: Date {
            (resetAt ?? pausedAt.addingTimeInterval(5 * 3600)).addingTimeInterval(15 * 60)
        }
    }

    @Published private(set) var isOn = true
    @Published private(set) var paused: [Paused] = []
    @Published private(set) var holdingAwake = false
    @Published var keepAwake: Bool {
        didSet {
            UserDefaults.standard.set(keepAwake, forKey: Self.keepAwakeKey)
            updateAwake()
        }
    }

    static let folder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/StampLab/quota")
    private static let settingsURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/settings.json")
    private static let settingKey = "autoContinueAtUsageLimit"
    private static let keepAwakeKey = "QuotaKeepAwake"

    private var timer: Timer?
    private var assertion: IOPMAssertionID = 0

    private init() {
        keepAwake = UserDefaults.standard.object(forKey: Self.keepAwakeKey) as? Bool ?? true
    }

    func start() {
        reload()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    func reload() {
        isOn = Self.readSetting()
        paused = Self.readPaused()
        updateAwake()
    }

    /// The switch. Writes the official setting so terminal sessions obey it too.
    func setOn(_ on: Bool) {
        Self.writeSetting(on)
        reload()
    }

    /// Chats still worth waiting for (their reset hasn't long passed).
    var waiting: [Paused] {
        let now = Date()
        return paused.filter { $0.state == "waiting" && now < $0.deadline }
    }

    /// Chats whose reset came and went without them moving.
    var stuck: [Paused] {
        let now = Date()
        return paused.filter { $0.state != "waiting" || now >= $0.deadline }
    }

    static func clock(_ date: Date?) -> String {
        guard let date else { return "เมื่อโควตารีเซ็ต" }
        let formatter = DateFormatter()
        formatter.dateFormat = Calendar.current.isDateInToday(date) || Calendar.current.isDateInTomorrow(date)
            ? "HH:mm" : "EEE HH:mm"
        formatter.locale = Locale(identifier: "th_TH")
        return formatter.string(from: date)
    }

    func openClaude() {
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop") {
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    /// Forget a chat the user handled by hand.
    func dismiss(_ id: String) {
        try? FileManager.default.removeItem(at: Self.folder.appendingPathComponent(id + ".json"))
        reload()
    }

    // MARK: Keep awake

    /// Only on AC power (the user's choice): the system-sleep assertion lets the
    /// display sleep but keeps Claude Code's wait alive until the reset.
    private func updateAwake() {
        let want = isOn && keepAwake && !waiting.isEmpty && Self.onACPower()
        if want, assertion == 0 {
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                        IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                        "StampLab: รอโควตา Claude รีเซ็ตเพื่อทำต่อ" as CFString,
                                        &assertion)
        } else if !want, assertion != 0 {
            IOPMAssertionRelease(assertion)
            assertion = 0
        }
        holdingAwake = assertion != 0
    }

    private static func onACPower() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        else { return true }   // a desktop Mac reports no battery
        return type == "AC Power"
    }

    // MARK: Files

    private static func readPaused() -> [Paused] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let now = Date()
        return files.filter { $0.pathExtension == "json" }.compactMap { url -> Paused? in
            guard let data = try? Data(contentsOf: url),
                  let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pausedAt = (record["pausedAt"] as? Double).map(Date.init(timeIntervalSince1970:))
            else { return nil }
            // Week-old leftovers (a chat closed while waiting) only clutter the menu.
            if now.timeIntervalSince(pausedAt) > 7 * 86400 {
                try? FileManager.default.removeItem(at: url)
                return nil
            }
            let cwd = (record["cwd"] as? String) ?? ""
            let title = (record["title"] as? String)
                ?? (cwd.isEmpty ? "แชต Claude" : (cwd as NSString).lastPathComponent)
            return Paused(id: url.deletingPathExtension().lastPathComponent,
                          title: title,
                          pausedAt: pausedAt,
                          resetAt: (record["resetAt"] as? Double).map(Date.init(timeIntervalSince1970:)),
                          state: (record["state"] as? String) ?? "waiting")
        }
        .sorted { $0.pausedAt > $1.pausedAt }
    }

    /// Missing key = Claude Code's default, which is on.
    private static func readSetting() -> Bool {
        guard let data = try? Data(contentsOf: settingsURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return true }
        return object[settingKey] as? Bool ?? true
    }

    /// Edits only this key's text so the rest of settings.json (hooks, order,
    /// formatting) stays exactly as it was; refuses to save anything that no
    /// longer parses.
    @discardableResult
    private static func writeSetting(_ on: Bool) -> Bool {
        guard var text = try? String(contentsOf: settingsURL, encoding: .utf8) else { return false }
        let pair = "\"\(settingKey)\": \(on)"
        if let range = text.range(of: "\"\(settingKey)\"\\s*:\\s*(true|false)", options: .regularExpression) {
            text.replaceSubrange(range, with: pair)
        } else if let brace = text.firstIndex(of: "{") {
            let rest = text[text.index(after: brace)...].trimmingCharacters(in: .whitespacesAndNewlines)
            text.insert(contentsOf: "\n  " + pair + (rest.hasPrefix("}") ? "" : ","), at: text.index(after: brace))
        } else {
            return false
        }
        guard let data = text.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else { return false }
        return (try? data.write(to: settingsURL, options: .atomic)) != nil
    }
}

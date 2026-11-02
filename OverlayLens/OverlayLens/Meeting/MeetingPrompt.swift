import AppKit
import SwiftUI

/// Asks "record & summarise?" when a call app (Zoom / Teams / Discord / LINE / Webex)
/// is launched or comes to the front. Never records without a click.
@MainActor
final class MeetingPromptController {
    static let apps: [String: String] = [
        "us.zoom.xos": "Zoom",
        "com.microsoft.teams2": "Teams",
        "com.microsoft.teams": "Teams",
        "com.hnc.Discord": "Discord",
        "jp.naver.line.mac": "LINE",
        "com.cisco.webexmeetingsapp": "Webex",
    ]
    nonisolated static let enabledKey = "MeetingPromptEnabled"
    nonisolated static let mutedKey = "MeetingPromptMuted"
    private static let cooldown: TimeInterval = 30 * 60
    private static let timeout: TimeInterval = 30

    private weak var recorder: MeetingRecorderController?
    private var observers: [NSObjectProtocol] = []
    private var lastPrompt: [String: Date] = [:]
    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?

    init(recorder: MeetingRecorderController) {
        self.recorder = recorder
        UserDefaults.standard.register(defaults: [Self.enabledKey: true])
        let nc = NSWorkspace.shared.notificationCenter
        observers.append(nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
                                        object: nil, queue: .main) { [weak self] n in
            let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.consider(app, launched: true) }
        })
        observers.append(nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                        object: nil, queue: .main) { [weak self] n in
            let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.consider(app, launched: false) }
        })
    }

    nonisolated static let logURL: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("OverlayLens/meeting-prompt.log")

    private func log(_ s: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
        if let h = try? FileHandle(forWritingTo: Self.logURL) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? line.write(to: Self.logURL, atomically: true, encoding: .utf8)
        }
    }

    /// Automation: `notifyutil -p com.overlaylens.meeting.prompt` shows the card for LINE.
    func showTest() { present(name: "LINE (ทดสอบ)", id: "jp.naver.line.mac.test") }

    private func consider(_ app: NSRunningApplication?, launched: Bool) {
        if let id = app?.bundleIdentifier, Self.apps[id] != nil {
            log("event \(id) launched=\(launched) enabled=\(UserDefaults.standard.bool(forKey: Self.enabledKey)) phase=\(String(describing: recorder?.model.phase))")
        }
        guard UserDefaults.standard.bool(forKey: Self.enabledKey),
              let id = app?.bundleIdentifier, let name = Self.apps[id],
              let recorder, !recorder.model.isRecording, !recorder.model.isBusy,
              recorder.model.phase == .idle || recorder.model.phase == .done
        else { return }
        let muted = UserDefaults.standard.stringArray(forKey: Self.mutedKey) ?? []
        guard !muted.contains(id) else { return }
        if let last = lastPrompt[id], Date().timeIntervalSince(last) < Self.cooldown { return }
        if panel?.isVisible == true { return }
        lastPrompt[id] = Date()
        log("present \(id)")
        present(name: name, id: id)
    }

    private func present(name: String, id: String) {
        let view = MeetingPromptView(
            appName: name,
            onRecord: { [weak self] in
                self?.close()
                self?.recorder?.hotkeyPressed()
            },
            onSkip: { [weak self] in self?.close() },
            onMute: { [weak self] in
                var m = UserDefaults.standard.stringArray(forKey: Self.mutedKey) ?? []
                if !m.contains(id) { m.append(id) }
                UserDefaults.standard.set(m, forKey: Self.mutedKey)
                self?.close()
            })
        let host = NSHostingController(rootView: view)
        let size = NSSize(width: 340, height: 150)
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                        backing: .buffered, defer: false)
        p.contentViewController = host
        p.setContentSize(size)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        if let s = NSScreen.main?.visibleFrame {
            p.setFrameOrigin(NSPoint(x: s.maxX - size.width - 16, y: s.maxY - size.height - 16))
        }
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.18; p.animator().alphaValue = 1 }
        panel = p
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.timeout * 1_000_000_000))
            if !Task.isCancelled { self?.close() }
        }
    }

    private func close() {
        dismissTask?.cancel()
        guard let p = panel else { return }
        panel = nil
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.15; p.animator().alphaValue = 0 },
                                             completionHandler: { p.orderOut(nil) })
    }
}

private struct MeetingPromptView: View {
    let appName: String
    let onRecord: () -> Void
    let onSkip: () -> Void
    let onMute: () -> Void
    private let clay = Color(red: 0.851, green: 0.467, blue: 0.341)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "waveform.circle.fill").foregroundStyle(clay).font(.title3)
                Text("ตรวจพบ \(appName)").font(.headline)
            }
            Text("อัดเสียงและสรุปการประชุมนี้ไหม?")
                .font(.subheadline).foregroundStyle(.secondary)
            HStack {
                Button(action: onRecord) { Text("อัดเลย").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).tint(clay)
                Button(action: onSkip) { Text("ไม่ต้อง").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered)
            }
            Button("ไม่ต้องถาม \(appName) อีก", action: onMute)
                .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 340, height: 150, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

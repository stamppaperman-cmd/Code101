import AppKit
import SwiftUI

/// Claude Code permission prompts, answerable from a card at the top right
/// (see ClaudeApproval for the hook side). Requests queue oldest first; the
/// card shows one at a time and goes away when the queue is empty.
@MainActor
final class ClaudeApprovalModel: ObservableObject {
    @Published private(set) var requests: [ClaudeApproval.Request] = []

    /// Re-reads the request folder, dropping requests nobody waits for any
    /// more: the hook ended (answered in Claude Code, or timed out), or the
    /// session's record shows the prompt was settled there.
    func reload() {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: ClaudeApproval.folder, includingPropertiesForKeys: nil)) ?? []
        let now = Date().timeIntervalSince1970
        var live: [ClaudeApproval.Request] = []
        for url in files where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let request = try? JSONDecoder().decode(ClaudeApproval.Request.self, from: data) else { continue }
            let hookAlive = kill(request.pid, 0) == 0 || errno == EPERM
            let expired = now - request.created > ClaudeApproval.waitSeconds + 10
            let settled = ClaudeApproval.isSettledElsewhere(
                requestCreated: request.created, inputKey: request.inputKey, session: session(request.session))
            if !hookAlive || expired || settled {
                // Removing the request also ends the hook's wait.
                try? fm.removeItem(at: url)
                try? fm.removeItem(at: ClaudeApproval.answerURL(request.id))
                continue
            }
            // Answered here; the hook picks it up within a moment.
            if fm.fileExists(atPath: ClaudeApproval.answerURL(request.id).path) { continue }
            live.append(request)
        }
        live.sort { $0.created < $1.created }
        if live != requests { requests = live }
    }

    func answer(_ request: ClaudeApproval.Request, _ answer: ClaudeApproval.Answer) {
        try? Data(answer.rawValue.utf8).write(to: ClaudeApproval.answerURL(request.id), options: .atomic)
        requests.removeAll { $0.id == request.id }
    }

    private func session(_ id: String) -> ClaudeApproval.SessionSnapshot? {
        let url = ClaudeApproval.sessionsFolder.appendingPathComponent(id + ".json")
        guard let data = try? Data(contentsOf: url),
              let record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return ClaudeApproval.SessionSnapshot(record: record)
    }
}

/// The rules saved with "อนุญาตเสมอ", for the menu and Settings to list and
/// undo. Reloaded when either appears — the hook writes the record, not the app.
@MainActor
final class ClaudeApprovalRules: ObservableObject {
    static let shared = ClaudeApprovalRules()

    @Published private(set) var rules: [ClaudeApproval.SavedRule] = []

    func reload() {
        let fresh = ClaudeApproval.savedRules()
        if fresh != rules { rules = fresh }
    }

    /// Takes the rule out of the project's settings too, so Claude Code asks
    /// about that command again.
    func forget(_ entry: ClaudeApproval.SavedRule) {
        ClaudeApproval.forget(entry)
        reload()
    }
}

@MainActor
final class ClaudeApprovalController {
    let model = ClaudeApprovalModel()
    private var panel: NSPanel?
    private var timer: Timer?

    /// Fixed panel with a top-anchored card (like the other widgets); the
    /// clear area below lets clicks through. Tall enough for the longest card:
    /// note, a full command, and the "อนุญาตเสมอ" row under the two buttons.
    static let panelSize = NSSize(width: 400, height: 460)

    init() {
        try? FileManager.default.createDirectory(at: ClaudeApproval.folder, withIntermediateDirectories: true)
        // Only a directory listing every 0.4 s; it's empty almost always.
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        model.reload()
        if model.requests.isEmpty {
            panel?.orderOut(nil)
        } else {
            show()
        }
    }

    private func show() {
        let panel = ensurePanel()
        guard !panel.isVisible else { return }
        if let visible = (NSScreen.screens.first ?? NSScreen.main)?.visibleFrame {
            panel.setFrameOrigin(NSPoint(
                x: visible.maxX - Self.panelSize.width - 10,
                y: visible.maxY - Self.panelSize.height
            ))
        }
        panel.orderFrontRegardless()
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let hosting = NSHostingController(rootView: ClaudeApprovalCard(model: model))
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = hosting
        panel.setContentSize(Self.panelSize)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        // Above the Finish Engine panel, which also lives top right.
        panel.level = .statusBar
        // A prompt is waiting wherever the user is: every Space, full screen too.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        self.panel = panel
        return panel
    }
}

private struct CardButtonStyle: ButtonStyle {
    let fill: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(fill.opacity(configuration.isPressed ? 0.7 : 1))
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

private struct ClaudeApprovalCard: View {
    @ObservedObject var model: ClaudeApprovalModel

    var body: some View {
        VStack(spacing: 0) {
            if let request = model.requests.first {
                card(request)
                    .id(request.id)
            }
            Spacer(minLength: 0)
        }
        .frame(
            width: ClaudeApprovalController.panelSize.width,
            height: ClaudeApprovalController.panelSize.height,
            alignment: .top)
        .environment(\.colorScheme, .dark)
    }

    private func card(_ request: ClaudeApproval.Request) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                Text("Claude ขออนุญาต").font(.system(size: 14, weight: .semibold))
                Spacer()
                if model.requests.count > 1 {
                    Text("รออีก \(model.requests.count - 1)")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 6) {
                Text(ClaudeApproval.toolLabel(request.tool))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(Color.white.opacity(0.14)))
                if !request.label.isEmpty {
                    Text(request.label).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            if !request.note.isEmpty {
                Text(request.note).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
            }
            if !request.detail.isEmpty {
                ScrollView {
                    Text(request.detail)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: 150)
                .fixedSize(horizontal: false, vertical: true)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.35)))
            }
            // Own style: the system ones turn grey while StampLab isn't the
            // active app, which is always the case for this panel.
            HStack(spacing: 8) {
                Button { model.answer(request, .deny) } label: {
                    Text("ปฏิเสธ").frame(maxWidth: .infinity, minHeight: 30)
                }
                .buttonStyle(CardButtonStyle(fill: Color.white.opacity(0.14)))
                Button { model.answer(request, .allow) } label: {
                    Text("อนุญาต").frame(maxWidth: .infinity, minHeight: 30)
                }
                .buttonStyle(CardButtonStyle(fill: Color(nsColor: .systemBlue)))
            }
            .font(.system(size: 13, weight: .semibold))
            // Only when Claude Code offered a rule for this prompt: a file
            // edit suggests none, and a whole-tool rule is filtered out.
            if !request.savableRules.isEmpty {
                alwaysButton(request)
            }
            Text("ตอบในหน้าต่าง Claude แทนก็ได้ ฝั่งไหนตอบก่อนใช้ฝั่งนั้น")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 372)
        .smokeGlass(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.top, 8)
    }

    /// Allow and let Claude Code remember it. Full width under the two
    /// buttons rather than a third one beside them: it needs the room to
    /// show the rule being saved, and the plain Allow stays the obvious one.
    private func alwaysButton(_ request: ClaudeApproval.Request) -> some View {
        Button { model.answer(request, .always) } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.shield.fill").font(.system(size: 11))
                    Text("อนุญาตเสมอ — ไม่ต้องถามอีก")
                        .font(.system(size: 13, weight: .semibold))
                }
                ForEach(request.savableRules, id: \.self) { rule in
                    Text(rule.display)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
        }
        .buttonStyle(CardButtonStyle(fill: Color.white.opacity(0.1)))
        .help("บันทึกกฎนี้ลง .claude/settings.local.json ของโปรเจกต์ ลบได้จากเมนู StampLab")
    }
}

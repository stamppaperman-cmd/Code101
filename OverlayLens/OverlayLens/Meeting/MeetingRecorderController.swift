import AppKit
import SwiftUI
@preconcurrency import UserNotifications

/// Borderless panels refuse key status by default, which would make the
/// context text field untypeable.
private final class MeetingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }
}

/// Floating "Meeting Notes" card. ⌃⌥⌘R starts / stops a recording from anywhere;
/// the menu row just shows or hides the card.
@MainActor
final class MeetingRecorderController: NSObject, UNUserNotificationCenterDelegate {
    let model = MeetingRecorderModel()
    private var panel: MeetingPanel?
    private var moveObserver: NSObjectProtocol?
    private var prompt: MeetingPromptController?

    nonisolated static let frameKey = "MeetingRecorderFrame"
    static let panelSize = NSSize(width: 372, height: 560)

    var isVisible: Bool { panel?.isVisible == true }

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
        installAutomationHooks()
        prompt = MeetingPromptController(recorder: self)
    }

    /// `notifyutil -p com.overlaylens.meeting.start | .stop | .toggle` — lets
    /// Shortcuts, Raycast or a shell script drive the recorder. `.import`
    /// transcribes a file without dragging it: write the path first with
    /// `defaults write com.overlaylens.OverlayLens MeetingImportPath /path/to/audio.m4a`.
    private func installAutomationHooks() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        for name in ["start", "stop", "toggle", "hide", "show", "prompt", "import"] {
            CFNotificationCenterAddObserver(
                center, observer,
                { _, observer, cfName, _, _ in
                    guard let observer, let raw = cfName?.rawValue as String? else { return }
                    let controller = Unmanaged<MeetingRecorderController>.fromOpaque(observer).takeUnretainedValue()
                    let action = raw.components(separatedBy: ".").last ?? ""
                    Task { @MainActor in controller.handleAutomation(action) }
                },
                "com.overlaylens.meeting.\(name)" as CFString, nil, .deliverImmediately)
        }
    }

    func handleAutomation(_ action: String) {
        switch action {
        case "start":
            guard !model.isRecording, !model.isBusy else { return }
            show()
            if model.phase != .idle { model.reset() }
            model.startRecording()
        case "stop":
            if model.isRecording { model.stopRecording() }
        case "hide":
            hide()
        case "show":
            show()
        case "prompt":
            prompt?.showTest()
        case "import":
            importFromDefaults()
        default:
            hotkeyPressed()
        }
    }

    /// The file named by the `MeetingImportPath` default (one path, or a list
    /// of them). The key is cleared afterwards so the same drop is not
    /// repeated by the next notification.
    private func importFromDefaults() {
        let defaults = UserDefaults.standard
        var paths: [String] = []
        if let one = defaults.string(forKey: "MeetingImportPath") {
            paths = [one]
        } else if let many = defaults.stringArray(forKey: "MeetingImportPath") {
            paths = many
        }
        defaults.removeObject(forKey: "MeetingImportPath")
        let urls = paths
            .map { ($0 as NSString).expandingTildeInPath }
            .map { URL(fileURLWithPath: $0) }
        guard !urls.isEmpty else { return }
        show()
        if model.phase != .idle, !model.isBusy, !model.isRecording { model.reset() }
        model.importFiles(urls)
    }

    func toggleVisibility() {
        isVisible ? hide() : show()
    }

    /// The hotkey: idle → open the card and start; recording → stop.
    func hotkeyPressed() {
        if model.isRecording {
            model.stopRecording()
            show()
        } else if !model.isBusy {
            show()
            if model.phase != .idle { model.reset() }
            model.startRecording()
        } else {
            show()
        }
    }

    func show() {
        let panel = ensurePanel()
        model.refreshRecent()
        if !panel.isVisible {
            position(panel)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                panel.animator().alphaValue = 1
            }
        } else {
            panel.orderFrontRegardless()
        }
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: { panel.orderOut(nil) })
    }

    private func ensurePanel() -> MeetingPanel {
        if let panel { return panel }
        let hosting = NSHostingController(
            rootView: MeetingRecorderView(model: model, onClose: { [weak self] in self?.hide() }))
        let panel = MeetingPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        panel.contentViewController = hosting
        panel.setContentSize(Self.panelSize)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        // Stays visible over full-screen Zoom / Teams and on every Space.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovableByWindowBackground = true
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main
        ) { note in
            guard let window = note.object as? NSWindow else { return }
            UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: MeetingRecorderController.frameKey)
        }
        self.panel = panel
        return panel
    }

    private func position(_ panel: NSPanel) {
        let size = Self.panelSize
        if let saved = UserDefaults.standard.string(forKey: Self.frameKey) {
            let frame = NSRectFromString(saved)
            if !frame.isEmpty, NSScreen.screens.contains(where: { $0.frame.intersects(frame) }) {
                panel.setFrameOrigin(NSPoint(x: frame.minX, y: frame.maxY - size.height))
                return
            }
        }
        guard let visible = (NSScreen.screens.first ?? NSScreen.main)?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(x: visible.maxX - size.width - 430, y: visible.maxY - size.height))
    }

    // MARK: - Notifications

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let path = response.notification.request.content.userInfo["path"] as? String {
            DispatchQueue.main.async {
                let url = URL(fileURLWithPath: path)
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
                if isDir.boolValue {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } else {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        completionHandler()
    }
}

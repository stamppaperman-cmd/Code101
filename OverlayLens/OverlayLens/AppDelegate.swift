import AppKit
import Carbon.HIToolbox
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: OverlayPanel?
    private var reader: ReaderPanel?
    private var quickTranslation: QuickTranslationController?
    private var shelfHotKey: HotKeyManager?
    private var translateHotKey: HotKeyManager?
    private var copyTextHotKey: HotKeyManager?
    private var finishEngineHotKey: HotKeyManager?
    private var meetingHotKey: HotKeyManager?
    private var revealPathHotKey: HotKeyManager?
    private var meeting: MeetingRecorderController?
    /// The Spotlight-style Finish Engine box; owns the Notion model the menu
    /// row reads too.
    private var finishEngine: FinishEngineSpotlight?
    private var claudeAmbient: ClaudeAmbientController?
    private var claudeApproval: ClaudeApprovalController?
    private var shakeToShelf: ShakeToShelf?
    private var menuBar: MenuBarController?
    private var dropShelf: DropShelfController?
    private var systemStats: SystemStatsController?
    private var claudeConnections: ClaudeConnectionsController?
    let viewModel = OverlayViewModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let dropShelf = DropShelfController()
        self.dropShelf = dropShelf
        systemStats = SystemStatsController()
        claudeConnections = ClaudeConnectionsController()
        // Before the menu bar controller: the menu row reads its model.
        let finishEngine = FinishEngineSpotlight()
        self.finishEngine = finishEngine
        QuotaResume.shared.start()
        let meeting = MeetingRecorderController()
        self.meeting = meeting
        quickTranslation = QuickTranslationController(model: viewModel)

        let claudeAmbient = ClaudeAmbientController()
        self.claudeAmbient = claudeAmbient
        claudeApproval = ClaudeApprovalController()
        quickTranslation?.onSaveToShelf = { [weak dropShelf] note in
            dropShelf?.model.addRaw(note)
            dropShelf?.show()
        }

        // One status item for everything — the menu bar has no room to spare.
        menuBar = MenuBarController(
            shelf: dropShelf,
            controls: AnyView(
                MenuBarControlsView(
                    viewModel: viewModel,
                    shelfModel: dropShelf.model,
                    finishModel: finishEngine.model,
                    onToggleStats: { [weak self] in self?.toggleSystemStatsWidget() },
                    onToggleConnections: { [weak self] in self?.toggleClaudeConnectionsWidget() },
                    onOpenDropShelf: { [weak self] in self?.menuBar?.toggleShelf() },
                    onToggleFinishEngine: { [weak self] in self?.toggleFinishEngine() },
                    meetingModel: meeting.model,
                    onToggleMeeting: { [weak self] in self?.toggleMeetingPanel() },
                    onTranslateScreen: { [weak self] in self?.translateScreen() },
                    onCopyTextFromScreen: { [weak self] in self?.copyTextFromScreen() },
                    onPreviewAmbient: { [weak claudeAmbient] in claudeAmbient?.preview() }
                )
            )
        )

        // Two windows: `panel` is the clear lens that marks what to capture,
        // `reader` shows the translation somewhere out of the way.
        let panel = OverlayPanel(viewModel: viewModel)
        self.panel = panel
        viewModel.panelFrameProvider = { [weak panel] in panel?.frame ?? .zero }
        viewModel.panelVisibilityHandler = { [weak panel] visible in
            if visible {
                panel?.orderFrontRegardless()
            } else {
                panel?.orderOut(nil)
            }
        }

        viewModel.openSettingsHandler = { [weak self] in
            guard let contentView = self?.panel?.contentView else { return }
            self?.menuBar?.showControls(anchoredTo: contentView)
        }

        let reader = ReaderPanel(viewModel: viewModel, lensFrame: panel.frame)
        self.reader = reader
        viewModel.readerFrameProvider = { [weak reader] in reader?.frame ?? .zero }
        viewModel.readerVisibilityHandler = { [weak reader] visible in
            if visible {
                reader?.orderFrontRegardless()
            } else {
                reader?.orderOut(nil)
            }
        }
        // Lens stays hidden and capture stays off until the user turns it on
        // (menu toggle or hotkey) — no auto-start, no permission prompt at launch.

        // No hotkey for the lens on purpose — it's toggled from the menu.
        // ⌃⌥⌘D opens the shelf (plain ⌥⌘D is macOS's Dock show/hide and never arrives).
        shelfHotKey = HotKeyManager(keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(controlKey | optionKey | cmdKey), id: 2) { [weak self] in
            Task { @MainActor in
                self?.menuBar?.toggleShelf()
            }
        }
        // Shake the pointer mid-drag → shelf pops up beside it.
        shakeToShelf = ShakeToShelf { [weak dropShelf] point in
            dropShelf?.show(near: point)
        }

        // ⌥⌘T / ⌥⌘G: the two screen pickers, reachable while the icon hides
        // under the notch.
        translateHotKey = HotKeyManager(keyCode: UInt32(kVK_ANSI_T), id: 3) { [weak self] in
            Task { @MainActor in self?.translateScreen() }
        }
        copyTextHotKey = HotKeyManager(keyCode: UInt32(kVK_ANSI_G), id: 4) { [weak self] in
            Task { @MainActor in self?.copyTextFromScreen() }
        }
        // ⌃⌥⌘F: Finish Engine box, same key shows and hides it.
        finishEngineHotKey = HotKeyManager(keyCode: UInt32(kVK_ANSI_F), modifiers: UInt32(controlKey | optionKey | cmdKey), id: 5) { [weak self] in
            Task { @MainActor in self?.toggleFinishEngine() }
        }

        // ⌃⌥⌘R: start / stop the meeting recorder (Zoom, Teams, Discord, LINE, Meet…).
        meetingHotKey = HotKeyManager(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(controlKey | optionKey | cmdKey), id: 6) { [weak self] in
            Task { @MainActor in self?.meeting?.hotkeyPressed() }
        }

        // ⌃⌥⌘O: select a path in any app → Finder opens there (reveal-path).
        revealPathHotKey = HotKeyManager(keyCode: UInt32(kVK_ANSI_O), modifiers: UInt32(controlKey | optionKey | cmdKey), id: 7) {
            Task { @MainActor in RevealPath.run() }
        }

        LaunchAtLogin.applyDefaultOnce()

        // Opened by hand (Desktop icon, Finder) → show the controls so the user
        // sees it start. Skipped when macOS starts it at login.
        if !launchedAsLoginItem {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.menuBar?.showControls()
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.viewModel.appDidBecomeActive()
            }
        }
    }

    /// Double-clicking the app while it's already running.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        menuBar?.showControls()
        return false
    }

    private var launchedAsLoginItem: Bool {
        let event = NSAppleEventManager.shared().currentAppleEvent
        let flagged = event?.eventID == AEEventID(kAEOpenApplication)
            && event?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
        // Login items registered through SMAppService may not carry that
        // flag; a launch in the first minutes after boot is a login launch.
        return flagged || ProcessInfo.processInfo.systemUptime < 180
    }

    /// Called from the main menu bar controls (the battery dropdown that used
    /// to host this toggle was removed).
    func toggleSystemStatsWidget() {
        systemStats?.toggle()
    }

    /// ⌃⌥⌘F and the menu row: shows or hides the Finish Engine box. From the
    /// menu, the popover closes first: the box closes itself when it loses
    /// key focus, so the closing popover must not be able to take it back.
    func toggleFinishEngine() {
        guard let menuBar, menuBar.isPopoverShown else {
            finishEngine?.toggle()
            return
        }
        menuBar.closePopover()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.finishEngine?.show()
        }
    }

    func toggleMeetingPanel() {
        menuBar?.closePopover()
        meeting?.toggleVisibility()
    }

    func translateScreen() {
        menuBar?.closePopover()
        quickTranslation?.start()
    }

    func copyTextFromScreen() {
        menuBar?.closePopover()
        quickTranslation?.start(mode: .copyText)
    }

    var isSystemStatsVisible: Bool {
        systemStats?.isVisible == true
    }

    func toggleClaudeConnectionsWidget() {
        claudeConnections?.toggle()
    }

    var isClaudeConnectionsVisible: Bool {
        claudeConnections?.isVisible == true
    }
}

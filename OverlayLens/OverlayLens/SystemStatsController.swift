import AppKit
import SwiftUI

/// Floating glass system-stats widget pinned at desktop-widget level: above
/// the wallpaper and Finder's desktop icons, below every app window — the
/// same plane the system calendar/battery widgets live on. Draggable, and
/// the frame persists across launches.
@MainActor
final class SystemStatsController {
    private let model = SystemStatsModel()
    private var panel: NSPanel?
    private var moveObserver: NSObjectProtocol?
    private var occlusionObserver: NSObjectProtocol?
    private var workspaceObservers: [NSObjectProtocol] = []

    private static let frameKey = "SystemStatsFrame"
    private static let visibleKey = "SystemStatsVisible"

    var isVisible: Bool { panel?.isVisible == true }

    init() {
        // Always visible on launch by user request ("โชว์ขึ้นมาตลอด") —
        // the menu toggle only hides it for the current run.
        // Temporarily hidden while verifying Finish Engine interactions.

        // Sampling while the lid is closed would just burn battery.
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.model.stop() }
        })
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isVisible else { return }
                self.model.start()
            }
        })
    }

    func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        let panel = ensurePanel()
        guard !panel.isVisible else { return }
        position(panel)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 1
        }
        model.start()
        UserDefaults.standard.set(true, forKey: Self.visibleKey)
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
        model.stop()
        UserDefaults.standard.set(false, forKey: Self.visibleKey)
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        // Fixed panel size; the glass card inside is top-anchored and draws
        // itself smaller or larger (stuck-app alarm rows) within it. Driving
        // the window frame from SwiftUI's preferred size loops Auto Layout
        // into a stack overflow on a borderless panel — don't.
        let hosting = NSHostingController(rootView: SystemStatsView(model: model))
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 320, height: 460)),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = hosting
        // Assigning the hosting controller resizes the window to the SwiftUI
        // view's fitting size, which is zero until the first layout — leaving
        // position() to place the panel by a height of 0, so the card grew up
        // past the top of the screen. Pin the size back explicitly.
        panel.setContentSize(NSSize(width: 320, height: 460))
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        // One notch above the desktop-icon plane keeps the widget clickable
        // over Finder's icon layer while staying under all app windows.
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.isMovableByWindowBackground = true

        // The widget sits under every app window, so it spends most of its
        // life fully covered. Sampling at full pace for a gauge nobody can
        // see would be self-inflicted load, but stuck-app detection still
        // wants data — so covered = lazy 10s pace, visible = 2s pace.
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: panel, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, let panel = self.panel, panel.isVisible else { return }
                self.model.setSlowPace(!panel.occlusionState.contains(.visible))
            }
        }

        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main
        ) { note in
            guard let window = note.object as? NSWindow else { return }
            UserDefaults.standard.set(
                NSStringFromRect(window.frame), forKey: SystemStatsController.frameKey
            )
        }

        self.panel = panel
        return panel
    }

    private func position(_ panel: NSPanel) {
        if let saved = UserDefaults.standard.string(forKey: Self.frameKey) {
            let frame = NSRectFromString(saved)
            if !frame.isEmpty, NSScreen.screens.contains(where: { $0.frame.intersects(frame) }) {
                panel.setFrameOrigin(frame.origin)
                return
            }
        }
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        // Default home: under the desktop-widget row in the top-left region.
        let origin = NSPoint(
            x: visible.minX + 352,
            y: min(
                max(visible.minY, visible.maxY - 340 - panel.frame.height),
                max(visible.minY, visible.maxY - panel.frame.height)
            )
        )
        panel.setFrameOrigin(origin)
    }
}

import AppKit
import SwiftUI

/// Floating glass panel listing Claude's connected apps, pinned at the same
/// desktop-widget level as the CPU/RAM widget: above the wallpaper and Finder
/// icons, below every app window. Draggable, and the frame persists.
@MainActor
final class ClaudeConnectionsController {
    private let model = ClaudeConnectionsModel()
    private var panel: NSPanel?
    private var moveObserver: NSObjectProtocol?
    private var occlusionObserver: NSObjectProtocol?
    private var workspaceObservers: [NSObjectProtocol] = []

    private static let frameKey = "ClaudeConnectionsFrame"
    private static let visibleKey = "ClaudeConnectionsVisible"
    private static let panelSize = NSSize(width: 320, height: 460)

    var isVisible: Bool { panel?.isVisible == true }

    /// Shown on first launch, and after that whatever the menu toggle was left
    /// on — unlike the stats widget, which always comes back visible.
    init() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.visibleKey) == nil || defaults.bool(forKey: Self.visibleKey) {
            show()
        }

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

        // Fixed panel size with a top-anchored card inside — same reason as
        // the stats widget: driving a borderless panel's frame from SwiftUI's
        // preferred size sends Auto Layout into a stack overflow.
        let hosting = NSHostingController(
            rootView: ClaudeConnectionsView(
                model: model,
                onClose: { [weak self] in self?.hide() }
            )
        )
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = hosting
        // Assigning a hosting controller resizes the window to the SwiftUI
        // view's fitting size, which is still zero at this point — position()
        // would then place the panel by a height of 0 and the card would grow
        // up off the top of the screen. Pin the size back explicitly.
        panel.setContentSize(Self.panelSize)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.isMovableByWindowBackground = true

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
                NSStringFromRect(window.frame), forKey: ClaudeConnectionsController.frameKey
            )
        }

        self.panel = panel
        return panel
    }

    private func position(_ panel: NSPanel) {
        if let saved = UserDefaults.standard.string(forKey: Self.frameKey) {
            let frame = NSRectFromString(saved)
            if !frame.isEmpty, NSScreen.screens.contains(where: { $0.frame.intersects(frame) }) {
                panel.setFrameOrigin(clamped(frame.origin, for: panel))
                return
            }
        }
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        // Default home: to the right of the stats widget's default slot.
        let origin = NSPoint(
            x: visible.minX + 692,
            y: visible.maxY - 340 - Self.panelSize.height
        )
        panel.setFrameOrigin(clamped(origin, for: panel))
    }

    /// Keeps the whole panel inside the screen it lands on — without this a
    /// saved frame from another display layout, or a default computed for a
    /// taller screen, can park the card half off the top edge.
    private func clamped(_ origin: NSPoint, for panel: NSPanel) -> NSPoint {
        let size = Self.panelSize
        let screen = NSScreen.screens.first {
            $0.frame.contains(NSPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2))
        } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return origin }
        return NSPoint(
            x: min(max(origin.x, visible.minX), max(visible.minX, visible.maxX - size.width)),
            y: min(max(origin.y, visible.minY), max(visible.minY, visible.maxY - size.height))
        )
    }
}

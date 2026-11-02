import AppKit
import SwiftUI

/// Floating glass panel for Finish Engine, toggled from the menu bar popover
/// or ⌃⌥⌘F. Unlike the CPU/RAM and Claude widgets it floats above app windows
/// — it's summoned on demand, then dismissed with the same shortcut.
/// Draggable, and both the frame and visibility persist across launches.
@MainActor
final class FinishEngineController {
    let model = FinishEngineModel()
    private var panel: NSPanel?
    private var moveObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?

    static let frameKey = "FinishEngineFrame"
    private static let visibleKey = "FinishEngineVisible"
    /// Room for the medium card + task flow; the clear area lets clicks through.
    static let panelSize = NSSize(width: 404, height: 560)

    var isVisible: Bool { panel?.isVisible == true }

    init() {
        if UserDefaults.standard.bool(forKey: Self.visibleKey) {
            show()
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isVisible else { return }
                self.model.refresh()
            }
        }
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

        // Fixed panel with a top-anchored card, like the other widgets:
        // sizing a borderless panel from SwiftUI's preferred size overflows
        // Auto Layout. The clear area below the card lets clicks through.
        let hosting = NSHostingController(
            rootView: FinishEngineMediumView(
                model: model,
                onClose: { [weak self] in self?.hide() },
                window: { [weak self] in self?.panel }
            )
        )
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
        panel.level = .floating
        // No .canJoinAllSpaces / .fullScreenAuxiliary: the panel stays on the
        // display + Space where it was placed instead of following the user
        // onto other desktops and full-screen apps (2-monitor setup).
        panel.collectionBehavior = [.managed, .ignoresCycle]
        panel.isMovableByWindowBackground = true

        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main
        ) { note in
            guard let window = note.object as? NSWindow else { return }
            UserDefaults.standard.set(
                NSStringFromRect(window.frame), forKey: FinishEngineController.frameKey
            )
        }

        self.panel = panel
        return panel
    }

    private func position(_ panel: NSPanel) {
        if let saved = UserDefaults.standard.string(forKey: Self.frameKey) {
            let frame = NSRectFromString(saved)
            if !frame.isEmpty, NSScreen.screens.contains(where: { $0.frame.intersects(frame) }) {
                // Keep the top-left corner where it was, even if the saved
                // frame came from a panel of a different height.
                let origin = NSPoint(x: frame.minX, y: frame.maxY - Self.panelSize.height)
                panel.setFrameOrigin(clamped(origin))
                return
            }
        }
        // First launch only: the screen with the menu bar, not whichever
        // screen has the key window.
        guard let visible = (NSScreen.screens.first ?? NSScreen.main)?.visibleFrame else { return }
        // Default home: top-right corner, where the Übersicht widget used to sit.
        let origin = NSPoint(
            x: visible.maxX - Self.panelSize.width - 10,
            y: visible.maxY - Self.panelSize.height
        )
        panel.setFrameOrigin(clamped(origin))
    }

    /// Only the card's top edge has to stay on screen — the rest of the panel
    /// is transparent, so letting it hang below the bottom is fine.
    private func clamped(_ origin: NSPoint) -> NSPoint {
        let size = Self.panelSize
        let screen = NSScreen.screens.first {
            $0.frame.contains(NSPoint(x: origin.x + size.width / 2, y: origin.y + size.height - 40))
        } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return origin }
        return NSPoint(
            x: min(max(origin.x, visible.minX), max(visible.minX, visible.maxX - size.width)),
            y: min(max(origin.y, visible.minY - size.height + 160), visible.maxY - size.height)
        )
    }
}

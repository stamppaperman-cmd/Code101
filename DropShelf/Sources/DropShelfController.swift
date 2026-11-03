import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Staging shelf for AirDrop: a floating glass panel under the notch holding
/// files, images, links, and notes until they all go out in one send.
///
/// It has no menu bar slot of its own — `MenuBarController` owns the single
/// status item and drives this (right-click, drag-onto-icon, or ⌥⌘D).
@MainActor
final class DropShelfController: NSObject {
    let model = DropShelfModel()
    private var panel: NSPanel?

    var isVisible: Bool { panel?.isVisible == true }

    func toggle() {
        if isVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    func show() {
        showPanel()
    }

    /// Shake-to-shelf: hang the shelf just above the pointer so its drop zone
    /// (at the bottom) is a short move up. Doesn't take key focus — the user
    /// is mid-drag, and the compose field isn't what they're reaching for.
    func show(near point: NSPoint) {
        let panel = ensurePanel()
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = panel.frame.size == .zero ? Self.panelSize : panel.frame.size
        var origin = NSPoint(x: point.x - size.width / 2, y: point.y + 24)
        if origin.y + size.height > visible.maxY {
            // No room above: hang it below the pointer instead.
            origin.y = point.y - 24 - size.height
        }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        let frame = NSRect(origin: origin, size: size)
        panelTopY = frame.maxY
        panel.level = .statusBar

        if panel.isVisible {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                panel.animator().setFrame(frame, display: true)
            }
            return
        }
        panel.setFrame(frame, display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 1
        }
    }

    private func showPanel() {
        let panel = ensurePanel()
        guard !panel.isVisible else { return }
        position(panel)
        panel.alphaValue = 0
        // Reassert the floating level in case a share left it stepped down.
        panel.level = .statusBar
        panel.orderFrontRegardless()
        // The compose field needs key focus; a nonactivating panel can take it
        // without pulling the whole (accessory) app to the front.
        panel.makeKey()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 1
        }
    }

    private func hidePanel() {
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let content = DropShelfView(
            model: model,
            onClose: { [weak self] in self?.hidePanel() },
            onMeasure: { [weak self] size in self?.resize(to: size) }
        )
        let hosting = NSHostingController(rootView: content)

        let panel = ShelfPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.onCancel = { [weak self] in self?.hidePanel() }
        panel.onPaste = { [weak self] in
            self?.model.pasteFilesOrImageFromClipboard() ?? false
        }
        panel.contentViewController = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        // Panels hide themselves on deactivate by default — which, once the
        // shelf takes key focus for its compose field, made it vanish right
        // after opening.
        panel.hidesOnDeactivate = false

        // AirDrop's picker centres itself on whatever window it is handed, so
        // handing it the shelf parked it right on top of the cards being sent.
        // It gets an invisible anchor window beside the shelf instead.
        model.sharingWindowProvider = { [weak self] in self?.prepareShareAnchor() }
        model.sharingStateHandler = { [weak self] isSharing in
            if !isSharing { self?.dismissShareAnchor() }
        }

        // Dragging the shelf elsewhere re-anchors it there.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.panelTopY = panel.frame.maxY }
        }

        self.panel = panel
        return panel
    }

    // MARK: - AirDrop picker placement

    /// Invisible stand-in the AirDrop picker centres itself on, so the picker
    /// lands beside the shelf instead of over the cards you are sending.
    private var shareAnchor: NSWindow?

    /// Roughly the picker's own footprint. Only the centre of this rect
    /// decides where the picker lands, so it needs to be close, not exact.
    private static let pickerSize = NSSize(width: 420, height: 300)

    private func prepareShareAnchor() -> NSWindow? {
        dismissShareAnchor()
        guard let panel, panel.isVisible else { return nil }

        let anchor = ShareAnchorWindow(
            contentRect: shareAnchorFrame(for: panel),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        anchor.isOpaque = false
        anchor.backgroundColor = .clear
        anchor.hasShadow = false
        anchor.level = .statusBar
        anchor.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Nothing is drawn in it; it must never swallow a click.
        anchor.ignoresMouseEvents = true
        anchor.orderFrontRegardless()

        shareAnchor = anchor
        return anchor
    }

    private func dismissShareAnchor() {
        shareAnchor?.orderOut(nil)
        shareAnchor = nil
        if let panel, panel.isVisible { panel.orderFrontRegardless() }
    }

    /// Beside the shelf when either side has room — right first, since the
    /// shelf hangs centre-top — and under it when neither does. Always kept
    /// inside the visible screen so the picker can't hang off an edge.
    private func shareAnchorFrame(for panel: NSWindow) -> NSRect {
        let size = Self.pickerSize
        let shelf = panel.frame
        let visible = (panel.screen ?? NSScreen.main)?.visibleFrame ?? shelf
        let gap: CGFloat = 16

        let y = min(
            max(shelf.midY - size.height / 2, visible.minY + gap),
            visible.maxY - size.height - gap
        )

        let rightX = shelf.maxX + gap
        if rightX + size.width <= visible.maxX - gap {
            return NSRect(origin: NSPoint(x: rightX, y: y), size: size)
        }

        let leftX = shelf.minX - gap - size.width
        if leftX >= visible.minX + gap {
            return NSRect(origin: NSPoint(x: leftX, y: y), size: size)
        }

        return NSRect(
            x: min(max(shelf.midX - size.width / 2, visible.minX + gap),
                   visible.maxX - size.width - gap),
            y: max(shelf.minY - gap - size.height, visible.minY + gap),
            width: size.width,
            height: size.height
        )
    }

    private static let panelSize = NSSize(width: 460, height: 300)

    /// Screen-space y of the shelf's top edge; the panel hangs from it so
    /// resizing grows downward instead of pushing up under the menu bar.
    private var panelTopY: CGFloat = 0

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let size = panel.frame.size == .zero ? Self.panelSize : panel.frame.size
        panelTopY = screen.visibleFrame.maxY - 4
        let origin = NSPoint(
            x: screen.frame.midX - size.width / 2,
            y: panelTopY - size.height
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    /// The shelf reports its own laid-out size (it grows when the first card
    /// lands); the panel follows it, hanging from the same top edge.
    /// Measuring in SwiftUI and resizing one-way avoids the AppKit
    /// auto-sizing path, which recursed itself to death here.
    private func resize(to size: NSSize) {
        guard let panel, size.width > 1, size.height > 1 else { return }
        let target = NSRect(
            x: panel.frame.origin.x,
            y: panelTopY - size.height,
            width: size.width,
            height: size.height
        )
        guard target != panel.frame else { return }
        panel.setFrame(target, display: true)
    }
}

/// Empty, invisible, click-through window that exists only to give the AirDrop
/// picker somewhere to centre itself. AppKit skips borderless windows when
/// looking for a key window, so it says yes here to be a valid share source.
private final class ShareAnchorWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

/// Borderless panels refuse key status by default, which would leave the
/// link/message field untypeable. Esc closes the shelf.
private final class ShelfPanel: NSPanel {
    var onCancel: (() -> Void)?
    /// ⌘V: returns true when it took files/an image off the clipboard.
    var onPaste: (() -> Bool)?

    override var canBecomeKey: Bool { true }

    // The compose TextField only understands text, so a ⌃⇧⌘4 screenshot
    // (PNG/TIFF on the clipboard) used to vanish on ⌘V. Catch it here first.
    // keyCode 9 = V key, independent of Thai/English layout.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown,
           event.keyCode == 9,
           event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
           onPaste?() == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

import AppKit
import SwiftUI

/// The floating translation lens: a borderless, non-activating panel with a
/// translucent glass background, draggable from anywhere on its surface.
final class OverlayPanel: NSPanel {
    static let lensSize = NSSize(width: 300, height: 180)

    init(viewModel: OverlayViewModel) {
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(
            x: screenFrame.midX - Self.lensSize.width / 2,
            y: screenFrame.midY - Self.lensSize.height / 2
        )
        super.init(
            contentRect: NSRect(origin: origin, size: Self.lensSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isMovable = false // dragging is handled manually by DragContainerView

        let container = DragContainerView(frame: NSRect(origin: .zero, size: Self.lensSize))
        container.wantsLayer = true
        container.layer?.cornerRadius = 18
        container.layer?.masksToBounds = true
        container.onDragStart = { [weak viewModel] in viewModel?.dragBegan() }
        container.onDragEnd = { [weak viewModel] in viewModel?.dragEnded() }

        let effectView = NSVisualEffectView(frame: container.bounds)
        effectView.material = .hudWindow
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.autoresizingMask = [.width, .height]
        container.addSubview(effectView)

        let hostingView = NSHostingView(rootView: OverlayContentView(viewModel: viewModel))
        hostingView.frame = container.bounds
        hostingView.autoresizingMask = [.width, .height]
        container.addSubview(hostingView)

        contentView = container
    }
}

/// Content view that moves the panel with mouseDown/mouseDragged and reports
/// drag start/end so capture can pause and restart at the new position.
final class DragContainerView: NSView {
    var onDragStart: (() -> Void)?
    var onDragEnd: (() -> Void)?

    private var initialMouseLocation: NSPoint = .zero
    private var initialWindowOrigin: NSPoint = .zero

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Swallow all mouse events so the whole lens surface is a drag handle.
        self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        initialMouseLocation = NSEvent.mouseLocation
        initialWindowOrigin = window.frame.origin
        onDragStart?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }
        let location = NSEvent.mouseLocation
        window.setFrameOrigin(NSPoint(
            x: initialWindowOrigin.x + (location.x - initialMouseLocation.x),
            y: initialWindowOrigin.y + (location.y - initialMouseLocation.y)
        ))
    }

    override func mouseUp(with event: NSEvent) {
        onDragEnd?()
    }
}

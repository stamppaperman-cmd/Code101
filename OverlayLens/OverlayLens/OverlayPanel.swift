import AppKit
import Combine
import SwiftUI

/// The floating translation lens: a borderless, non-activating panel with a
/// translucent glass background, draggable from anywhere on its surface and
/// resizable from its bottom-right corner.
final class OverlayPanel: NSPanel {
    static let defaultLensSize = NSSize(width: 300, height: 180)

    private var opacityCancellable: AnyCancellable?

    init(viewModel: OverlayViewModel) {
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(
            x: screenFrame.midX - Self.defaultLensSize.width / 2,
            y: screenFrame.midY - Self.defaultLensSize.height / 2
        )
        super.init(
            contentRect: NSRect(origin: origin, size: Self.defaultLensSize),
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

        let container = DragContainerView(frame: NSRect(origin: .zero, size: Self.defaultLensSize))
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

        effectView.alphaValue = viewModel.glassOpacity
        opacityCancellable = viewModel.$glassOpacity
            .receive(on: RunLoop.main)
            .sink { [weak effectView] opacity in
                effectView?.alphaValue = opacity
            }
    }
}

/// Content view that moves the panel with mouseDown/mouseDragged (or resizes
/// it when the drag starts in the bottom-right corner) and reports drag
/// start/end so capture can pause and restart at the new frame.
final class DragContainerView: NSView {
    static let minLensSize = NSSize(width: 200, height: 120)
    static let maxLensSize = NSSize(width: 900, height: 600)

    var onDragStart: (() -> Void)?
    var onDragEnd: (() -> Void)?

    private enum DragMode { case move, resize }
    private let resizeGripHitSize: CGFloat = 24
    private let closeButtonHitSize: CGFloat = 32

    private var dragMode: DragMode = .move
    private var initialMouseLocation: NSPoint = .zero
    private var initialWindowFrame: NSRect = .zero

    override func hitTest(_ point: NSPoint) -> NSView? {
        // The whole lens surface is a drag handle, except the top-right
        // corner where the SwiftUI close button lives.
        let local = convert(point, from: superview)
        if local.x > bounds.width - closeButtonHitSize, local.y > bounds.height - closeButtonHitSize {
            return super.hitTest(point)
        }
        return self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let local = convert(event.locationInWindow, from: nil)
        dragMode = (local.x > bounds.width - resizeGripHitSize && local.y < resizeGripHitSize)
            ? .resize
            : .move
        initialMouseLocation = NSEvent.mouseLocation
        initialWindowFrame = window.frame
        onDragStart?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }
        let location = NSEvent.mouseLocation
        let dx = location.x - initialMouseLocation.x
        let dy = location.y - initialMouseLocation.y

        switch dragMode {
        case .move:
            window.setFrameOrigin(NSPoint(
                x: initialWindowFrame.minX + dx,
                y: initialWindowFrame.minY + dy
            ))
        case .resize:
            // Bottom-right grip: dragging right widens, dragging down grows
            // downward while the top edge stays put.
            let width = (initialWindowFrame.width + dx)
                .clamped(to: Self.minLensSize.width...Self.maxLensSize.width)
            let height = (initialWindowFrame.height - dy)
                .clamped(to: Self.minLensSize.height...Self.maxLensSize.height)
            window.setFrame(
                NSRect(
                    x: initialWindowFrame.minX,
                    y: initialWindowFrame.maxY - height,
                    width: width,
                    height: height
                ),
                display: true
            )
        }
    }

    override func mouseUp(with event: NSEvent) {
        onDragEnd?()
    }
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

import AppKit
import Combine
import SwiftUI

/// Lens 1 — the clear viewfinder. A borderless, non-activating panel with a
/// see-through interior (so you can read what's underneath) and a thin accent
/// border marking the region being captured. Draggable from anywhere on its
/// surface and resizable from any edge or corner. In AR mode the translated
/// lines are drawn in place inside it; the block translation lives in the
/// separate `ReaderPanel`.
final class OverlayPanel: NSPanel {
    static let defaultLensSize = NSSize(width: 300, height: 180)

    private var cancellables = Set<AnyCancellable>()
    private weak var viewModel: OverlayViewModel?

    init(viewModel: OverlayViewModel) {
        let contentRect = Self.restoredLensFrame() ?? Self.centeredDefaultFrame()
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.viewModel = viewModel

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false // nothing opaque to cast one; it'd just be a grey box
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isMovable = false // dragging is handled manually by DragContainerView

        let container = DragContainerView(frame: NSRect(origin: .zero, size: contentRect.size))
        container.wantsLayer = true
        container.layer?.cornerRadius = 14
        container.layer?.masksToBounds = true
        // Border, grab band and header are all drawn in SwiftUI now (the
        // border color reports capture state, so it can't be a static layer).
        // The middle is left at alpha 0 on purpose: macOS routes mouse events
        // by the window's alpha channel, so transparent pixels pass clicks
        // through to whatever is underneath — you can keep using the app you
        // are translating. Everything grabbable is painted by
        // `OverlayContentView` instead.
        container.onDragStart = { [weak viewModel] in viewModel?.dragBegan() }
        container.onDragEnd = { [weak viewModel] in viewModel?.dragEnded() }
        container.onHoverChange = { [weak viewModel] hovering in viewModel?.setHovering(hovering) }

        let hostingView = NSHostingView(rootView: OverlayContentView(viewModel: viewModel))
        hostingView.frame = container.bounds
        hostingView.autoresizingMask = [.width, .height]
        container.addSubview(hostingView)

        contentView = container

        // While asking for permission the lens shows a real button, so mouse
        // events must reach SwiftUI instead of being eaten by the drag handle.
        viewModel.$status
            .map { $0 == .needsPermission }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak container] needsPermission in
                container?.permissionMode = needsPermission
            }
            .store(in: &cancellables)

        // A display can disconnect or change resolution out from under the
        // panel; make sure it's still fully on some screen afterward.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(revalidatePlacementOnScreenChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func revalidatePlacementOnScreenChange() {
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(frame) }) else {
            // Off every connected screen (e.g. its display was unplugged) —
            // recenter on the main screen at the panel's current size.
            if let mainScreen = NSScreen.main {
                let visible = mainScreen.visibleFrame
                setFrameOrigin(NSPoint(x: visible.midX - frame.width / 2, y: visible.midY - frame.height / 2))
                notifyFrameSettled()
            }
            return
        }
        let visible = screen.visibleFrame
        var newFrame = frame
        newFrame.origin.x = min(max(newFrame.origin.x, visible.minX), visible.maxX - newFrame.width)
        newFrame.origin.y = min(max(newFrame.origin.y, visible.minY), visible.maxY - newFrame.height)
        if newFrame != frame {
            setFrame(newFrame, display: true)
            notifyFrameSettled()
        }
    }

    /// Keeps the capture rect and saved position in sync after the panel
    /// moves outside of a direct user drag (e.g. a display reconfiguration).
    private func notifyFrameSettled() {
        viewModel?.dragEnded()
    }

    /// Last saved lens frame, if it is still valid and on a connected screen.
    private static func restoredLensFrame() -> NSRect? {
        guard let saved = UserDefaults.standard.string(forKey: OverlayViewModel.lensFrameKey) else {
            return nil
        }
        let rect = NSRectFromString(saved)
        guard rect.width >= DragContainerView.minLensSize.width,
              rect.height >= DragContainerView.minLensSize.height,
              rect.width <= DragContainerView.maxLensSize.width,
              rect.height <= DragContainerView.maxLensSize.height,
              NSScreen.screens.contains(where: { $0.frame.intersects(rect) })
        else {
            return nil
        }
        return rect
    }

    private static func centeredDefaultFrame() -> NSRect {
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSRect(
            x: screenFrame.midX - defaultLensSize.width / 2,
            y: screenFrame.midY - defaultLensSize.height / 2,
            width: defaultLensSize.width,
            height: defaultLensSize.height
        )
    }
}

/// Content view that moves the panel with mouseDown/mouseDragged (or resizes
/// it when the drag starts near an edge/corner), scroll-adjusts glass
/// opacity, and reports drag start/end so capture can pause and restart at
/// the new frame.
final class DragContainerView: NSView {
    static let minLensSize = NSSize(width: 200, height: 120)
    static let maxLensSize = NSSize(width: 900, height: 600)
    /// How close to a screen edge (in points) a drag-release must land to snap flush.
    static let edgeSnapThreshold: CGFloat = 20

    var onDragStart: (() -> Void)?
    var onDragEnd: (() -> Void)?
    var onHoverChange: ((Bool) -> Void)?
    /// Delta from a scroll gesture over the lens, used to nudge glass opacity.
    var onScrollOpacity: ((CGFloat) -> Void)?
    /// While the permission message (with its button) is showing, most of the
    /// surface passes events through to SwiftUI instead of dragging.
    var permissionMode = false

    /// Which edge(s) of the panel a resize drag is moving. A single edge
    /// resizes one axis; a corner (two edges) resizes both, keeping the two
    /// opposite edges fixed — standard window resize-handle behavior.
    private struct ResizeEdges: OptionSet {
        let rawValue: Int
        static let left = ResizeEdges(rawValue: 1 << 0)
        static let right = ResizeEdges(rawValue: 1 << 1)
        static let top = ResizeEdges(rawValue: 1 << 2)
        static let bottom = ResizeEdges(rawValue: 1 << 3)
    }

    private enum DragMode: Equatable {
        case move
        case resize(ResizeEdges)
    }

    /// Plain-edge hit margin; corners use a slightly larger zone so they're
    /// easier to grab.
    private let edgeResizeMargin: CGFloat = 8
    private let cornerResizeMargin: CGFloat = 14
    /// Top-right strip hosting the SwiftUI buttons. Matches the lens header's
    /// height so no dead band is left underneath it.
    private let controlStripSize = NSSize(width: 60, height: 26)
    private let permissionDragBandHeight: CGFloat = 26

    private var dragMode: DragMode = .move
    private var initialMouseLocation: NSPoint = .zero
    private var initialWindowFrame: NSRect = .zero

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        // Top-right corner: the SwiftUI control buttons. Checked first so they
        // stay clickable in permission mode too.
        if local.x > bounds.width - controlStripSize.width,
           local.y > bounds.height - controlStripSize.height {
            return super.hitTest(point)
        }
        if permissionMode {
            // Keep a drag band along the top edge; the rest goes to SwiftUI
            // so the "Open System Settings" button is clickable.
            return local.y > bounds.height - permissionDragBandHeight ? self : super.hitTest(point)
        }
        return self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        // .activeAlways: the panel is non-activating, so app-active-only
        // tracking would never fire.
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChange?(false)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let local = convert(event.locationInWindow, from: nil)
        let edges = resizeEdges(at: local)
        dragMode = edges.isEmpty ? .move : .resize(edges)
        initialMouseLocation = NSEvent.mouseLocation
        initialWindowFrame = window.frame
        onDragStart?()
    }

    /// Which edge(s) `point` (in the view's own bounds) is near, if any.
    /// Bounds are unflipped (y = 0 at the bottom), matching AppKit screen
    /// coordinates used for the resulting window math.
    private func resizeEdges(at point: NSPoint) -> ResizeEdges {
        let nearLeftCorner = point.x < cornerResizeMargin
        let nearRightCorner = point.x > bounds.width - cornerResizeMargin
        let nearBottomCorner = point.y < cornerResizeMargin
        let nearTopCorner = point.y > bounds.height - cornerResizeMargin

        if nearLeftCorner && nearBottomCorner { return [.left, .bottom] }
        if nearLeftCorner && nearTopCorner { return [.left, .top] }
        if nearRightCorner && nearBottomCorner { return [.right, .bottom] }
        if nearRightCorner && nearTopCorner { return [.right, .top] }
        if point.x < edgeResizeMargin { return [.left] }
        if point.x > bounds.width - edgeResizeMargin { return [.right] }
        if point.y < edgeResizeMargin { return [.bottom] }
        if point.y > bounds.height - edgeResizeMargin { return [.top] }
        return []
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
        case .resize(let edges):
            window.setFrame(resizedFrame(edges: edges, dx: dx, dy: dy), display: true)
        }
    }

    /// Applies a resize delta to `initialWindowFrame` for the given active
    /// edge(s), clamping each axis independently and keeping the edge(s) NOT
    /// being dragged fixed in place.
    private func resizedFrame(edges: ResizeEdges, dx: CGFloat, dy: CGFloat) -> NSRect {
        var frame = initialWindowFrame

        if edges.contains(.right) {
            frame.size.width = (initialWindowFrame.width + dx)
                .clamped(to: Self.minLensSize.width...Self.maxLensSize.width)
        } else if edges.contains(.left) {
            let width = (initialWindowFrame.width - dx)
                .clamped(to: Self.minLensSize.width...Self.maxLensSize.width)
            frame.origin.x = initialWindowFrame.maxX - width
            frame.size.width = width
        }

        if edges.contains(.top) {
            frame.size.height = (initialWindowFrame.height + dy)
                .clamped(to: Self.minLensSize.height...Self.maxLensSize.height)
        } else if edges.contains(.bottom) {
            let height = (initialWindowFrame.height - dy)
                .clamped(to: Self.minLensSize.height...Self.maxLensSize.height)
            frame.origin.y = initialWindowFrame.maxY - height
            frame.size.height = height
        }

        return frame
    }

    override func mouseUp(with event: NSEvent) {
        if dragMode == .move {
            snapToScreenEdgeIfNeeded()
        }
        onDragEnd?()
    }

    override func scrollWheel(with event: NSEvent) {
        onScrollOpacity?(event.scrollingDeltaY)
    }

    /// Snaps the panel flush to a screen edge it was dropped within
    /// `edgeSnapThreshold` points of. Only applies to moves, not resizes.
    private func snapToScreenEdgeIfNeeded() {
        guard let window,
              let screen = NSScreen.screens.first(where: { $0.frame.intersects(window.frame) }) ?? NSScreen.main
        else { return }

        let visible = screen.visibleFrame
        var snapped = window.frame

        if abs(snapped.minX - visible.minX) < Self.edgeSnapThreshold {
            snapped.origin.x = visible.minX
        } else if abs(snapped.maxX - visible.maxX) < Self.edgeSnapThreshold {
            snapped.origin.x = visible.maxX - snapped.width
        }

        if abs(snapped.minY - visible.minY) < Self.edgeSnapThreshold {
            snapped.origin.y = visible.minY
        } else if abs(snapped.maxY - visible.maxY) < Self.edgeSnapThreshold {
            snapped.origin.y = visible.maxY - snapped.height
        }

        if snapped != window.frame {
            window.setFrame(snapped, display: true, animate: true)
        }
    }
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

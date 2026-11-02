import AppKit
import Combine
import SwiftUI

/// Lens 2 — the reading window. Same glass panel the old combined lens had,
/// but decoupled from the capture region: park it wherever there's room while
/// the clear lens sits on top of the text being translated.
final class ReaderPanel: NSPanel {
    static let defaultSize = NSSize(width: 360, height: 200)

    private var cancellables = Set<AnyCancellable>()
    private weak var viewModel: OverlayViewModel?

    init(viewModel: OverlayViewModel, lensFrame: NSRect) {
        let contentRect = Self.restoredFrame() ?? Self.defaultFrame(besideLens: lensFrame)
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.viewModel = viewModel

        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isMovable = false // DragContainerView drives moves and resizes

        let container = DragContainerView(frame: NSRect(origin: .zero, size: contentRect.size))
        container.wantsLayer = true
        container.layer?.cornerRadius = 18
        container.layer?.masksToBounds = true
        // Moving the reader must not disturb capture — it only needs its own
        // frame remembered.
        container.onDragEnd = { [weak viewModel] in viewModel?.readerMoved() }
        container.onHoverChange = { [weak viewModel] hovering in viewModel?.setReaderHovering(hovering) }
        container.onScrollOpacity = { [weak viewModel] delta in
            // Scroll up (positive deltaY) makes the glass more solid; scroll
            // down makes it more see-through. Range matches the menu bar slider.
            guard let viewModel else { return }
            let sensitivity = 0.0025
            let updated = viewModel.glassOpacity + Double(delta) * sensitivity
            viewModel.glassOpacity = updated.clamped(to: 0.15...1.0)
        }

        let effectView = NSVisualEffectView(frame: container.bounds)
        effectView.material = .hudWindow
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.autoresizingMask = [.width, .height]
        container.addSubview(effectView)

        let hostingView = NSHostingView(rootView: ReaderContentView(viewModel: viewModel))
        hostingView.frame = container.bounds
        hostingView.autoresizingMask = [.width, .height]
        container.addSubview(hostingView)

        contentView = container

        effectView.alphaValue = viewModel.glassOpacity
        viewModel.$glassOpacity
            .receive(on: RunLoop.main)
            .sink { [weak effectView] opacity in
                effectView?.alphaValue = opacity
            }
            .store(in: &cancellables)
    }

    private static func restoredFrame() -> NSRect? {
        guard let saved = UserDefaults.standard.string(forKey: OverlayViewModel.readerFrameKey) else {
            return nil
        }
        let rect = NSRectFromString(saved)
        guard rect.width >= DragContainerView.minLensSize.width,
              rect.height >= DragContainerView.minLensSize.height,
              NSScreen.screens.contains(where: { $0.frame.intersects(rect) })
        else {
            return nil
        }
        return rect
    }

    /// First run: sit to the right of the clear lens, or to its left when
    /// there isn't room, so the two windows don't launch stacked.
    private static func defaultFrame(besideLens lens: NSRect) -> NSRect {
        let visible = (NSScreen.main?.visibleFrame) ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = defaultSize
        let gap: CGFloat = 16

        var origin = NSPoint(x: lens.maxX + gap, y: lens.midY - size.height / 2)
        if origin.x + size.width > visible.maxX {
            origin.x = lens.minX - gap - size.width
        }
        origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        return NSRect(origin: origin, size: size)
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

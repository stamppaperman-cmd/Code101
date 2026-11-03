import AppKit

/// Shake the pointer while dragging a file (or image, or link) anywhere on
/// screen and the Drop Shelf pops up beside it, ready to take the drop.
///
/// Watches the system with global mouse monitors — mouse events, unlike key
/// events, need no Accessibility permission. A shake only counts during a
/// real drag-and-drop: the drag pasteboard must have changed since the mouse
/// went down, so moving a window or selecting text never triggers it.
@MainActor
final class ShakeToShelf {
    static let defaultsKey = "shakeToShelf"

    nonisolated(unsafe) private var monitors: [Any] = []
    private let onShake: (NSPoint) -> Void

    private var dragCountAtMouseDown = 0
    private var lastX: CGFloat = 0
    private var direction: CGFloat = 0
    private var travel: CGFloat = 0
    private var reversals: [TimeInterval] = []
    private var firedThisDrag = false

    /// A reversal only counts after this much sideways travel, so hand jitter
    /// during a normal drag never adds up to a shake.
    private let minTravel: CGFloat = 40
    /// This many quick direction changes inside `window` seconds = a shake.
    private let reversalsNeeded = 4
    private let window: TimeInterval = 0.9

    init(onShake: @escaping (NSPoint) -> Void) {
        self.onShake = onShake
        UserDefaults.standard.register(defaults: [Self.defaultsKey: true])

        if let down = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseDown() }
        }) { monitors.append(down) }
        if let drag = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.dragged() }
        }) { monitors.append(drag) }
    }

    private func mouseDown() {
        dragCountAtMouseDown = NSPasteboard(name: .drag).changeCount
        lastX = NSEvent.mouseLocation.x
        direction = 0
        travel = 0
        reversals.removeAll()
        firedThisDrag = false
    }

    private func dragged() {
        guard !firedThisDrag,
              UserDefaults.standard.bool(forKey: Self.defaultsKey)
        else { return }

        let location = NSEvent.mouseLocation
        let dx = location.x - lastX
        lastX = location.x
        guard dx != 0 else { return }

        let step: CGFloat = dx > 0 ? 1 : -1
        if step == direction {
            travel += abs(dx)
            return
        }
        // Direction flipped: count it only if the stroke before was long enough.
        if direction != 0, travel >= minTravel {
            let now = ProcessInfo.processInfo.systemUptime
            reversals.append(now)
            reversals.removeAll { now - $0 > window }
        }
        direction = step
        travel = abs(dx)

        guard reversals.count >= reversalsNeeded,
              NSPasteboard(name: .drag).changeCount != dragCountAtMouseDown
        else { return }
        firedThisDrag = true
        reversals.removeAll()
        onShake(location)
    }

    deinit {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
    }
}

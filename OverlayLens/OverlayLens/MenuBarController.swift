import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The app's one and only menu bar slot. A notched Mac runs out of menu bar
/// room fast, so the lens controls and the Drop Shelf share a single status
/// item instead of taking one each:
///
/// - left-click → controls popover (with a Drop Shelf entry)
/// - right-click / ctrl-click → Drop Shelf straight away
/// - drag files, images, or a link onto the icon → lands in the shelf
/// - ⌥⌘D anywhere → Drop Shelf
@MainActor
final class MenuBarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let shelf: DropShelfController

    init(shelf: DropShelfController, controls: AnyView) {
        self.shelf = shelf
        super.init()

        popover.behavior = .transient
        popover.delegate = self
        let hosting = NSHostingController(rootView: controls)
        // Rows at the top (Finish Engine, auto-resume) can change height
        // after launch; let the popover follow instead of clipping them.
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        popover.contentSize = hosting.view.fittingSize

        if let button = statusItem.button {
            button.image = Brand.menuBarMark()
            button.image?.accessibilityDescription = "StampLab"
            button.imagePosition = .imageLeft
            button.target = self
            button.action = #selector(handleClick)
            // Backstop in case the overlay below doesn't see the right-click.
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])

            // Pinned rather than autoresized: the item is variableLength, so
            // the button grows and shrinks with the shelf count badge and a
            // frame captured at init would stop covering it (silently killing
            // drops and right-clicks).
            let dropView = StatusItemDropView(frame: button.bounds)
            dropView.translatesAutoresizingMaskIntoConstraints = false
            wireDropTarget(dropView)
            button.addSubview(dropView)
            NSLayoutConstraint.activate([
                dropView.leadingAnchor.constraint(equalTo: button.leadingAnchor),
                dropView.trailingAnchor.constraint(equalTo: button.trailingAnchor),
                dropView.topAnchor.constraint(equalTo: button.topAnchor),
                dropView.bottomAnchor.constraint(equalTo: button.bottomAnchor),
            ])
        }

        shelf.model.badgeHandler = { [weak self] count in self?.updateBadge(count) }
        updateBadge(shelf.model.items.count)
    }

    /// Shared by the status item overlay and the screen-edge drop zone: both
    /// stage whatever was dropped and pop the shelf open.
    func wireDropTarget(_ view: StatusItemDropView) {
        view.onDragEntered = { [weak self] in self?.openShelf() }
        view.onURLs = { [weak self] urls in
            self?.shelf.model.add(urls: urls)
            self?.openShelf()
        }
        view.onImageData = { [weak self] data, type in
            self?.shelf.model.add(imageData: data, type: type)
            self?.openShelf()
        }
        view.onText = { [weak self] string in
            self?.shelf.model.addRaw(string)
            self?.openShelf()
        }
    }

    /// Shelf contents show as a count next to the icon — cheaper than a second
    /// status item, and it disappears again when the shelf is empty.
    private func updateBadge(_ count: Int) {
        statusItem.button?.title = count > 0 ? " \(count)" : ""
    }

    @objc private func handleClick() {
        let event = NSApp.currentEvent
        let isSecondary = event?.type == .rightMouseDown
            || event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true

        if isSecondary {
            openShelf()
        } else {
            togglePopover()
        }
    }

    private func openShelf() {
        popover.performClose(nil)
        shelf.show()
    }

    func toggleShelf() {
        popover.performClose(nil)
        shelf.toggle()
    }

    /// Called from the popover so picking Drop Shelf doesn't leave the
    /// controls hanging open behind it.
    func closePopover() {
        popover.performClose(nil)
    }

    var isPopoverShown: Bool { popover.isShown }

    /// Same controls, opened from the lens header instead of the status item —
    /// the icon can be stranded under the notch, the lens never is.
    func showControls(anchoredTo view: NSView) {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        let anchor = NSRect(
            x: view.bounds.maxX - 60,
            y: view.bounds.maxY - 26,
            width: 60,
            height: 26
        )
        popover.show(relativeTo: anchor, of: view, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    /// Opened from the Desktop icon / Finder: there's no window to bring back,
    /// so show the controls — otherwise the click looks like it did nothing.
    func showControls() {
        guard !popover.isShown, let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}

extension MenuBarController: NSPopoverDelegate {
    /// The popover keeps one hosting view for the app's whole life, so a row's
    /// `.onAppear` runs only the first time it opens. Anything the menu reads
    /// from disk is refreshed here instead — otherwise the saved-rules row
    /// kept showing rules that had already been deleted.
    func popoverWillShow(_ notification: Notification) {
        ClaudeApprovalRules.shared.reload()
    }
}

/// Invisible overlay on the status item button that accepts drags of files,
/// promised files (Photos), raw image data (browser images), and links or
/// text dragged straight from a browser address bar or a chat window.
final class StatusItemDropView: NSView {
    var onURLs: (([URL]) -> Void)?
    var onImageData: ((Data, UTType) -> Void)?
    var onText: ((String) -> Void)?
    var onDragEntered: (() -> Void)?
    var onDragExited: (() -> Void)?

    private static let promiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        return queue
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        var types: [NSPasteboard.PasteboardType] = [.fileURL, .png, .tiff, .URL, .string]
        types += NSFilePromiseReceiver.readableDraggedTypes.map {
            NSPasteboard.PasteboardType($0)
        }
        registerForDraggedTypes(types)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onDragEntered?()
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onDragExited?()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        onDragExited?()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard

        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty {
            onURLs?(urls)
            return true
        }

        if let receivers = pasteboard.readObjects(
            forClasses: [NSFilePromiseReceiver.self]
        ) as? [NSFilePromiseReceiver], !receivers.isEmpty {
            for receiver in receivers {
                receiver.receivePromisedFiles(
                    atDestination: DropShelfModel.stagingDirectory,
                    options: [:],
                    operationQueue: Self.promiseQueue
                ) { [weak self] url, error in
                    guard error == nil else { return }
                    DispatchQueue.main.async { self?.onURLs?([url]) }
                }
            }
            return true
        }

        if let data = pasteboard.data(forType: .png) {
            onImageData?(data, .png)
            return true
        }
        if let data = pasteboard.data(forType: .tiff) {
            onImageData?(data, .tiff)
            return true
        }

        // A dragged address bar carries .URL; selected text carries .string.
        if let string = pasteboard.string(forType: .URL) ?? pasteboard.string(forType: .string) {
            onText?(string)
            return true
        }

        return false
    }

    // The overlay swallows clicks, so re-trigger the button's action manually.
    override func mouseDown(with event: NSEvent) {
        sendButtonAction()
    }

    override func rightMouseDown(with event: NSEvent) {
        sendButtonAction()
    }

    private func sendButtonAction() {
        guard let button = superview as? NSStatusBarButton,
              let action = button.action
        else { return }
        NSApp.sendAction(action, to: button.target, from: button)
    }
}

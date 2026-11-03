import AppKit
import Carbon.HIToolbox
import UniformTypeIdentifiers

/// Standalone Drop Shelf: the AirDrop staging shelf from OverlayLens, on its
/// own with a single menu bar icon.
///
/// - left-click the icon → shelf
/// - right-click / ctrl-click → menu (shake toggle, quit)
/// - drag files, images, or a link onto the icon → lands in the shelf
/// - ⌃⌥⌘D anywhere → shelf
/// - shake the pointer while dragging → shelf pops up beside it
@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var shelf: DropShelfController?
    private var menuBar: MenuBarController?
    private var shelfHotKey: HotKeyManager?
    private var shakeToShelf: ShakeToShelf?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let shelf = DropShelfController()
        self.shelf = shelf
        menuBar = MenuBarController(shelf: shelf)

        // ⌃⌥⌘D (plain ⌥⌘D is macOS's Dock show/hide and never arrives).
        shelfHotKey = HotKeyManager(
            keyCode: UInt32(kVK_ANSI_D),
            modifiers: UInt32(controlKey | optionKey | cmdKey),
            id: 1
        ) { [weak self] in
            Task { @MainActor in self?.shelf?.toggle() }
        }
        shakeToShelf = ShakeToShelf { [weak shelf] point in
            shelf?.show(near: point)
        }

        // No Dock icon, so a first-time user would see nothing happen on
        // launch. Show the shelf once so they know where it lives.
        let firstRunKey = "DropShelfDidFirstRun"
        if !UserDefaults.standard.bool(forKey: firstRunKey) {
            UserDefaults.standard.set(true, forKey: firstRunKey)
            // Straight from didFinishLaunching the panel never reaches the
            // screen; give the run loop a beat first.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak shelf] in
                shelf?.show()
            }
        }
    }

    /// Opening the app again from Finder/Launchpad while it's running brings
    /// the shelf up instead of doing nothing.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        shelf?.show()
        return false
    }
}

@MainActor
final class MenuBarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let shelf: DropShelfController

    init(shelf: DropShelfController) {
        self.shelf = shelf
        super.init()

        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "tray.and.arrow.up.fill", accessibilityDescription: "Drop Shelf")
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageLeft
            button.target = self
            button.action = #selector(handleClick)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])

            // Pinned rather than autoresized: the item is variableLength, so
            // the button grows and shrinks with the shelf count badge.
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

    private func wireDropTarget(_ view: StatusItemDropView) {
        view.onDragEntered = { [weak self] in self?.shelf.show() }
        view.onURLs = { [weak self] urls in
            self?.shelf.model.add(urls: urls)
            self?.shelf.show()
        }
        view.onImageData = { [weak self] data, type in
            self?.shelf.model.add(imageData: data, type: type)
            self?.shelf.show()
        }
        view.onText = { [weak self] string in
            self?.shelf.model.addRaw(string)
            self?.shelf.show()
        }
    }

    private func updateBadge(_ count: Int) {
        statusItem.button?.title = count > 0 ? " \(count)" : ""
    }

    @objc private func handleClick() {
        let event = NSApp.currentEvent
        let isSecondary = event?.type == .rightMouseDown
            || event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true

        if isSecondary {
            showMenu()
        } else {
            shelf.toggle()
        }
    }

    private func showMenu() {
        let menu = NSMenu()

        let open = NSMenuItem(title: "เปิด Drop Shelf", action: #selector(openShelf), keyEquivalent: "")
        open.target = self
        menu.addItem(open)

        let shake = NSMenuItem(title: "เขย่าเมาส์ตอนลากไฟล์เพื่อเปิด", action: #selector(toggleShake), keyEquivalent: "")
        shake.target = self
        shake.state = UserDefaults.standard.bool(forKey: ShakeToShelf.defaultsKey) ? .on : .off
        menu.addItem(shake)

        menu.addItem(.separator())
        let hint = NSMenuItem(title: "คีย์ลัด ⌃⌥⌘D · คลิกซ้ายที่ไอคอนเพื่อเปิด/ปิด", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "ออกจาก Drop Shelf", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        guard let button = statusItem.button else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 4), in: button)
    }

    @objc private func openShelf() { shelf.show() }

    @objc private func toggleShake() {
        let key = ShakeToShelf.defaultsKey
        UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: key), forKey: key)
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

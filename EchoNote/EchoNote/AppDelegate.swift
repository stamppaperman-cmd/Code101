import AppKit

/// Lets files arrive from Finder ("Open With"), the Dock icon, or `open -a EchoNote file.m4a`.
/// URLs that land before the UI exists are buffered and flushed once it does.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var buffered: [URL] = []

    var onOpen: (([URL]) -> Void)? {
        didSet {
            guard let onOpen, !buffered.isEmpty else { return }
            let pending = buffered
            buffered.removeAll()
            onOpen(pending)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if let onOpen {
            onOpen(urls)
        } else {
            buffered.append(contentsOf: urls)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

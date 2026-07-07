import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: OverlayPanel?
    let viewModel = OverlayViewModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let panel = OverlayPanel(viewModel: viewModel)
        self.panel = panel
        viewModel.panelFrameProvider = { [weak panel] in panel?.frame ?? .zero }
        viewModel.panelVisibilityHandler = { [weak panel] visible in
            if visible {
                panel?.orderFrontRegardless()
            } else {
                panel?.orderOut(nil)
            }
        }
        panel.orderFrontRegardless()

        viewModel.checkPermissionAndStart()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.viewModel.appDidBecomeActive()
            }
        }
    }
}

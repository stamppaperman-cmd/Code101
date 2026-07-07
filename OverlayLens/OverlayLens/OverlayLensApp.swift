import SwiftUI

@main
struct OverlayLensApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("OverlayLens", systemImage: "text.magnifyingglass") {
            Button("Quit OverlayLens") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}

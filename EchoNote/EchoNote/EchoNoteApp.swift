import SwiftUI

@main
struct EchoNoteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .frame(minWidth: 880, minHeight: 540)
                .onAppear {
                    appDelegate.onOpen = { urls in model.addFiles(urls) }
                }
        }
        .defaultSize(width: 1120, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("เพิ่มไฟล์…") { model.showOpenPanel() }
                    .keyboardShortcut("o", modifiers: .command)
            }
        }
    }
}

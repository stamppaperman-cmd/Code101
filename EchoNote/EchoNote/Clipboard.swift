import AppKit

enum Clipboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

enum FileExport {
    static func save(_ text: String, suggestedName: String) {
        save(Data(text.utf8), suggestedName: suggestedName)
    }

    static func save(_ data: Data?, suggestedName: String) {
        guard let data else {
            NSSound.beep()
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url, options: .atomic)
    }
}

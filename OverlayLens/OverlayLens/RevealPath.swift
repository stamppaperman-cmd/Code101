import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// ⌃⌥⌘O: open the path in the selected text in Finder, from any app —
/// including ones whose right-click menu has no Services (the Claude app).
/// Copies the selection with a synthetic ⌘C (needs Accessibility), hands the
/// text to reveal_path.py (~/Claude/Projects/reveal-path, which owns the path
/// parsing and its tests), then puts the old clipboard back. Nothing selected
/// or no permission → uses what's already on the clipboard, so
/// "Copy, then ⌃⌥⌘O" works too.
@MainActor
enum RevealPath {
    static let script = NSString(string: "~/Claude/Projects/reveal-path/reveal_path.py").expandingTildeInPath
    private static var askedThisLaunch = false

    static var canCopySelection: Bool { AXIsProcessTrusted() }

    static func askForAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func run() {
        if !canCopySelection && !askedThisLaunch {
            askedThisLaunch = true
            askForAccessibility()
        }
        Task { @MainActor in reveal(await selectedText()) }
    }

    private static func selectedText() async -> String {
        let pb = NSPasteboard.general
        guard canCopySelection else { return pb.string(forType: .string) ?? "" }
        // The hotkey fires while ⌃⌥⌘ are still down; let them come up first
        // or the app gets ⌃⌥⌘C instead of ⌘C.
        let held: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand, .maskShift]
        var waited = 0
        while waited < 40, !CGEventSource.flagsState(.combinedSessionState).intersection(held).isEmpty {
            try? await Task.sleep(for: .milliseconds(25))
            waited += 1
        }
        let saved = snapshot(pb)
        let before = pb.changeCount
        postCopy()
        waited = 0
        while waited < 20, pb.changeCount == before {
            try? await Task.sleep(for: .milliseconds(25))
            waited += 1
        }
        guard pb.changeCount != before else { return pb.string(forType: .string) ?? "" }
        let text = pb.string(forType: .string) ?? ""
        restore(saved, to: pb)
        return text
    }

    private static func postCopy() {
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: down)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
    }

    private static func snapshot(_ pb: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pb.pasteboardItems ?? []).map { item in
            Dictionary(item.types.compactMap { type in item.data(forType: type).map { (type, $0) } },
                       uniquingKeysWith: { first, _ in first })
        }
    }

    private static func restore(_ items: [[NSPasteboard.PasteboardType: Data]], to pb: NSPasteboard) {
        pb.clearContents()
        guard !items.isEmpty else { return }
        pb.writeObjects(items.map { types in
            let item = NSPasteboardItem()
            for (type, data) in types { item.setData(data, forType: type) }
            return item
        })
    }

    private static func reveal(_ text: String) {
        guard FileManager.default.fileExists(atPath: script) else {
            NSSound.beep()
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [script]
        let input = Pipe()
        process.standardInput = input
        do {
            try process.run()
        } catch {
            NSSound.beep()
            return
        }
        input.fileHandleForWriting.write(Data(text.utf8))
        try? input.fileHandleForWriting.close()
    }
}

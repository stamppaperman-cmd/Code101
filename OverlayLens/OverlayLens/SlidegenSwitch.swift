import Foundation

/// On/off switch for the local slide-image generator in ~/Claude/slidegen.
/// Off = a flag file that the generator scripts (`slidegen_switch.py`) and the
/// Claude Code hook (`slidegen-guard`) both check, so Claude and Codex stop
/// using slidegen until it is switched back on. Switching off mid-run lets the
/// image being drawn finish, then the run stops.
enum SlidegenSwitch {
    static let flagURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/StampLab/slidegen-off")

    static var isOn: Bool { !FileManager.default.fileExists(atPath: flagURL.path) }

    static func set(on: Bool) {
        let fm = FileManager.default
        if on {
            try? fm.removeItem(at: flagURL)
        } else {
            try? fm.createDirectory(at: flagURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data("ปิดจาก StampLab \(Date())\n".utf8).write(to: flagURL)
        }
    }
}

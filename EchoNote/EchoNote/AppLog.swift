import Foundation

/// Three runs died on this machine leaving nothing behind: no `.ips` crash report,
/// no `log show` output, no jetsam entry. Each one had to be diagnosed by inferring
/// backwards from `job.json`, which only persists on 5% steps. A plain text file
/// costs nothing and turns "the app vanished" into a timestamped last line — and,
/// because the memory footprint is written with every entry, into evidence about
/// why it vanished.
///
/// Deliberately not an actor: the transcription actor, the main actor and
/// WhisperKit's own worker threads all write here, and a log that forces its
/// callers to await is a log that stops being used.
final class AppLog: @unchecked Sendable {
    static let shared = AppLog()

    private let queue = DispatchQueue(label: "com.echonote.log")
    private var handle: FileHandle?
    let url: URL
    let previousURL: URL

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = support.appendingPathComponent("EchoNote", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        url = folder.appendingPathComponent("echonote.log")
        previousURL = folder.appendingPathComponent("echonote-previous.log")

        // One previous run is worth keeping — that is where the death of the run
        // before this one is recorded. Anything older is noise.
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        if (attributes?[.size] as? Int ?? 0) > 4_000_000 {
            try? FileManager.default.removeItem(at: previousURL)
            try? FileManager.default.moveItem(at: url, to: previousURL)
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        try? handle?.seekToEnd()
    }

    /// Resident footprint in MB — the number macOS actually weighs when it decides
    /// to kill something, so it belongs on every line rather than in a separate tool.
    static var footprintMB: Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.phys_footprint) / 1_048_576
    }

    func write(_ message: String) {
        let stamp = Self.formatter.string(from: Date())
        let line = String(format: "%@ [%6.0f MB] %@\n", stamp, Self.footprintMB, message)
        queue.async { [handle] in
            guard let data = line.data(using: .utf8) else { return }
            try? handle?.write(contentsOf: data)
        }
    }

    /// Blocks until everything queued has hit the disk. Called before work that has
    /// killed the process before, so the last line survives the kill.
    func flush() {
        queue.sync { try? handle?.synchronize() }
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        // Pinned to the Gregorian calendar: on a Thai system the default renders 2569
        // for 2026, which makes the log impossible to line up against `log show` or a
        // crash report.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()
}

/// Shorthand — `log("…")` reads better at the call sites that matter.
func log(_ message: String) { AppLog.shared.write(message) }

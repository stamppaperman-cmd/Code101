import Foundation

/// Naming and validation for audio files dropped on the Meeting card.
/// Pure logic (no AppKit) so the logic tests can cover it.
enum MeetingImport {
    /// Containers macOS can decode for us: audio files, plus the video
    /// wrappers a recorded call usually arrives in (we only read their audio).
    static let supportedExtensions: Set<String> = [
        "m4a", "mp3", "wav", "wave", "caf", "aif", "aiff", "aifc",
        "aac", "adts", "flac", "mp4", "m4v", "mov", "m4b", "amr", "3gp",
    ]

    static func isSupported(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    /// Dropping an .m4a needs no transcoding: the pipeline reads it directly.
    static func needsTranscode(_ url: URL) -> Bool {
        url.pathExtension.lowercased() != "m4a"
    }

    private static func formatter(_ pattern: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = pattern
        return f
    }

    /// The file's own name, minus extension and anything that cannot go in a
    /// folder name. A dot-file such as ".m4a" leaves nothing usable behind.
    static func stem(of url: URL) -> String {
        let raw = url.lastPathComponent
        let withoutExtension = raw.hasPrefix(".") ? "" : url.deletingPathExtension().lastPathComponent
        let cleaned = sanitise(withoutExtension)
        return cleaned.isEmpty ? "ไฟล์เสียง" : cleaned
    }

    /// Folder name of an imported session. The `yyyy-MM-dd_HHmm` prefix is what
    /// `MeetingRecorderModel.session(at:)` parses, so it has to stay first.
    static func folderName(for url: URL, date: Date) -> String {
        "\(formatter("yyyy-MM-dd_HHmm").string(from: date))_\(stem(of: url))"
    }

    /// Card / notes title: the file's own name, then when it was imported.
    static func title(for url: URL, date: Date) -> String {
        "\(stem(of: url)) · \(formatter("yyyy-MM-dd HH:mm").string(from: date))"
    }

    /// Keeps file names usable as a folder name: no separators, no leading
    /// dot, not endless.
    static func sanitise(_ name: String) -> String {
        var out = name
        for bad in ["/", ":", "\n", "\r", "\t"] { out = out.replacingOccurrences(of: bad, with: " ") }
        out = out.trimmingCharacters(in: .whitespacesAndNewlines)
        while out.hasPrefix(".") { out.removeFirst() }
        out = out.trimmingCharacters(in: .whitespaces)
        return String(out.prefix(60)).trimmingCharacters(in: .whitespaces)
    }

    /// Adds `-2`, `-3`… when a folder of that name is already there, so two
    /// imports of the same file in one minute never overwrite each other.
    static func uniqueFolder(in root: URL, named name: String, exists: (URL) -> Bool) -> URL {
        var candidate = root.appendingPathComponent(name, isDirectory: true)
        var n = 2
        while exists(candidate), n < 100 {
            candidate = root.appendingPathComponent("\(name)-\(n)", isDirectory: true)
            n += 1
        }
        return candidate
    }

    /// What to say when the drop holds nothing we can read.
    static func rejectionMessage(for urls: [URL]) -> String? {
        guard !urls.isEmpty else { return "ไม่พบไฟล์ที่วาง" }
        guard urls.allSatisfy({ !isSupported($0) }) else { return nil }
        let names = urls.map { $0.lastPathComponent }.prefix(2).joined(separator: ", ")
        return "เปิดไฟล์นี้ไม่ได้ (\(names)) — รองรับไฟล์เสียงและวิดีโอ เช่น m4a, mp3, wav, caf, mp4, mov"
    }
}

enum MeetingImportError: LocalizedError {
    case noAudioTrack(String)
    case decodeFailed(String)

    var errorDescription: String? {
        switch self {
        case .noAudioTrack(let name): return "ไฟล์ \(name) ไม่มีเสียงอยู่ข้างใน"
        case .decodeFailed(let name): return "แปลงไฟล์ \(name) เป็นเสียงไม่สำเร็จ — ลองแปลงเป็น .m4a หรือ .wav ก่อน"
        }
    }
}

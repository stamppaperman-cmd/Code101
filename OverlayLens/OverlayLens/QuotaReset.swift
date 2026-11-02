import Foundation

/// Reads when a claude.ai usage limit resets out of Claude Code's limit
/// message, e.g. "You've hit your session limit · resets 1:30am (Asia/Bangkok)"
/// or a weekly "resets Mon 3:00 AM". Shared by ambient-hook (it writes the
/// paused-session record) and the logic tests. No match → nil, and StampLab
/// falls back to the 5-hour window.
enum QuotaReset {
    static func parse(_ text: String, now: Date = Date(), calendar: Calendar = .current) -> Date? {
        let lower = text.lowercased()
        let pattern = #"resets\s+(?:at\s+)?(?:(mon|tue|wed|thu|fri|sat|sun)[a-z]*,?\s+)?(\d{1,2})(?::(\d{2}))?\s*(am|pm)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower))
        else { return nil }
        func group(_ i: Int) -> String? {
            Range(match.range(at: i), in: lower).map { String(lower[$0]) }
        }
        guard var hour = group(2).flatMap(Int.init) else { return nil }
        let minute = group(3).flatMap(Int.init) ?? 0
        if let ampm = group(4) {
            guard (1...12).contains(hour) else { return nil }
            hour = ampm == "am" ? hour % 12 : hour % 12 + 12
        }
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }

        var calendar = calendar
        // The message names its zone, e.g. "(Asia/Bangkok)" — trust it over ours.
        if let zone = text.range(of: #"\(([A-Za-z_]+/[A-Za-z_]+)\)"#, options: .regularExpression),
           let tz = TimeZone(identifier: String(text[zone].dropFirst().dropLast())) {
            calendar.timeZone = tz
        }
        var parts = DateComponents(hour: hour, minute: minute, second: 0)
        if let day = group(1) {
            parts.weekday = ["sun": 1, "mon": 2, "tue": 3, "wed": 4, "thu": 5, "fri": 6, "sat": 7][day]
        }
        return calendar.nextDate(after: now, matching: parts, matchingPolicy: .nextTime)
    }

    /// Latest chat title in a transcript tail: Claude Code appends
    /// {"type":"custom-title","customTitle":"…"} whenever a chat is (re)named.
    static func sessionTitle(inTranscriptTail tail: String) -> String? {
        for line in tail.split(separator: "\n").reversed() where line.contains("\"custom-title\"") {
            if let data = line.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let title = object["customTitle"] as? String, !title.isEmpty {
                return title
            }
        }
        return nil
    }

    /// The last `bytes` of a transcript — they run to 20 MB+, so never read it whole.
    static func tail(ofFile path: String, bytes: UInt64 = 262_144) -> String {
        guard let handle = FileHandle(forReadingAtPath: path) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > bytes ? size - bytes : 0)
        return String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
    }
}

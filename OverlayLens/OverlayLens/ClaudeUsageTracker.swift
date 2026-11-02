import Foundation

/// Token usage summed from Claude Code's local transcripts.
///
/// Anthropic doesn't expose the real quota, so this mirrors what `ccusage`
/// does: Claude Code appends every API response (with its token usage) to
/// `~/.claude/projects/**/*.jsonl`; usage is rate-limited in 5-hour blocks
/// that start on the hour of the first message after the previous block
/// ends. Totals here cover Claude Code only — chat in the Claude desktop
/// app doesn't write these files.
struct ClaudeUsage {
    var blockInput = 0
    var blockOutput = 0
    var blockCacheWrite = 0
    var blockCacheRead = 0
    /// Start/end of the active 5-hour block; nil when nothing was used in
    /// the current window (fully reset).
    var blockStart: Date?
    var blockEnd: Date?
    var todayTotal = 0
    /// Rolling total over the last 7 days (Claude also has a weekly limit).
    var weekTotal = 0
    /// Largest block total in the scanned window, as a rough baseline for
    /// how far the current block has gone.
    var maxBlockTotal = 0

    /// Percent of the block believed to remain, measured against the
    /// heaviest block in the scan window since the real quota is opaque.
    var remainingPercent: Int {
        let baseline = max(maxBlockTotal, blockTotal)
        guard blockEnd != nil, baseline > 0 else { return 100 }
        return max(0, 100 - Int(Double(blockTotal) / Double(baseline) * 100))
    }

    var blockTotal: Int { blockInput + blockOutput + blockCacheWrite + blockCacheRead }
}

enum ClaudeUsageTracker {
    private struct Entry {
        let time: Date
        let input: Int
        let output: Int
        let cacheWrite: Int
        let cacheRead: Int
        var total: Int { input + output + cacheWrite + cacheRead }
    }

    private static let blockLength: TimeInterval = 5 * 3600

    static func compute(now: Date = Date()) -> ClaudeUsage {
        var entries = collectEntries(since: now.addingTimeInterval(-7 * 24 * 3600))
        entries.sort { $0.time < $1.time }

        // Group into 5-hour blocks, each starting on the hour of its first
        // entry.
        struct Block {
            var start: Date
            var end: Date
            var input = 0, output = 0, cacheWrite = 0, cacheRead = 0
            var total: Int { input + output + cacheWrite + cacheRead }
        }
        var blocks: [Block] = []
        for entry in entries {
            if blocks.isEmpty || entry.time >= blocks[blocks.count - 1].end {
                let start = floorToHour(entry.time)
                blocks.append(Block(start: start, end: start.addingTimeInterval(blockLength)))
            }
            blocks[blocks.count - 1].input += entry.input
            blocks[blocks.count - 1].output += entry.output
            blocks[blocks.count - 1].cacheWrite += entry.cacheWrite
            blocks[blocks.count - 1].cacheRead += entry.cacheRead
        }

        var usage = ClaudeUsage()
        usage.maxBlockTotal = blocks.map(\.total).max() ?? 0
        usage.weekTotal = entries.reduce(0) { $0 + $1.total }
        usage.todayTotal = entries
            .filter { Calendar.current.isDateInToday($0.time) }
            .reduce(0) { $0 + $1.total }

        if let current = blocks.last, now < current.end {
            usage.blockInput = current.input
            usage.blockOutput = current.output
            usage.blockCacheWrite = current.cacheWrite
            usage.blockCacheRead = current.cacheRead
            usage.blockStart = current.start
            usage.blockEnd = current.end
        }
        return usage
    }

    // MARK: - Transcript parsing

    private static func collectEntries(since cutoff: Date) -> [Entry] {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return [] }

        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()

        // Files untouched for longer than the scan window (plus margin)
        // can't contain relevant lines.
        let mtimeCutoff = cutoff.addingTimeInterval(-6 * 3600)

        var entries: [Entry] = []
        var seen = Set<String>()

        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard let mtime = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate,
                mtime > mtimeCutoff,
                let content = try? String(contentsOf: url, encoding: .utf8)
            else { continue }

            for line in content.split(separator: "\n") {
                guard let usageStart = line.range(of: "\"usage\":{"),
                      let timestamp = extract(line, after: "\"timestamp\":\"", upTo: "\""),
                      let time = withFractional.date(from: timestamp) ?? plain.date(from: timestamp),
                      time > cutoff
                else { continue }

                // The interesting numbers sit right after "usage":{ — cap the
                // window so huge lines (embedded images etc.) stay cheap.
                let windowEnd = line.index(
                    usageStart.upperBound,
                    offsetBy: 400,
                    limitedBy: line.endIndex
                ) ?? line.endIndex
                let window = line[usageStart.upperBound..<windowEnd]

                // Retries can duplicate a message across lines; count each
                // API response once.
                let messageID = extract(line, after: "\"id\":\"msg_", upTo: "\"") ?? ""
                let requestID = extract(line, after: "\"requestId\":\"", upTo: "\"") ?? ""
                if !messageID.isEmpty, !seen.insert(messageID + requestID).inserted { continue }

                entries.append(Entry(
                    time: time,
                    input: extractInt(window, after: "\"input_tokens\":"),
                    output: extractInt(window, after: "\"output_tokens\":"),
                    cacheWrite: extractInt(window, after: "\"cache_creation_input_tokens\":"),
                    cacheRead: extractInt(window, after: "\"cache_read_input_tokens\":")
                ))
            }
        }
        return entries
    }

    private static func extract(_ line: Substring, after prefix: String, upTo terminator: Character) -> String? {
        guard let start = line.range(of: prefix)?.upperBound,
              let end = line[start...].firstIndex(of: terminator)
        else { return nil }
        return String(line[start..<end])
    }

    private static func extractInt(_ window: Substring, after prefix: String) -> Int {
        guard let start = window.range(of: prefix)?.upperBound else { return 0 }
        let digits = window[start...].prefix(while: \.isNumber)
        return Int(digits) ?? 0
    }

    private static func floorToHour(_ date: Date) -> Date {
        let seconds = date.timeIntervalSinceReferenceDate
        return Date(timeIntervalSinceReferenceDate: (seconds / 3600).rounded(.down) * 3600)
    }

    // MARK: - Formatting

    static func compact(_ tokens: Int) -> String {
        switch tokens {
        case 1_000_000...: return String(format: "%.2fM", Double(tokens) / 1_000_000)
        case 1_000...: return String(format: "%.0fK", Double(tokens) / 1_000)
        default: return "\(tokens)"
        }
    }
}

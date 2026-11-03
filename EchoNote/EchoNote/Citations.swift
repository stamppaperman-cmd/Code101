import Foundation

/// One statement in a summary, with the transcript segments it came from.
///
/// A summary without citations can only ever be audited as a whole: `SummaryAudit`
/// could say "มกราคม is not in the transcript" but not where the model got it, which
/// left a reader to search 1,092 lines by hand. With the segments attached, the same
/// warning becomes a two-second check — and, because this app owns the audio, the
/// check can be to play the recording at that second rather than to read.
struct Claim: Codable, Hashable, Identifiable {
    var text: String
    var segmentIds: [Int]
    /// Segment numbers the model cited that do not exist. A model inventing its own
    /// evidence is exactly the failure this layer exists to catch, so it is recorded
    /// rather than quietly dropped.
    var invalidIds: [Int]?

    var id: String { text }
    var isGrounded: Bool { !segmentIds.isEmpty }
    var hasHallucinatedCitation: Bool { !(invalidIds ?? []).isEmpty }
}

/// A doubtful fact plus the lines the claim said it came from.
struct LocatedWarning: Codable, Hashable, Identifiable {
    var claim: String
    /// Facts that appear nowhere in the transcript. The model made these up.
    var missing: [String]
    /// Facts that are somewhere in the transcript but not in the segments this claim
    /// cited. The fact is real; the claim attached it to the wrong moment — a failure
    /// that is invisible without citations, and the reason they are worth collecting.
    var misplaced: [String]
    var segmentIds: [Int]
    /// The cited transcript text, carried along so the reader does not have to go
    /// looking for it.
    var quotes: [String]

    var id: String { claim }

    var severity: String { missing.isEmpty ? "อ้างผิดที่" : "ไม่พบในต้นฉบับ" }

    var summary: String {
        var parts = [String]()
        if !missing.isEmpty { parts.append("ไม่พบในต้นฉบับ: \(missing.joined(separator: ", "))") }
        if !misplaced.isEmpty { parts.append("มีในไฟล์แต่ไม่ได้อยู่ในบรรทัดที่อ้าง: \(misplaced.joined(separator: ", "))") }
        return "\"\(claim)\" — \(parts.joined(separator: " · "))"
    }

    var timeLabels: [String] { [] }
}

/// Reading and writing `[#12]` markers, and the numbering that makes them possible.
enum Citations {
    /// `[#12]`, `[#12, #15]`, `[#12 #15]`, `[#12,15]` — models are inconsistent about
    /// separators and there is no reason to lose a real citation over a comma.
    private static let bracketed = try! NSRegularExpression(
        pattern: #"\[\s*#?\s*\d+(?:\s*[,;、]?\s*#?\s*\d+)*\s*\]"#)

    /// Measured on the first real run: told to write `[#42]`, a 9B model instead copied
    /// the transcript's own `#42` prefix to the front of the sentence — every claim was
    /// cited and the parser scored 0%. Insisting harder in the prompt is the move this
    /// codebase has already learned not to make, so the bare form is accepted too.
    ///
    /// Only at the very start or the very end of a line, so a `#` inside a sentence is
    /// left alone.
    private static let leadingRun = try! NSRegularExpression(
        pattern: #"^\s*#\d+(?:\s*[,;、]?\s*#\d+)*\s*[:.\-–—]?\s*"#)
    private static let trailingRun = try! NSRegularExpression(
        pattern: #"\s*[(\[]?\s*#\d+(?:\s*[,;、]?\s*#\d+)*\s*[)\]]?\s*$"#)

    /// Splits a model's line into the sentence and the segment numbers it cited.
    static func parse(_ line: String) -> (text: String, ids: [Int]) {
        var text = line
        var inner = [[Int]]()

        // Bracketed markers are walked back-to-front so removing one cannot shift the
        // ranges of the others. Each match keeps its own numbers in reading order, and
        // the groups are put back in reading order at the end — reversing the flattened
        // list instead would silently swap [#42, #43] into [43, 42].
        let matches = bracketed.matches(in: line, range: NSRange(line.startIndex..., in: line))
        for match in matches.reversed() {
            guard let range = Range(match.range, in: line),
                  let stripRange = Range(match.range, in: text) else { continue }
            inner.append(numbers(in: String(line[range])))
            text.removeSubrange(stripRange)
        }

        let leading = take(leadingRun, from: &text)
        let trailing = take(trailingRun, from: &text)

        var seen = Set<Int>()
        let ids = (leading + inner.reversed().flatMap { $0 } + trailing)
            .filter { seen.insert($0).inserted }
        return (text.trimmingCharacters(in: .whitespacesAndNewlines), ids)
    }

    /// Removes one anchored run of bare `#n` markers and returns the numbers in it.
    /// A line that is *only* markers is left alone — stripping it would leave nothing
    /// to attach them to, and `claim(from:)` drops empty statements anyway.
    private static func take(_ expression: NSRegularExpression, from text: inout String) -> [Int] {
        guard let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text),
              !range.isEmpty else { return [] }
        let found = numbers(in: String(text[range]))
        guard !found.isEmpty, range.lowerBound != text.startIndex || range.upperBound != text.endIndex
        else { return found }
        text.removeSubrange(range)
        return found
    }

    /// Turns one model line into a claim, keeping only citations that point at a
    /// segment that actually exists.
    static func claim(from line: String, validIds: Set<Int>) -> Claim? {
        let (text, ids) = parse(line)
        guard !text.isEmpty else { return nil }
        let valid = ids.filter { validIds.contains($0) }
        let invalid = ids.filter { !validIds.contains($0) }
        return Claim(text: text, segmentIds: valid, invalidIds: invalid.isEmpty ? nil : invalid)
    }

    /// The transcript as the summarizer sees it: every line carries the number the
    /// model is required to cite it by.
    static func numbered(_ segments: [Segment], corrected: Bool) -> [String] {
        segments.map { "#\($0.id) [\($0.startLabel)] \($0.display(corrected: corrected))" }
    }

    /// Share of statements that carry at least one real citation — the one number
    /// that says whether the grounding is working on this file.
    static func groundedShare(_ claims: [Claim]) -> Double? {
        guard !claims.isEmpty else { return nil }
        return Double(claims.filter(\.isGrounded).count) / Double(claims.count)
    }

    private static func numbers(in text: String) -> [Int] {
        var found = [Int]()
        var current = ""
        for character in text {
            if character.isNumber {
                current.append(character)
            } else if !current.isEmpty {
                if let value = Int(current) { found.append(value) }
                current = ""
            }
        }
        if let value = Int(current) { found.append(value) }
        return found
    }
}

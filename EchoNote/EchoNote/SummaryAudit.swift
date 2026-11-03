import Foundation

/// A 9B model summarizing Thai will occasionally rewrite a fact it half-heard —
/// วันพุธ quietly becomes วันพฤหัสบดี, and nothing in the output looks wrong.
///
/// This checks the summary's hard facts (numbers, weekdays, months) against the
/// transcript it was built from. It cannot catch every drift, but it catches the
/// class of error that is invisible to a reader who wasn't at the meeting.
///
/// With citations attached it catches a second class as well. A fact that exists in
/// the transcript but not in the segments the claim cited is a real fact bolted to
/// the wrong moment — the summary reads perfectly and is still wrong, and nothing
/// short of a citation can see it.
enum SummaryAudit {
    private static let weekdays = ["จันทร์", "อังคาร", "พุธ", "พฤหัสบดี", "พฤหัส",
                                   "ศุกร์", "เสาร์", "อาทิตย์"]

    private static let months = ["มกราคม", "กุมภาพันธ์", "มีนาคม", "เมษายน", "พฤษภาคม",
                                 "มิถุนายน", "กรกฎาคม", "สิงหาคม", "กันยายน", "ตุลาคม",
                                 "พฤศจิกายน", "ธันวาคม"]

    /// Hard facts in `claim` that do not appear in `source`.
    static func unsupported(in claim: String, source: String) -> [String] {
        var missing = [String]()
        for day in weekdays where claim.contains(day) && !source.contains(day) {
            missing.append("วัน\(day)")
        }
        for month in months where claim.contains(month) && !source.contains(month) {
            missing.append(month)
        }
        for number in numbers(in: claim) where !source.contains(number) {
            missing.append(number)
        }
        return Array(NSOrderedSet(array: missing)) as? [String] ?? missing
    }

    static func hasCJK(_ text: String) -> Bool {
        text.contains { $0.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) } }
    }

    /// Text-only audit, kept for summaries that carry no citations.
    static func warnings(for summary: Summary, transcript: String) -> [String] {
        let claims = ([summary.tldr] + summary.bullets + summary.actions)
            .filter { !$0.isEmpty }

        var results = [String]()
        for claim in claims {
            var missing = unsupported(in: claim, source: transcript)
            if hasCJK(claim) { missing.append("มีตัวอักษรจีนปนมา") }
            guard !missing.isEmpty else { continue }
            results.append("\"\(claim)\" — ไม่พบในต้นฉบับ: \(missing.joined(separator: ", "))")
        }
        return results
    }

    /// The same audit, but every finding knows which lines to look at — and gains a
    /// check that has no text-only equivalent: whether the claim's own citations
    /// actually contain the fact it asserts.
    static func located(claims: [Claim],
                        segments: [Segment],
                        corrected: Bool) -> [LocatedWarning] {
        let transcript = segments.map { $0.display(corrected: corrected) }.joined(separator: " ")
        var byId = [Int: String]()
        for segment in segments { byId[segment.id] = segment.display(corrected: corrected) }

        var results = [LocatedWarning]()
        for claim in claims where !claim.text.isEmpty {
            let quotes = claim.segmentIds.compactMap { byId[$0] }
            let cited = quotes.joined(separator: " ")

            var missing = unsupported(in: claim.text, source: transcript)
            if hasCJK(claim.text) { missing.append("มีตัวอักษรจีนปนมา") }

            // Only facts the transcript really contains can be misplaced; anything
            // else is already reported as missing.
            let misplaced = quotes.isEmpty
                ? []
                : unsupported(in: claim.text, source: cited).filter { !missing.contains($0) }

            guard !missing.isEmpty || !misplaced.isEmpty else { continue }
            results.append(LocatedWarning(claim: claim.text,
                                          missing: missing,
                                          misplaced: misplaced,
                                          segmentIds: claim.segmentIds,
                                          quotes: quotes))
        }
        return results
    }

    /// Digit runs only. Thai numerals spelled as words are left alone because the
    /// summary legitimately renders them as digits.
    private static func numbers(in text: String) -> [String] {
        var found = [String]()
        var current = ""
        for character in text {
            if character.isNumber {
                current.append(character)
            } else if !current.isEmpty {
                found.append(current)
                current = ""
            }
        }
        if !current.isEmpty { found.append(current) }
        return found
    }
}

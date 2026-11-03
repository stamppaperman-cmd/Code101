import Foundation

/// The user's list of names, brands and jargon for a recording. Proper nouns are what
/// ASR gets wrong most and what a cleanup model guesses worst: on one interview the
/// interviewee's own name came back as both `แต่งกวา` and `แปลงกวา`, and `แคมเปญ` as
/// `แคมเป็น`.
///
/// ## Two better-looking approaches were built, measured, and thrown away
///
/// **1. Whisper's `initial_prompt` (`DecodingOptions.promptTokens`).** It works — and it
/// costs more than it returns. Measured 2026-09-07 on the 45-second test meeting with a
/// 48-token list:
///
/// | | without | with |
/// |---|---|---|
/// | `แคมเป็น` → `แคมเปญ` | ✗ | **✓** |
/// | `ไตรมาตร` → `ไตรมาส` | ✗ | **✓** |
/// | segments | 13 | **2** |
/// | text lost | none | **a sentence, cut at `โดยเน`** |
///
/// The prompt is spent out of the same 223-token decode budget as the transcript — the
/// budget whose exhaustion is why this app drops audio at all. Three spellings bought,
/// a sentence and every intermediate timestamp lost.
///
/// **2. Fuzzy substring replacement in the finished text.** Thai is written without
/// spaces, so there is no boundary to anchor to, and every objective tried picked the
/// wrong span. Closest-match prefers a *prefix* of the misspelling — `ไตรมา` is one edit
/// from `ไตรมาส` while `ไตรมาตร` is two — and rewrites the line to `ไตรมาสตร`.
/// Longest-match swallows what follows, turning `ไตรมาสนี้กับ` into `ไตรมาสบ`. Both
/// corrupted correct text, which is the one thing this app must never do.
///
/// ## What it does instead
///
/// The list is handed to `TextCorrector` as context. That pass already fences the model
/// in three ways — dates and numbers masked out of reach, a strict 1:1 line-count check,
/// a per-line digit and length check — and it only ever writes `Segment.corrected`,
/// leaving the raw transcript untouched. Telling a model which words exist in this
/// recording is something it is genuinely good at, and every guard against it going
/// wrong is already built and tested.
enum Vocabulary {
    private static let key = "customVocabulary"

    /// Enough for the people and products in one recording. A longer list dilutes the
    /// instruction rather than strengthening it.
    static let maximumWords = 40

    static var words: [String] {
        get { UserDefaults.standard.stringArray(forKey: key) ?? [] }
        set { UserDefaults.standard.set(clean(newValue), forKey: key) }
    }

    static func clean(_ words: [String]) -> [String] {
        var seen = Set<String>()
        return words
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
            .prefix(maximumWords)
            .map { $0 }
    }

    /// The lines appended to the cleanup prompt, or nil when there is nothing to say.
    /// Phrased as a whitelist of correct spellings rather than as a licence to rewrite,
    /// because the failure mode of this pass has always been doing too much.
    static func promptSection(_ words: [String]) -> String? {
        let cleaned = clean(words)
        guard !cleaned.isEmpty else { return nil }
        return """

        คำเฉพาะที่ปรากฏในไฟล์นี้ สะกดแบบนี้เท่านั้น:
        \(cleaned.joined(separator: ", "))
        ถ้าเจอคำที่ออกเสียงใกล้เคียงกับคำในรายการนี้ ให้แก้ให้ตรงตามรายการ
        ห้ามแก้คำอื่นที่ไม่ได้อยู่ในรายการ และห้ามเพิ่มคำจากรายการเข้าไปเองถ้าไม่มีในต้นฉบับ
        """
    }
}

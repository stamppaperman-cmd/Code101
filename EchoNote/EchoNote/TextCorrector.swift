import Foundation

/// Whisper transcribes Thai phonetically, so it reliably produces plausible-but-wrong
/// spellings (แคมเป็น for แคมเปญ, ไตรมาตร for ไตรมาส). This pass fixes spelling only.
///
/// Asking a model nicely is not enough — measured against real output it fixed the
/// spellings but also turned "ภายในวันสุขนี" (ศุกร์) into "ภายในวันนี้" and dropped the
/// "หน้า" from "วันจันหน้า". Rewriting a date is far worse than leaving it misspelled,
/// so the model is fenced in by three mechanisms instead:
///
///  1. Date, time and number spans are masked to §n§ placeholders before the model
///     sees them, and restored verbatim afterwards — it cannot edit what it can't read.
///  2. Segments go out numbered and must come back numbered 1:1; a batch whose reply
///     doesn't line up is discarded whole.
///  3. Each line is re-checked for digit preservation and plausible length before it
///     is accepted; anything suspicious keeps its raw text.
///
/// The raw transcript is never overwritten, so a bad correction costs nothing.
struct TextCorrector: Sendable {
    var client = OllamaClient()
    var model: String

    private static let batchSize = 30
    /// Ollama serves these in parallel; 3 keeps memory sane next to the ASR model.
    private static let concurrency = 3
    private static let contextWindow = 8_192

    /// Whisper reports an average log probability for every segment and this app used
    /// to discard it. Correcting all 1,092 segments of a 64-minute interview took 15
    /// minutes and put a thousand already-correct lines in front of a model measured
    /// deleting words from them. The lines Whisper was least sure of are where the
    /// spelling errors are; the rest are risk without reward.
    static let doubtfulShare = 0.25

    func correct(segments: [Segment],
                 onStage: @escaping @Sendable (String, Double) -> Void) async throws -> [String] {
        // The deterministic table runs first and always lands, so a cautious or
        // unhelpful model can never cost us a fix we already know is correct.
        var output = segments.map { Self.applyKnownFixes($0.text) }
        guard !segments.isEmpty else { return output }

        let targets = Self.doubtful(segments, share: Self.doubtfulShare)
        guard !targets.isEmpty else { return output }
        log("correct: \(targets.count)/\(segments.count) segments below the confidence cut")

        let batches = stride(from: 0, to: targets.count, by: Self.batchSize).map { start in
            Array(targets[start..<min(start + Self.batchSize, targets.count)])
        }

        let total = batches.count
        let masks = batches.map { batch in batch.map { Self.mask(output[$0]) } }
        let client = client
        let model = model
        // The user's word list rides along with the cleanup prompt rather than into the
        // decoder, where it would cost transcript. See `Vocabulary` for what was tried.
        let prompt = Self.systemPrompt + (Vocabulary.promptSection(Vocabulary.words) ?? "")

        let replies = try await ConcurrentMap.run(
            Array(batches.indices),
            concurrency: Self.concurrency,
            onWaveComplete: { done in
                onStage("กำลังเกลาคำ \(done)/\(total) ช่วง", Double(done) / Double(total))
            }
        ) { _, batchIndex in
            let numbered = masks[batchIndex].enumerated()
                .map { "\($0.offset + 1). \($0.element.text)" }
                .joined(separator: "\n")
            return try await client.chat(model: model,
                                         system: prompt,
                                         user: numbered,
                                         wantsJSON: false,
                                         numCtx: Self.contextWindow,
                                         temperature: 0)
        }

        for (batchIndex, batch) in batches.enumerated() {
            guard let reply = replies[batchIndex],
                  let lines = Self.parse(reply, expecting: batch.count) else { continue }
            for (offset, position) in batch.enumerated() {
                let base = output[position]
                guard let restored = Self.unmask(lines[offset], spans: masks[batchIndex][offset].spans),
                      Self.accept(raw: base, corrected: restored),
                      // Whisper sometimes emits U+FFFD where decoding broke; never
                      // let the cleanup pass launder that into normal-looking text.
                      !restored.contains("\u{FFFD}") else { continue }
                output[position] = restored
            }
        }
        return output
    }

    private static let systemPrompt = """
    คุณคือตัวตรวจแก้คำผิดจากการถอดเสียงภาษาไทย
    ผู้ใช้จะส่งข้อความมาเป็นบรรทัดที่มีเลขกำกับ

    หน้าที่: แก้เฉพาะคำที่สะกดผิดจากการถอดเสียง เช่น "แคมเป็น" เป็น "แคมเปญ"

    กฎเหล็ก ห้ามฝ่าฝืนเด็ดขาด:
    - ตอบกลับเป็นบรรทัดมีเลขกำกับชุดเดิม จำนวนบรรทัดต้องเท่ากับที่ได้รับเป๊ะ
    - สัญลักษณ์รูปแบบ §ตัวเลข§ คือข้อมูลที่ถูกล็อกไว้
      ห้ามแก้ ห้ามลบ ห้ามย้าย ต้องคัดลอกกลับมาเหมือนเดิมทุกตัว
    - ห้ามรวมบรรทัด ห้ามแยกบรรทัด ห้ามเพิ่มบรรทัด ห้ามลบบรรทัด
    - ห้ามเพิ่มคำ ห้ามตัดคำ ห้ามเรียบเรียงประโยคใหม่ ห้ามสรุป
    - บรรทัดที่ถูกอยู่แล้ว ให้คัดลอกกลับมาเหมือนเดิมทุกตัวอักษร
    - ห้ามใส่คำนำหรือคำลงท้ายใดๆ ตอบเฉพาะบรรทัดที่มีเลขกำกับ
    """

    // MARK: - Fencing the model in

    struct Masked {
        let text: String
        let spans: [String]
    }

    /// Anything carrying a date, a time or a number. These are the tokens a reader
    /// cannot verify by eye later, so the model never gets to touch them.
    private static let protectedSpans = try! NSRegularExpression(
        pattern: "\\d+%?|วัน[ก-๙]*|เดือน[ก-๙]*|ปี[ก-๙]*|[ก-๙]*โมง|ทุ่ม|บ่าย|เช้า|เย็น|หน้า|นี้|ที่แล้ว"
    )

    static func mask(_ text: String) -> Masked {
        let full = NSRange(text.startIndex..., in: text)
        let matches = protectedSpans.matches(in: text, range: full)
        guard !matches.isEmpty else { return Masked(text: text, spans: []) }

        var spans = [String]()
        var result = ""
        var cursor = text.startIndex
        for match in matches {
            guard let range = Range(match.range, in: text) else { continue }
            result += text[cursor..<range.lowerBound]
            spans.append(String(text[range]))
            result += "§\(spans.count)§"
            cursor = range.upperBound
        }
        result += text[cursor...]
        return Masked(text: result, spans: spans)
    }

    /// Restores the locked spans, or returns nil when the model lost one — which
    /// means the line can no longer be trusted and the raw text must stand.
    static func unmask(_ text: String, spans: [String]) -> String? {
        var result = text
        for (index, span) in spans.enumerated() {
            let placeholder = "§\(index + 1)§"
            guard result.contains(placeholder) else { return nil }
            result = result.replacingOccurrences(of: placeholder, with: span)
        }
        return result.contains("§") ? nil : result
    }

    /// Segment positions worth sending to the model: the least confident `share` of
    /// those Whisper scored, plus every segment it did not score at all — a transcript
    /// produced before confidence was recorded gets the old all-lines behaviour rather
    /// than a silent downgrade.
    static func doubtful(_ segments: [Segment], share: Double) -> [Int] {
        let scored = segments.indices.filter { segments[$0].confidence != nil }
        guard !scored.isEmpty else { return Array(segments.indices) }

        let unscored = segments.indices.filter { segments[$0].confidence == nil }
        let wanted = min(max(Int((Double(scored.count) * share).rounded()), 1), scored.count)
        let worst = scored
            .sorted { (segments[$0].confidence ?? 0, $0) < (segments[$1].confidence ?? 0, $1) }
            .prefix(wanted)
        return Array(Set(unscored).union(worst)).sorted()
    }

    /// Last line of defence: a spelling fix keeps every digit and stays about the
    /// same length. Anything else is the model paraphrasing.
    static func accept(raw: String, corrected: String) -> Bool {
        guard !corrected.isEmpty else { return false }
        guard raw.filter(\.isNumber) == corrected.filter(\.isNumber) else { return false }
        // A spelling fix barely changes length. The old 0.7 floor let the model
        // quietly delete whole words — it turned "เรียนเป็นเด็กศิลปศาสตร์" into
        // "เรียนเด็กศิลปศาสตร์" and that passed.
        let ratio = Double(corrected.count) / Double(max(raw.count, 1))
        return ratio >= 0.95 && ratio <= 1.15
    }

    /// Substitutions that are always right, applied without asking a model.
    /// Every entry here is a confusion observed in real output; a deterministic
    /// table cannot invent a new error the way a 9B model can.
    private static let knownFixes: [(String, String)] = [
        ("ฟรั่งเศส", "ฝรั่งเศส"),
        ("ฟรั่งเศษ", "ฝรั่งเศส"),
        ("ฝรั่งเศษ", "ฝรั่งเศส"),
        ("แคมเป็น", "แคมเปญ"),
        ("แคมเปน", "แคมเปญ"),
        ("ไตรมาตร", "ไตรมาส"),
        ("ไตรมาศ", "ไตรมาส"),
        ("วันพุทธ", "วันพุธ"),
        ("ครังต่อไป", "ครั้งต่อไป"),
        ("วันจันหน้า", "วันจันทร์หน้า"),
        ("วันสุขนี", "วันศุกร์นี้"),
    ]

    static func applyKnownFixes(_ text: String) -> String {
        var result = text
        for (wrong, right) in knownFixes {
            result = result.replacingOccurrences(of: wrong, with: right)
        }
        return result
    }

    /// Returns the corrected lines in order, or nil when the reply doesn't contain
    /// exactly the indices 1...count — the signal that the model went off-script.
    static func parse(_ reply: String, expecting count: Int) -> [String]? {
        var byIndex = [Int: String]()
        for rawLine in reply.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let dot = line.firstIndex(where: { $0 == "." || $0 == ")" }) else { continue }
            guard let index = Int(line[line.startIndex..<dot]) else { continue }
            let text = line[line.index(after: dot)...].trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            byIndex[index] = text
        }
        guard byIndex.count == count else { return nil }
        var ordered = [String]()
        ordered.reserveCapacity(count)
        for index in 1...count {
            guard let text = byIndex[index] else { return nil }
            ordered.append(text)
        }
        return ordered
    }
}

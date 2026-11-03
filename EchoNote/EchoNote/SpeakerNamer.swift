import Foundation

/// Voices alone can never yield a name — a name only exists in a recording if
/// someone says it. This reads the transcript for introductions and forms of
/// address ("วันนี้มีพี่แจสมิน", "คุณสมชายรับผิดชอบ") and maps them onto the
/// diarized speakers. Everything it returns is a guess and is labelled as one;
/// the user's own rename always wins.
struct SpeakerNamer: Sendable {
    var client = OllamaClient()
    var model: String

    private static let contextWindow = 8_192
    /// Introductions live at the start; a slice from the middle catches names
    /// that only come up later without paying for the whole transcript.
    private static let headCharacters = 4_000
    private static let middleCharacters = 2_000

    struct Guess: Sendable {
        let speakerId: Int
        let name: String
        let evidence: String
    }

    func guessNames(for job: Job, corrected: Bool) async throws -> [Guess] {
        let transcript = job.attributedText(corrected: corrected)
        guard !transcript.isEmpty else { return [] }

        let sample = Self.sample(transcript)
        let reply = try await client.chat(model: model,
                                          system: Self.systemPrompt,
                                          user: sample,
                                          wantsJSON: true,
                                          numCtx: Self.contextWindow,
                                          temperature: 0)
        let raw = Self.decode(reply, knownSpeakers: Set((job.speakers ?? []).map(\.id)))
        let kept = raw.filter { Self.accept($0, segments: job.segments) }
        if kept.count != raw.count {
            let dropped = raw.filter { guess in !kept.contains { $0.speakerId == guess.speakerId } }
            for guess in dropped {
                log("speaker name rejected: ผู้พูด \(guess.speakerId + 1) = \"\(guess.name)\" from \"\(guess.evidence)\"")
            }
        }
        return kept
    }

    /// Measured on a real interview: the interviewer asked "พี่แปลงกวา ตอนนี้อายุเท่าไหร่ครับ"
    /// and the model handed *the interviewer* that name. Addressing someone by name is
    /// evidence about the person being addressed, never about the person speaking, and
    /// no amount of prompt wording made the model reliably tell those apart.
    ///
    /// So the direction is checked here instead. A name taken from a speaker's own line
    /// only stands if that line is an introduction; a name taken from someone else's
    /// line is fine, because that is what being addressed looks like. Evidence that
    /// cannot be found in the transcript at all was invented and is dropped.
    static func accept(_ guess: Guess, segments: [Segment]) -> Bool {
        guard !segments.isEmpty else { return true }
        guard let speaker = speakerSaying(guess.evidence, in: segments) else { return false }
        guard speaker == guess.speakerId else { return true }
        return isSelfIntroduction(guess.evidence)
    }

    /// Which voice said a sentence, by finding it in the transcript it was copied from.
    static func speakerSaying(_ sentence: String, in segments: [Segment]) -> Int? {
        let needle = normalized(sentence)
        guard needle.count >= 6 else { return nil }
        for segment in segments {
            for candidate in [segment.text, segment.corrected].compactMap({ $0 }) {
                let hay = normalized(candidate)
                guard hay.count >= 6 else { continue }
                if hay.contains(needle) || needle.contains(hay) { return segment.speakerId }
            }
        }
        return nil
    }

    private static let introMarkers = ["ชื่อ", "ผมคือ", "ผมชื่อ", "ดิฉันคือ", "ฉันคือ",
                                       "เราคือ", "หนูชื่อ", "เรียกว่า", "แนะนำตัว",
                                       "my name", "i'm ", "i am ", "call me"]

    static func isSelfIntroduction(_ sentence: String) -> Bool {
        let lowered = sentence.lowercased()
        return introMarkers.contains { lowered.contains($0) }
    }

    /// Models re-wrap whitespace when they quote; nothing else about the sentence
    /// should decide whether it matches.
    private static func normalized(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined()
    }

    private static func sample(_ transcript: String) -> String {
        guard transcript.count > headCharacters + middleCharacters else { return transcript }
        let head = String(transcript.prefix(headCharacters))
        let middleStart = transcript.index(transcript.startIndex, offsetBy: transcript.count / 2)
        let middle = String(transcript[middleStart...].prefix(middleCharacters))
        return head + "\n…\n" + middle
    }

    private static let systemPrompt = """
    ผู้ใช้จะส่งข้อความถอดเสียงที่แยกผู้พูดไว้แล้ว เช่น "ผู้พูด 1:" "ผู้พูด 2:"
    หน้าที่ของคุณคือหาว่าผู้พูดแต่ละคนชื่ออะไร โดยดูจากสิ่งที่พูดกันในบทสนทนา

    ตอบเป็น JSON เท่านั้น:
    {"speakers":[{"id":1,"name":"ชื่อที่พบ","evidence":"ประโยคจากต้นฉบับที่ทำให้รู้ชื่อนี้"}]}

    กฎเหล็ก:
    - id คือเลขผู้พูดตามที่ปรากฏในต้นฉบับ เช่น "ผู้พูด 2:" ให้ใช้ id เท่ากับ 2
    - ใส่เฉพาะคนที่มีหลักฐานชัดเจนในบทสนทนา
    - หลักฐานมีสองแบบเท่านั้น และต้องแยกให้ออก:
      (ก) เจ้าตัวแนะนำตัวเอง เช่น ผู้พูด 2 พูดว่า "ผมชื่อสมชาย" → ชื่อนี้เป็นของผู้พูด 2
      (ข) คนอื่นเรียกชื่อเขา เช่น ผู้พูด 1 พูดว่า "คุณสมชายครับ ขอถามหน่อย"
          → ชื่อนี้เป็นของ "ผู้พูด 2" ที่ถูกเรียก ไม่ใช่ของผู้พูด 1 ที่พูดประโยคนั้น
    - ระวังให้มาก: การที่ใครพูดชื่อออกมา ไม่ได้แปลว่านั่นคือชื่อของคนพูด
      คำถามอย่าง "พี่สมชาย ตอนนี้อายุเท่าไหร่" คือคนพูดกำลังเรียกคนอื่น
    - evidence ต้องคัดลอกประโยคจริงจากต้นฉบับ ห้ามแต่งขึ้นเอง
    - ถ้าไม่มีหลักฐานว่าใครชื่ออะไร ให้ตอบ {"speakers":[]}
    - ห้ามเดาชื่อจากน้ำเสียง เพศ หรือความน่าจะเป็น
    """

    private static func decode(_ raw: String, knownSpeakers: Set<Int>) -> [Guess] {
        let text = Summarizer.stripThinking(raw)
        guard let open = text.firstIndex(of: "{"), let close = text.lastIndex(of: "}"), open < close,
              let data = String(text[open...close]).data(using: .utf8) else { return [] }

        struct Payload: Decodable {
            struct Entry: Decodable {
                let id: Int
                let name: String
                let evidence: String?
            }
            let speakers: [Entry]?
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return [] }

        return (payload.speakers ?? []).compactMap { entry in
            // The prompt shows speakers 1-based; profiles are 0-based.
            let identifier = entry.id - 1
            guard knownSpeakers.contains(identifier) else { return nil }
            let name = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            return Guess(speakerId: identifier, name: name, evidence: entry.evidence ?? "")
        }
    }
}

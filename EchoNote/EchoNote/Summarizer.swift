import Foundation

struct OllamaError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Minimal client for the local Ollama daemon. Everything stays on 127.0.0.1 —
/// no API key, no quota, no audio or transcript ever leaves the machine.
struct OllamaClient: Sendable {
    var base = URL(string: "http://127.0.0.1:11434")!

    private var session: URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 600
        config.timeoutIntervalForResource = 3600
        return URLSession(configuration: config)
    }

    func isRunning() async -> Bool {
        (try? await installedModels()) != nil
    }

    func installedModels() async throws -> [String] {
        var request = URLRequest(url: base.appendingPathComponent("api/tags"))
        request.timeoutInterval = 5
        let (data, _) = try await URLSession.shared.data(for: request)
        struct Tags: Decodable {
            struct Model: Decodable { let name: String }
            let models: [Model]
        }
        let tags = try JSONDecoder().decode(Tags.self, from: data)
        return tags.models.map(\.name).sorted()
    }

    /// Embeddings for a batch of strings. Batched on purpose: one round trip per
    /// window would cost more than the arithmetic it enables.
    func embed(model: String, inputs: [String]) async throws -> [[Float]] {
        guard !inputs.isEmpty else { return [] }
        let body: [String: Any] = ["model": model, "input": inputs]

        var request = URLRequest(url: base.appendingPathComponent("api/embed"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw OllamaError(message: String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)")
        }
        struct Reply: Decodable { let embeddings: [[Float]] }
        return try JSONDecoder().decode(Reply.self, from: data).embeddings
    }

    /// One non-streaming chat turn. `think: false` keeps reasoning models from
    /// padding the reply; models that reject the flag are retried without it.
    func chat(model: String, system: String, user: String, wantsJSON: Bool,
              numCtx: Int, temperature: Double = 0) async throws -> String {
        do {
            return try await send(model: model, system: system, user: user, wantsJSON: wantsJSON,
                                  numCtx: numCtx, temperature: temperature, disableThinking: true)
        } catch let error as OllamaError where error.message.localizedCaseInsensitiveContains("think") {
            return try await send(model: model, system: system, user: user, wantsJSON: wantsJSON,
                                  numCtx: numCtx, temperature: temperature, disableThinking: false)
        }
    }

    private func send(model: String, system: String, user: String, wantsJSON: Bool,
                      numCtx: Int, temperature: Double, disableThinking: Bool) async throws -> String {
        var body: [String: Any] = [
            "model": model,
            "stream": false,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
            "options": ["temperature": temperature, "num_ctx": numCtx],
        ]
        if disableThinking { body["think"] = false }
        if wantsJSON { body["format"] = "json" }

        var request = URLRequest(url: base.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let detail = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw OllamaError(message: detail)
        }
        struct Reply: Decodable {
            struct Message: Decodable { let content: String }
            let message: Message
        }
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        return Summarizer.stripThinking(reply.message.content)
    }
}

/// Map-reduce summarization: long transcripts are cut on segment boundaries,
/// each chunk is condensed to notes, then the notes are merged into one JSON summary.
struct Summarizer: Sendable {
    var client = OllamaClient()
    var model: String

    private static let chunkCharacterLimit = 3_500
    private static let contextWindow = 8_192
    private static let concurrency = 3

    func summarize(job: Job, onStage: @escaping @Sendable (String, Double) -> Void) async throws -> Summary {
        // Summarize the cleaned-up text when it exists — fewer garbled words in,
        // fewer invented facts out.
        let useCorrected = job.hasCorrections
        let chunks = Self.chunk(job.segments, corrected: useCorrected)
        guard !chunks.isEmpty else { throw OllamaError(message: "ไม่มีข้อความให้สรุป") }

        var notes: String
        if chunks.count == 1 {
            notes = chunks[0]
        } else {
            let total = chunks.count
            let client = client
            let model = model
            let partials = try await ConcurrentMap.run(
                chunks,
                concurrency: Self.concurrency,
                onWaveComplete: { done in
                    onStage("กำลังสรุป \(done)/\(total) ช่วง", Double(done) / Double(total) * 0.8)
                }
            ) { _, chunk in
                try await client.chat(model: model,
                                      system: Self.mapSystemPrompt,
                                      user: chunk,
                                      wantsJSON: false,
                                      numCtx: Self.contextWindow,
                                      temperature: 0)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            notes = partials.compactMap { $0 }.joined(separator: "\n\n")
        }

        onStage("กำลังเรียบเรียงสรุปรวม", 0.85)
        let json = try await client.chat(model: model,
                                         system: Self.reduceSystemPrompt,
                                         user: notes,
                                         wantsJSON: true,
                                         numCtx: Self.contextWindow,
                                         temperature: 0)

        let payload = try Self.decode(json)
        let validIds = Set(job.segments.map(\.id))
        let bulletClaims = payload.bullets.compactMap { Citations.claim(from: $0, validIds: validIds) }
        let actionClaims = payload.actions.compactMap { Citations.claim(from: $0, validIds: validIds) }
        let headline = Citations.parse(payload.tldr)

        // `bullets` and `actions` keep holding plain sentences. The markers live on
        // the claims beside them, so anything that already reads a summary — the
        // markdown export, the PDF, a previous version of this app — is untouched.
        var summary = Summary(tldr: headline.text,
                              bullets: bulletClaims.map(\.text),
                              actions: actionClaims.map(\.text),
                              keywords: payload.keywords,
                              model: model,
                              createdAt: Date())
        summary.citedBullets = bulletClaims
        summary.citedActions = actionClaims

        let headlineClaim = Claim(text: headline.text,
                                  segmentIds: headline.ids.filter { validIds.contains($0) })
        summary.locatedWarnings = SummaryAudit.located(claims: [headlineClaim] + bulletClaims + actionClaims,
                                                       segments: job.segments,
                                                       corrected: useCorrected)
        summary.warnings = summary.locatedWarnings?.map(\.summary)

        let grounded = Citations.groundedShare(bulletClaims + actionClaims) ?? 0
        log("summary: \(bulletClaims.count) bullets, \(actionClaims.count) actions, "
            + "\(Int(grounded * 100))% cited, \(summary.locatedWarnings?.count ?? 0) warning(s)")

        onStage("สรุปเสร็จ", 1)
        return summary
    }

    // MARK: - Prompts

    private static let mapSystemPrompt = """
    คุณคือผู้ช่วยสรุปบันทึกเสียง ผู้ใช้จะส่งข้อความถอดเสียง "บางช่วง" ของไฟล์ยาวมาให้
    หน้าที่ของคุณคือดึงประเด็นสำคัญออกมาเป็นข้อ ๆ สั้นและกระชับ
    กฎ:
    - ใช้ข้อมูลจากต้นฉบับเท่านั้น ห้ามเดาหรือแต่งเติม
    - ถ้ามีตัวเลข ชื่อคน วันเวลา หรือข้อตกลง ให้คงไว้ให้ครบ
    - ถ้าช่วงนี้มีสิ่งที่ต้องทำต่อ ให้ขึ้นต้นข้อนั้นด้วย "ACTION:"
    - ตอบเป็นภาษาเดียวกับต้นฉบับ ไม่ต้องมีคำนำหรือคำลงท้าย
    - ทุกบรรทัดในต้นฉบับมีเลขกำกับขึ้นต้นด้วย # เช่น "#42 [12:34] ข้อความ"
      ทุกข้อที่คุณเขียน ต้องปิดท้ายด้วยเลขบรรทัดที่ใช้ ในรูปแบบ [#42] หรือ [#42, #43]
      ห้ามเขียนข้อใดโดยไม่มีเลขบรรทัด และห้ามใส่เลขที่ไม่มีในต้นฉบับ
    """

    private static let reduceSystemPrompt = """
    คุณคือผู้ช่วยสรุปบันทึกเสียง ผู้ใช้จะส่งข้อความถอดเสียงหรือโน้ตย่อยมาให้
    ตอบกลับเป็น JSON เท่านั้น ตามโครงสร้างนี้:
    {
      "tldr": "สรุปทั้งหมดใน 1-2 ประโยค",
      "bullets": ["ข้อเท็จจริง ผลลัพธ์ หรือการตัดสินใจ เรียงตามลำดับที่พูด"],
      "actions": ["สิ่งที่ต้องทำต่อ พร้อมผู้รับผิดชอบและกำหนดเวลาถ้ามี"],
      "keywords": ["คำสำคัญ 3-8 คำ"]
    }

    กฎเหล็ก ห้ามฝ่าฝืนเด็ดขาด:
    1. ตัวเลข เปอร์เซ็นต์ วันที่ ชื่อวัน เวลา และชื่อคน ต้องคัดลอกจากต้นฉบับตรงตัว
       ห้ามแปลง ห้ามคำนวณ ห้ามปัดเศษ ห้ามเดา
       ถ้าต้นฉบับเขียน "วันพุธ" ต้องเขียน "วันพุธ" ห้ามเปลี่ยนเป็นวันอื่นเด็ดขาด
    2. ห้ามเติมคำบอกเวลาที่ไม่มีในต้นฉบับ เช่น "วันนี้" "พรุ่งนี้" "สัปดาห์หน้า"
    3. ประโยคใดที่มีคนรับผิดชอบ หรือมีสิ่งที่ต้องส่ง/ต้องทำ/มีกำหนดเวลา
       ให้ใส่ใน actions เท่านั้น ห้ามใส่ซ้ำใน bullets
    4. bullets เก็บเฉพาะข้อเท็จจริง ผลลัพธ์ และการตัดสินใจ
    5. ถ้าไม่แน่ใจว่าต้นฉบับพูดอะไร ให้ตัดข้อนั้นทิ้ง ดีกว่าเดา
    6. ถ้าไม่มีสิ่งที่ต้องทำต่อ ให้ actions เป็น []
    7. ค่าทุกตัวต้องเป็นภาษาเดียวกับต้นฉบับ
    8. ต้นฉบับที่ได้รับมีเลขบรรทัดกำกับ อาจอยู่ต้นบรรทัดในรูปแบบ "#42 [12:34] ข้อความ"
       หรืออยู่ท้ายข้อในรูปแบบ [#42] หรือ [#42, #43]
       ทุกข้อความใน tldr, bullets และ actions ต้อง "ปิดท้าย" ด้วยเลขบรรทัดที่ใช้
       ในรูปแบบ [#42] หรือ [#42, #43] เท่านั้น เช่น
       "ยอดขายเพิ่มขึ้น 8% [#2, #3]"
       ให้คัดลอกเลขมาตรง ๆ ห้ามคิดเลขใหม่ ห้ามเดา
       ถ้ารวมหลายบรรทัดเป็นข้อเดียว ให้ใส่เลขของทุกบรรทัดที่ใช้
       ข้อที่หาเลขบรรทัดไม่ได้ ให้ตัดทิ้ง ดีกว่าเขียนโดยไม่มีที่มา
    """

    // MARK: - Helpers

    /// Splits on segment boundaries so a chunk never cuts mid-sentence.
    static func chunk(_ segments: [Segment], corrected: Bool = false) -> [String] {
        var chunks = [String]()
        var current = ""
        for segment in segments {
            let line = "#\(segment.id) [\(segment.startLabel)] \(segment.display(corrected: corrected))"
            if !current.isEmpty, current.count + line.count > chunkCharacterLimit {
                chunks.append(current)
                current = line
            } else {
                current += current.isEmpty ? line : "\n" + line
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    static func stripThinking(_ text: String) -> String {
        guard let start = text.range(of: "<think>"), let end = text.range(of: "</think>") else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var stripped = text
        stripped.removeSubrange(start.lowerBound..<end.upperBound)
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct Payload: Decodable {
        var tldr: String = ""
        var bullets: [String] = []
        var actions: [String] = []
        var keywords: [String] = []

        enum CodingKeys: String, CodingKey { case tldr, bullets, actions, keywords }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            tldr = (try? container.decode(String.self, forKey: .tldr)) ?? ""
            bullets = (try? container.decode([String].self, forKey: .bullets)) ?? []
            actions = (try? container.decode([String].self, forKey: .actions)) ?? []
            keywords = (try? container.decode([String].self, forKey: .keywords)) ?? []
        }
    }

    /// Models occasionally wrap JSON in prose; take the outermost braces.
    private static func decode(_ raw: String) throws -> Payload {
        let text = stripThinking(raw)
        let candidate: String
        if let open = text.firstIndex(of: "{"), let close = text.lastIndex(of: "}"), open < close {
            candidate = String(text[open...close])
        } else {
            candidate = text
        }
        guard let data = candidate.data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              !payload.tldr.isEmpty || !payload.bullets.isEmpty else {
            throw OllamaError(message: "สรุปไม่สำเร็จ โมเดลตอบผิดรูปแบบ — กดสรุปใหม่ หรือเปลี่ยนโมเดลสรุป")
        }
        return payload
    }
}

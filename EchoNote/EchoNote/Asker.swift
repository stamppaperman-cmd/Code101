import Foundation

/// An answer that carries its evidence. `refused` is a first-class outcome, not a
/// failure: "this recording does not say" is the correct answer far more often than
/// a fluent paragraph is, and a model that cannot say it will invent one instead.
struct GroundedAnswer: Codable, Hashable, Identifiable {
    var id = UUID()
    var question: String
    var text: String
    /// The answer split into statements, each with the transcript lines behind it.
    var claims: [Claim]
    /// Everything retrieval put in front of the model, whether it was used or not —
    /// so "it missed the obvious part" and "it made something up" stay tellable apart.
    var consulted: [Int]
    var refused: Bool
    var askedAt = Date()
    /// Which model answered — and therefore whether this answer cost the recording's
    /// privacy. Recorded on the answer so it stays visible after the fact.
    var backend: AnswerBackend = .local

    var isGrounded: Bool { !refused && claims.contains(where: \.isGrounded) }
}

/// Which model answers. Local is the default and the only one that keeps the recording
/// on this machine; the hosted option exists because it can hold the whole transcript at
/// once where the local model holds eight retrieved windows.
enum AnswerBackend: String, Codable, CaseIterable, Identifiable {
    case local, gemini

    var id: String { rawValue }

    var label: String {
        switch self {
        case .local: return "ในเครื่อง"
        case .gemini: return "Gemini (ฟรี)"
        }
    }

    /// True when choosing this sends the transcript off the machine. Every place that
    /// offers the choice has to say so.
    var sendsDataOut: Bool { self != .local }

    var detail: String {
        switch self {
        case .local:
            return "ตอบด้วยโมเดลในเครื่องผ่าน Ollama ข้อมูลไม่ออกจากเครื่อง เห็นเฉพาะช่วงที่ค้นเจอ"
        case .gemini:
            return "ส่งสรุปและข้อความถอดเสียงทั้งไฟล์ไปที่ Google เพื่อให้ตอบได้ครอบคลุมทั้งบทสนทนา — ข้อมูลออกจากเครื่อง"
        }
    }
}

/// Asks a question of one recording and refuses to look anywhere else.
///
/// The model is handed a few retrieved moments and nothing more. It cannot draw on
/// the rest of the transcript because it never sees it, and it cannot draw on its own
/// training because every sentence it writes has to name the line it came from — a
/// sentence with no line is dropped before the answer is shown.
struct Asker: Sendable {
    var client = OllamaClient()
    var model: String

    static let topK = 8
    private static let contextWindow = 8_192
    /// Below this the question is about something the recording never touches.
    ///
    /// Calibrated against lexical similarity, where a question sharing no character
    /// trigrams with the transcript scores exactly zero. The previous value was set
    /// against embedding cosine, which on Thai returned the same number for a relevant
    /// and an irrelevant question alike — a floor that could never fire.
    static let relevanceFloor: Float = 0.02
    static let refusal = "ไม่พบคำตอบในไฟล์นี้"

    /// The local path: retrieve a few moments, show the model those and nothing else.
    func answer(_ question: String,
                index: RetrievalIndex,
                segments: [Segment]) async throws -> GroundedAnswer {
        let trimmed = try Self.validate(question)

        let retriever = Retriever(client: client, model: index.model)
        let hits = try await retriever.search(trimmed, in: index, topK: Self.topK)

        guard let best = hits.first, best.score >= Self.relevanceFloor else {
            log("ask: \"\(trimmed)\" — best score \(hits.first?.score ?? 0), below floor; refused without asking the model")
            return GroundedAnswer(question: trimmed,
                                  text: Self.refusal,
                                  claims: [],
                                  consulted: hits.flatMap(\.window.segmentIds),
                                  refused: true,
                                  backend: .local)
        }

        let cited = Set(hits.flatMap(\.window.segmentIds))
        let context = segments
            .filter { cited.contains($0.id) }
            .sorted { $0.startMS < $1.startMS }
            .map { "#\($0.id) [\($0.startLabel)] \($0.display(corrected: index.corrected))" }
            .joined(separator: "\n")

        let reply = try await client.chat(model: model,
                                          system: Self.systemPrompt,
                                          user: "คำถาม: \(trimmed)\n\nข้อความจากไฟล์:\n\(context)",
                                          wantsJSON: false,
                                          numCtx: Self.contextWindow,
                                          temperature: 0)

        log("ask (local): \"\(trimmed)\" top score \(String(format: "%.3f", best.score))")
        return Self.assemble(question: trimmed, reply: reply, validIds: cited, backend: .local)
    }

    /// The hosted path. A million-token context means retrieval is not needed: the
    /// summary and the whole numbered transcript go in together, which is the one thing
    /// the local 8k model cannot do — a question whose answer is spread across the hour
    /// rather than sitting in one window.
    ///
    /// The citation rule does not relax because the model got bigger. Every sentence
    /// still has to name a line, and one that cannot is still dropped.
    static func answerExternally(_ question: String,
                                 segments: [Segment],
                                 corrected: Bool,
                                 client: GeminiClient) async throws -> GroundedAnswer {
        let trimmed = try validate(question)
        guard !segments.isEmpty else { throw OllamaError(message: "ยังไม่มีข้อความถอดเสียง") }

        // Raw transcript only — no summary. The summary is a 9B model's output, and
        // sending it alongside the transcript invites a second model to repeat the
        // first one's mistakes with more confidence. The transcript is the only thing
        // here that came from the recording.
        let context = "ข้อความถอดเสียงทั้งไฟล์:\n"
            + Citations.numbered(segments, corrected: corrected).joined(separator: "\n")

        log("ask (gemini): \"\(trimmed)\" sending \(segments.count) segments, \(context.count) chars")
        let reply = try await client.chat(system: systemPrompt,
                                          user: "คำถาม: \(trimmed)\n\n\(context)")
        return assemble(question: trimmed,
                        reply: reply,
                        validIds: Set(segments.map(\.id)),
                        backend: .gemini)
    }

    private static func validate(_ question: String) throws -> String {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw OllamaError(message: "ยังไม่ได้พิมพ์คำถาม") }
        return trimmed
    }

    /// Shared by both backends: split the reply into statements, keep only the ones that
    /// name a real line, and treat "nothing survived" as a refusal rather than as an
    /// answer with the evidence quietly removed.
    private static func assemble(question: String,
                                 reply: String,
                                 validIds: Set<Int>,
                                 backend: AnswerBackend) -> GroundedAnswer {
        let consulted = validIds.sorted()
        let body = Summarizer.stripThinking(reply).trimmingCharacters(in: .whitespacesAndNewlines)
        if body.isEmpty || body.contains(refusal) {
            return GroundedAnswer(question: question, text: refusal, claims: [],
                                  consulted: consulted, refused: true, backend: backend)
        }

        let claims = body
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .compactMap { Citations.claim(from: $0, validIds: validIds) }

        let grounded = claims.filter(\.isGrounded)
        guard !grounded.isEmpty else {
            log("ask: answered with no usable citation; refused")
            return GroundedAnswer(question: question, text: refusal, claims: [],
                                  consulted: consulted, refused: true, backend: backend)
        }

        log("ask: \(grounded.count)/\(claims.count) statements cited")
        return GroundedAnswer(question: question,
                              text: grounded.map(\.text).joined(separator: "\n"),
                              claims: grounded,
                              consulted: consulted,
                              refused: false,
                              backend: backend)
    }

    private static let systemPrompt = """
    คุณคือผู้ช่วยตอบคำถามจากบันทึกเสียง ผู้ใช้จะส่งคำถามและข้อความบางส่วนจากไฟล์มาให้
    ทุกบรรทัดมีเลขกำกับขึ้นต้นด้วย # เช่น "#42 [12:34] ข้อความ"

    กฎเหล็ก ห้ามฝ่าฝืนเด็ดขาด:
    1. ตอบจากข้อความที่ให้มาเท่านั้น ห้ามใช้ความรู้อื่นนอกเหนือจากนี้
    2. ทุกประโยคที่ตอบ ต้องปิดท้ายด้วยเลขบรรทัดที่ใช้ เช่น [#42] หรือ [#42, #43]
       ประโยคที่ไม่มีเลขบรรทัด จะถูกทิ้งทั้งประโยค
    3. ถ้าข้อความที่ให้มาไม่มีคำตอบ ให้ตอบเพียงว่า "ไม่พบคำตอบในไฟล์นี้"
       ห้ามเดา ห้ามอนุมาน ห้ามตอบแบบกว้าง ๆ เพื่อให้ดูเหมือนมีคำตอบ
    4. ตัวเลข วันที่ เวลา และชื่อคน ต้องคัดลอกจากต้นฉบับตรงตัว
    5. ตอบเป็นภาษาเดียวกับคำถาม สั้นและตรง หนึ่งประเด็นต่อหนึ่งบรรทัด
    6. ไม่ต้องมีคำนำ ไม่ต้องมีคำลงท้าย ไม่ต้องสรุปซ้ำ
    """
}

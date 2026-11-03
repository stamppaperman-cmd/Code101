import Foundation

/// Google's free Gemini tier, as an *opt-in* alternative to the local model.
///
/// Everything else in this app runs on 127.0.0.1 and that remains the default. This
/// path is different in kind, not degree: the transcript leaves the machine. It is
/// here because a hosted model has a million-token context where the local one has
/// 8,192 — it can be handed the entire recording and the summary at once instead of
/// eight retrieved windows — and because the free tier costs nothing. The caller is
/// responsible for making sure the user chose it.
struct GeminiClient: Sendable {
    /// Model ids move; this is a starting point the user can change in settings.
    static let defaultModel = "gemini-2.0-flash"

    var model: String = defaultModel
    var apiKey: String

    private var session: URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 180
        return URLSession(configuration: config)
    }

    func chat(system: String, user: String, temperature: Double = 0) async throws -> String {
        guard !apiKey.isEmpty else {
            throw OllamaError(message: "ยังไม่ได้ใส่ API key ของ Gemini")
        }

        let body: [String: Any] = [
            "system_instruction": ["parts": [["text": system]]],
            "contents": [["role": "user", "parts": [["text": user]]]],
            "generationConfig": ["temperature": temperature],
        ]

        var request = URLRequest(
            url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Header, not a query parameter — a key in a URL ends up in logs and history.
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw OllamaError(message: Self.readableError(data, status: http.statusCode, model: model))
        }

        struct Reply: Decodable {
            struct Candidate: Decodable {
                struct Content: Decodable {
                    struct Part: Decodable { let text: String? }
                    let parts: [Part]?
                }
                let content: Content?
                let finishReason: String?
            }
            let candidates: [Candidate]?
        }
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        let text = (reply.candidates?.first?.content?.parts ?? [])
            .compactMap(\.text)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw OllamaError(message: "Gemini ไม่ได้ตอบอะไรกลับมา (finishReason: \(reply.candidates?.first?.finishReason ?? "?"))")
        }
        return text
    }

    /// Google's errors carry a usable message; surfacing the raw JSON helps nobody.
    private static func readableError(_ data: Data, status: Int, model: String) -> String {
        struct Failure: Decodable {
            struct Detail: Decodable { let message: String? }
            let error: Detail?
        }
        let message = (try? JSONDecoder().decode(Failure.self, from: data))?.error?.message
        switch status {
        case 400 where message?.contains("API key") == true, 401, 403:
            return "Gemini ปฏิเสธ API key — ตรวจว่าคีย์ถูกต้องและเปิดใช้ Generative Language API แล้ว"
        case 429:
            return "โควตาฟรีของ Gemini เต็มสำหรับตอนนี้ — รอสักครู่ หรือกลับไปใช้โมเดลในเครื่อง"
        case 404:
            return "ไม่พบโมเดล \"\(model)\" — ชื่อโมเดลอาจเปลี่ยนไปแล้ว ลองแก้ในตั้งค่า"
        default:
            return message ?? "Gemini ตอบกลับด้วยรหัส \(status)"
        }
    }
}

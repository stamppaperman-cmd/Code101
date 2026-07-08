import Foundation

/// Free Google Translate web endpoint (no API key required). Used as the
/// primary translator when online; Apple's on-device Translation framework
/// is the fallback.
enum OnlineTranslator {
    enum OnlineTranslationError: LocalizedError {
        case badResponse

        var errorDescription: String? {
            "The online translation service returned an unexpected response."
        }
    }

    static func translate(_ text: String, source: String, target: String) async throws -> String {
        var components = URLComponents(string: "https://translate.googleapis.com/translate_a/single")!
        components.queryItems = [
            URLQueryItem(name: "client", value: "gtx"),
            URLQueryItem(name: "sl", value: source),
            URLQueryItem(name: "tl", value: target),
            URLQueryItem(name: "dt", value: "t"),
            URLQueryItem(name: "q", value: String(text.prefix(3000))),
        ]
        guard let url = components.url else {
            throw OnlineTranslationError.badResponse
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 8

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw OnlineTranslationError.badResponse
        }

        // Response shape: [[["<translated>","<original>",...], ...], ...]
        guard let root = try JSONSerialization.jsonObject(with: data) as? [Any],
              let segments = root.first as? [Any] else {
            throw OnlineTranslationError.badResponse
        }
        let pieces = segments.compactMap { ($0 as? [Any])?.first as? String }
        guard !pieces.isEmpty else {
            throw OnlineTranslationError.badResponse
        }
        return pieces.joined()
    }
}

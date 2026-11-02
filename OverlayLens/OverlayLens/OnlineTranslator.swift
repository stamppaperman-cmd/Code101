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

    /// The gtx endpoint gets rate-limited (HTTP 429) after heavy use; when it
    /// does, the Chrome-extension endpoint usually still answers.
    static func translate(_ text: String, source: String, target: String) async throws -> String {
        // While gtx is blocked, go straight to the backup instead of paying
        // for a failed round trip on every translation.
        if Date() >= gtxBlockedUntil {
            do {
                return try await translateGtx(text, source: source, target: target)
            } catch {
                gtxBlockedUntil = Date().addingTimeInterval(15 * 60)
            }
        }
        return try await translateDictExtension(text, source: source, target: target)
    }

    nonisolated(unsafe) private static var gtxBlockedUntil = Date.distantPast

    /// Response shape: ["<translated>"] (or [["<translated>","<lang>"]] for sl=auto).
    private static func translateDictExtension(_ text: String, source: String, target: String) async throws -> String {
        var components = URLComponents(string: "https://clients5.google.com/translate_a/t")!
        components.queryItems = [
            URLQueryItem(name: "client", value: "dict-chrome-ex"),
            URLQueryItem(name: "sl", value: source),
            URLQueryItem(name: "tl", value: target),
            URLQueryItem(name: "q", value: String(text.prefix(3000))),
        ]
        guard let url = components.url else { throw OnlineTranslationError.badResponse }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw OnlineTranslationError.badResponse
        }
        return try parseDictExtension(data)
    }

    static func parseDictExtension(_ data: Data) throws -> String {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [Any] else {
            throw OnlineTranslationError.badResponse
        }
        let pieces = root.compactMap { ($0 as? String) ?? (($0 as? [Any])?.first as? String) }
        guard !pieces.isEmpty else { throw OnlineTranslationError.badResponse }
        return pieces.joined()
    }

    private static func translateGtx(_ text: String, source: String, target: String) async throws -> String {
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
        return try parseGtx(data)
    }

    static func parseGtx(_ data: Data) throws -> String {
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

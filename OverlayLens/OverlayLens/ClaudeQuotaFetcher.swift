import Foundation
import Security
import os

/// Real usage percentages from Anthropic's OAuth usage endpoint — the same
/// numbers the claude.ai "Usage" settings page shows. Uses the OAuth access
/// token Claude Code already stores on this Mac (credentials file, or its
/// keychain item — the first keychain read pops a one-time Allow dialog).
/// Returns nil when no token is available or the request fails, so callers
/// can fall back to the local-transcript estimate.
struct ClaudeQuota {
    struct Window {
        /// 0–100, percent of the limit used.
        var utilization: Double
        var resetsAt: Date?
    }

    /// 5-hour window — "Current session" on the claude.ai usage page.
    var session: Window?
    /// Weekly windows: "" = all models, otherwise the per-model name
    /// ("fable", "opus", …) as the API reports it.
    var weekly: [(name: String, window: Window)] = []
}

enum ClaudeQuotaFetcher {
    /// Never logs the token itself — only which step failed, so quota
    /// problems are debuggable via `log show`.
    private static let log = Logger(subsystem: "com.stamp.OverlayLens", category: "quota")

    static func fetch() async -> ClaudeQuota? {
        // Preferred source: the rate_limits JSON Claude Code pipes into the
        // user's statusline script, which caches it to disk for us. Free,
        // fresh while any Claude Code session is active, and never 429s.
        if let cached = localCache() {
            log.notice("quota: using statusline cache")
            return cached
        }

        guard let token = accessToken() else {
            log.error("quota: no access token (file + keychain both failed)")
            return nil
        }
        guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        guard let (data, response) = try? await URLSession.shared.data(for: request) else {
            log.error("quota: request failed (network)")
            return nil
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else {
            let body = String(data: data.prefix(300), encoding: .utf8) ?? "?"
            log.error("quota: HTTP \(status): \(body, privacy: .public)")
            return nil
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            log.error("quota: response is not a JSON object")
            return nil
        }
        log.notice("quota: HTTP 200, keys = \(json.keys.sorted().joined(separator: ","), privacy: .public)")

        guard let quota = parse(json) else {
            log.error("quota: parsed nothing usable from response")
            return nil
        }
        let summary = "session \(quota.session?.utilization ?? -1)%, weekly " +
            quota.weekly.map { "\($0.name.isEmpty ? "all" : $0.name)=\($0.window.utilization)%" }
                .joined(separator: " ")
        log.notice("quota: parsed \(summary, privacy: .public)")
        return quota
    }

    /// Cache-only read: never touches the keychain or the network, so it is
    /// safe to call from the ambient screen without a surprise permission prompt.
    static func cachedOnly() -> ClaudeQuota? { localCache() }

    /// `~/.claude/rate_limits_cache.json`, written by statusline.sh from the
    /// JSON Claude Code feeds it. Considered fresh for 15 minutes.
    private static func localCache() -> ClaudeQuota? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/rate_limits_cache.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cachedAt = (json["cached_at"] as? NSNumber)?.doubleValue,
              Date().timeIntervalSince(Date(timeIntervalSince1970: cachedAt)) < 15 * 60,
              let limits = json["rate_limits"] as? [String: Any]
        else { return nil }
        return parse(limits)
    }

    private static func parse(_ json: [String: Any]) -> ClaudeQuota? {
        var quota = ClaudeQuota()
        for (key, value) in json {
            guard let dict = value as? [String: Any],
                  let window = parseWindow(dict)
            else { continue }
            if key == "five_hour" {
                quota.session = window
            } else if key == "seven_day" {
                quota.weekly.append((name: "", window: window))
            } else if key.hasPrefix("seven_day_") {
                quota.weekly.append((
                    name: String(key.dropFirst("seven_day_".count)),
                    window: window
                ))
            }
        }
        // All-models row first, then per-model alphabetically.
        quota.weekly.sort { ($0.name.isEmpty ? "" : $0.name) < ($1.name.isEmpty ? "" : $1.name) }

        guard quota.session != nil || !quota.weekly.isEmpty else { return nil }
        return quota
    }

    private static func parseWindow(_ dict: [String: Any]) -> ClaudeQuota.Window? {
        // API says "utilization"; the statusline JSON says "used_percentage".
        guard let raw = (dict["utilization"] ?? dict["used_percentage"]) as? NSNumber else {
            return nil
        }
        let utilization = raw.doubleValue

        var resetsAt: Date?
        if let stamp = dict["resets_at"] as? String {
            let withFractional = ISO8601DateFormatter()
            withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            resetsAt = withFractional.date(from: stamp) ?? ISO8601DateFormatter().date(from: stamp)
        } else if let epoch = dict["resets_at"] as? NSNumber {
            resetsAt = Date(timeIntervalSince1970: epoch.doubleValue)
        }
        return ClaudeQuota.Window(utilization: min(100, max(0, utilization)), resetsAt: resetsAt)
    }

    // MARK: - Token lookup

    private static func accessToken() -> String? {
        // Older installs keep a plain credentials file.
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
        if let data = try? Data(contentsOf: file), let token = parseToken(data) {
            return token
        }

        // Current installs use the login keychain (item owned by Claude Code;
        // macOS asks the user to allow OverlayLens the first time).
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            log.error("quota: keychain read failed, OSStatus \(status)")
            return nil
        }
        let token = parseToken(data)
        if token == nil { log.error("quota: keychain item found but token missing in JSON") }
        return token
    }

    private static func parseToken(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty
        else { return nil }
        return token
    }
}

import AppKit
import Foundation

/// One app or service Claude can talk to (a claude.ai connector, a locally
/// configured MCP server, or a plugin server that still needs sign-in).
struct ClaudeConnector: Identifiable, Equatable {
    enum Status {
        /// Used by a Claude session within the last few minutes.
        case activeNow
        /// Configured and available, but not touched recently.
        case connected
        /// Declared, but Claude recorded that it needs authorization.
        case needsAuth
    }

    enum Source {
        /// claude.ai connector attached to a Claude app / Claude Code session.
        case connector
        /// MCP server from a local config file (~/.claude.json, desktop config).
        case local
        /// MCP server shipped by a plugin.
        case plugin
    }

    let id: String
    let name: String
    let status: Status
    let source: Source
    let toolCount: Int
    let enabledToolCount: Int
    let lastUsed: Date?
    /// Where it came from: session title, plugin name, or config file.
    let context: String?
}

struct ClaudeConnectionsSnapshot: Equatable {
    /// Connectors and local servers that are wired up, newest use first.
    var connected: [ClaudeConnector] = []
    /// Servers Claude recorded as needing sign-in.
    var pending: [ClaudeConnector] = []
    /// The Claude desktop app is running right now.
    var isClaudeAppRunning = false
    /// Title of the session that most recently used a connector.
    var activeSessionTitle: String?
    var lastActivity: Date?

    var isEmpty: Bool { connected.isEmpty && pending.isEmpty }
}

/// Reads Claude's own on-disk state to work out which apps it is wired to.
///
/// There is no API for this, so the picture is assembled from four files
/// Claude maintains itself:
///   * `~/Library/Application Support/Claude/{local-agent-mode-sessions,
///     claude-code-sessions}/…/local_*.json` — each session records its
///     `remoteMcpServersConfig` (uuid + display name + full tool list) and
///     `enabledMcpTools`; this is the only place connector *names* appear.
///   * `~/.claude.json` — locally configured `mcpServers`, plus
///     `claudeAiMcpEverConnected` as a fallback when no session file has run.
///   * `~/Library/Application Support/Claude/claude_desktop_config.json` —
///     desktop app MCP servers.
///   * `~/.claude/mcp-needs-auth-cache.json` — servers awaiting sign-in.
///
/// Session files are up to ~0.5 MB each (they embed every tool schema), so
/// results are cached per file and only re-parsed when the modification date
/// changes — in the steady state that's one file, the live session.
final class ClaudeConnectionsScanner {
    /// Recent enough that the connector counts as in use right now.
    private static let activeWindow: TimeInterval = 5 * 60
    /// Session files older than this are ignored — a connector list from two
    /// months ago says nothing about what is wired up today.
    private static let staleAfter: TimeInterval = 30 * 24 * 60 * 60
    /// Newest session files parsed per directory.
    private static let sessionFileLimit = 10

    private struct SessionInfo {
        let lastActivity: Date
        let title: String?
        let servers: [(uuid: String, name: String, toolCount: Int)]
        let enabledPerServer: [String: Int]
    }

    private var sessionCache: [String: (mtime: Date, info: SessionInfo?)] = [:]
    private var configCache: [String: (mtime: Date, json: [String: Any]?)] = [:]

    private let home = FileManager.default.homeDirectoryForCurrentUser

    // MARK: - Scan

    func scan(isClaudeAppRunning: Bool) -> ClaudeConnectionsSnapshot {
        var snapshot = ClaudeConnectionsSnapshot()
        snapshot.isClaudeAppRunning = isClaudeAppRunning

        var connected = scanSessions(into: &snapshot)
        connected.append(contentsOf: scanLocalServers())
        if connected.isEmpty {
            connected = everConnectedFallback()
        }

        // Most recently used first; connectors from the same session all share
        // one timestamp, so name breaks the tie — otherwise the rows would
        // reshuffle on every refresh.
        snapshot.connected = connected.sorted {
            switch ($0.lastUsed, $1.lastUsed) {
            case let (a?, b?): return a == b ? $0.name < $1.name : a > b
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return $0.name < $1.name
            }
        }
        // The same service can be declared by several plugins (two Figma
        // servers) and can also be a connector that is already wired up —
        // listing it again under "needs sign-in" just reads as a mistake.
        let connectedNames = Set(snapshot.connected.map { $0.name.lowercased() })
        var seen = Set<String>()
        snapshot.pending = scanNeedsAuth().filter { connector in
            let key = connector.name.lowercased()
            guard !connectedNames.contains(key) else { return false }
            return seen.insert(key).inserted
        }
        return snapshot
    }

    // MARK: - claude.ai connectors (session files)

    private func scanSessions(into snapshot: inout ClaudeConnectionsSnapshot) -> [ClaudeConnector] {
        let root = home
            .appendingPathComponent("Library/Application Support/Claude")
        let dirs = ["local-agent-mode-sessions", "claude-code-sessions"]
            .map { root.appendingPathComponent($0) }

        var infos: [SessionInfo] = []
        for dir in dirs {
            for url in newestSessionFiles(in: dir) {
                if let info = sessionInfo(at: url) { infos.append(info) }
            }
        }
        guard !infos.isEmpty else { return [] }

        infos.sort { $0.lastActivity > $1.lastActivity }
        snapshot.activeSessionTitle = infos.first?.title
        snapshot.lastActivity = infos.first?.lastActivity

        // A connector may appear in several sessions; keep the most recent
        // sighting, which is also the one whose tool list is current.
        var byUUID: [String: ClaudeConnector] = [:]
        for info in infos {
            for server in info.servers where byUUID[server.uuid] == nil {
                let age = Date().timeIntervalSince(info.lastActivity)
                byUUID[server.uuid] = ClaudeConnector(
                    id: server.uuid,
                    name: server.name,
                    status: age <= Self.activeWindow ? .activeNow : .connected,
                    source: .connector,
                    toolCount: server.toolCount,
                    enabledToolCount: info.enabledPerServer[server.uuid] ?? 0,
                    lastUsed: info.lastActivity,
                    context: info.title
                )
            }
        }
        return Array(byUUID.values)
    }

    /// The newest session files in a directory, ignoring the sidecar files
    /// (`spaces.json`, caches) that share the folder.
    private func newestSessionFiles(in dir: URL) -> [URL] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var candidates: [(URL, Date)] = []
        let cutoff = Date().addingTimeInterval(-Self.staleAfter)
        for case let url as URL in walker {
            guard url.lastPathComponent.hasPrefix("local_"),
                  url.pathExtension == "json",
                  let values = try? url.resourceValues(
                      forKeys: [.contentModificationDateKey, .isRegularFileKey]
                  ),
                  values.isRegularFile == true,
                  let mtime = values.contentModificationDate,
                  mtime > cutoff
            else { continue }
            candidates.append((url, mtime))
        }
        return candidates
            .sorted { $0.1 > $1.1 }
            .prefix(Self.sessionFileLimit)
            .map(\.0)
    }

    private func sessionInfo(at url: URL) -> SessionInfo? {
        guard let mtime = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate
        else { return nil }

        if let cached = sessionCache[url.path], cached.mtime == mtime {
            return cached.info
        }

        let info = parseSession(at: url)
        sessionCache[url.path] = (mtime, info)
        return info
    }

    private func parseSession(at url: URL) -> SessionInfo? {
        guard let json = readJSON(at: url),
              let servers = json["remoteMcpServersConfig"] as? [[String: Any]],
              !servers.isEmpty
        else { return nil }

        let parsed: [(uuid: String, name: String, toolCount: Int)] = servers.compactMap {
            guard let uuid = $0["uuid"] as? String, let name = $0["name"] as? String
            else { return nil }
            return (uuid, name, ($0["tools"] as? [Any])?.count ?? 0)
        }
        guard !parsed.isEmpty else { return nil }

        // enabledMcpTools keys look like "<server-uuid>:<tool-name>".
        var enabled: [String: Int] = [:]
        if let tools = json["enabledMcpTools"] as? [String: Any] {
            for (key, value) in tools where (value as? Bool) == true {
                guard let separator = key.firstIndex(of: ":") else { continue }
                enabled[String(key[key.startIndex..<separator]), default: 0] += 1
            }
        }

        let millis = (json["lastActivityAt"] as? Double)
            ?? (json["createdAt"] as? Double)
            ?? 0
        let lastActivity = millis > 0
            ? Date(timeIntervalSince1970: millis / 1000)
            : ((try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? Date.distantPast)

        let title = (json["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return SessionInfo(
            lastActivity: lastActivity,
            title: title,
            servers: parsed,
            enabledPerServer: enabled
        )
    }

    // MARK: - Locally configured MCP servers

    private func scanLocalServers() -> [ClaudeConnector] {
        var result: [ClaudeConnector] = []

        let claudeJSON = home.appendingPathComponent(".claude.json")
        if let json = cachedJSON(at: claudeJSON) {
            result.append(contentsOf: localServers(
                in: json["mcpServers"], context: "~/.claude.json"
            ))
            // Per-project servers: projects → <path> → mcpServers.
            if let projects = json["projects"] as? [String: Any] {
                for (path, value) in projects {
                    guard let project = value as? [String: Any] else { continue }
                    result.append(contentsOf: localServers(
                        in: project["mcpServers"],
                        context: (path as NSString).lastPathComponent
                    ))
                }
            }
        }

        let desktopConfig = home.appendingPathComponent(
            "Library/Application Support/Claude/claude_desktop_config.json"
        )
        if let json = cachedJSON(at: desktopConfig) {
            result.append(contentsOf: localServers(
                in: json["mcpServers"], context: "Claude Desktop"
            ))
        }
        return result
    }

    private func localServers(in value: Any?, context: String) -> [ClaudeConnector] {
        guard let servers = value as? [String: Any] else { return [] }
        return servers.keys.sorted().map { key in
            ClaudeConnector(
                id: "local:\(context):\(key)",
                name: Self.displayName(forServerKey: key),
                status: .connected,
                source: .local,
                toolCount: 0,
                enabledToolCount: 0,
                lastUsed: nil,
                context: context
            )
        }
    }

    /// Connector names Claude remembers having connected, used only when no
    /// session file is available to give the live picture.
    private func everConnectedFallback() -> [ClaudeConnector] {
        guard let json = cachedJSON(at: home.appendingPathComponent(".claude.json")),
              let names = json["claudeAiMcpEverConnected"] as? [String]
        else { return [] }
        return names.map { raw in
            let name = raw.replacingOccurrences(of: "claude.ai ", with: "")
            return ClaudeConnector(
                id: "ever:\(raw)",
                name: name,
                status: .connected,
                source: .connector,
                toolCount: 0,
                enabledToolCount: 0,
                lastUsed: nil,
                context: "claude.ai"
            )
        }
    }

    // MARK: - Servers waiting for sign-in

    private func scanNeedsAuth() -> [ClaudeConnector] {
        let url = home.appendingPathComponent(".claude/mcp-needs-auth-cache.json")
        guard let json = cachedJSON(at: url) else { return [] }

        var result: [ClaudeConnector] = []
        for (key, value) in json {
            // Keys look like "plugin:productivity:notion".
            let parts = key.split(separator: ":").map(String.init)
            let plugin = parts.count >= 3 ? parts[1] : nil
            let millis = (value as? [String: Any])?["timestamp"] as? Double
            result.append(ClaudeConnector(
                id: "auth:\(key)",
                name: Self.displayName(forServerKey: parts.last ?? key),
                status: .needsAuth,
                source: parts.first == "plugin" ? .plugin : .local,
                toolCount: 0,
                enabledToolCount: 0,
                lastUsed: millis.map { Date(timeIntervalSince1970: $0 / 1000) },
                context: plugin
            ))
        }
        return result.sorted { $0.name < $1.name }
    }

    // MARK: - JSON helpers

    private func cachedJSON(at url: URL) -> [String: Any]? {
        guard let mtime = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate
        else { return nil }

        if let cached = configCache[url.path], cached.mtime == mtime {
            return cached.json
        }
        let json = readJSON(at: url)
        configCache[url.path] = (mtime, json)
        return json
    }

    private func readJSON(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// "plugin:productivity:notion" → "Notion"; "my-server" → "My Server".
    static func displayName(forServerKey key: String) -> String {
        let cleaned = key
            .replacingOccurrences(of: "_", with: "-")
            .split(separator: "-")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
        return cleaned.isEmpty ? key : cleaned
    }
}

// MARK: - Model

/// Owns the refresh loop and publishes snapshots to the widget. Scanning runs
/// on a utility queue; the mtime cache keeps a steady-state refresh down to
/// one small file read plus, at most, one session file parse.
@MainActor
final class ClaudeConnectionsModel: ObservableObject {
    @Published private(set) var snapshot: ClaudeConnectionsSnapshot?

    private let scanner = ClaudeConnectionsScanner()
    private let queue = DispatchQueue(label: "com.overlaylens.claudeconnections", qos: .utility)
    private var timer: Timer?
    private var isSlowPace = false

    var isRunning: Bool { timer != nil }

    func start() {
        guard timer == nil else { return }
        tick()
        scheduleTimer()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Covered by other windows: nobody can read it, so drop to a lazy pace.
    func setSlowPace(_ slow: Bool) {
        guard isSlowPace != slow else { return }
        isSlowPace = slow
        guard timer != nil else { return }
        timer?.invalidate()
        if !slow { tick() }
        scheduleTimer()
    }

    func refreshNow() {
        tick()
    }

    private func scheduleTimer() {
        // Connections change on the scale of minutes, and a tick walks the
        // session directory, so there is nothing to gain from a fast pace.
        timer = Timer.scheduledTimer(
            withTimeInterval: isSlowPace ? 120 : 15, repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        let appRunning = !NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.anthropic.claudefordesktop")
            .isEmpty
        queue.async { [weak self] in
            guard let self else { return }
            let next = self.scanner.scan(isClaudeAppRunning: appRunning)
            Task { @MainActor in
                // Snapshots compare equal most ticks, so SwiftUI skips the
                // re-render entirely.
                if self.snapshot != next { self.snapshot = next }
            }
        }
    }
}

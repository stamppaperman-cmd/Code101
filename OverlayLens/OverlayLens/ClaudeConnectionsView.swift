import AppKit
import SwiftUI

/// Desktop glass widget listing which apps Claude is wired to: claude.ai
/// connectors and local MCP servers as rows (with a live dot on whatever a
/// session touched in the last few minutes), and servers still waiting for
/// sign-in as compact amber chips underneath.
struct ClaudeConnectionsView: View {
    @ObservedObject var model: ClaudeConnectionsModel
    /// Close button in the header; hides the widget until it is switched back
    /// on from the menu bar.
    var onClose: (() -> Void)? = nil

    @State private var hoveringClose = false

    private static let mint = Color(red: 0.50, green: 0.86, blue: 0.76)
    private static let amber = Color(red: 0.96, green: 0.75, blue: 0.41)
    private static let live = Color(red: 0.36, green: 0.85, blue: 0.53)

    /// Claude brand orange (Crail), matching the menu bar mascot.
    private static let orange = Color(red: 0.85, green: 0.47, blue: 0.34)
    private static let close = Color(red: 0.89, green: 0.29, blue: 0.29)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let snapshot = model.snapshot {
                if snapshot.isEmpty {
                    emptyState
                } else {
                    connectedSection(snapshot)
                    pendingSection(snapshot)
                }
                footer(snapshot)
            } else {
                Text("กำลังอ่านการเชื่อมต่อ…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 140)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .frame(width: 300, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.35), .white.opacity(0.08)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
        .padding(10)
        // Top-anchored inside the fixed panel so the card grows downward as
        // connectors come and go.
        .frame(width: 320, height: 460, alignment: .top)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            closeButton
            VStack(alignment: .leading, spacing: 1) {
                Text("Claude เชื่อมกับแอป")
                    .font(.system(size: 14, weight: .semibold))
                Text(subtitleText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            // Static dots on purpose: a repeatForever pulse keeps SwiftUI
            // redrawing the whole card at 60fps for as long as the widget is
            // on the desktop, which costs about as much as the scan itself.
            if model.snapshot?.isClaudeAppRunning == true {
                Circle()
                    .fill(Self.live)
                    .frame(width: 7, height: 7)
            }
        }
    }

    /// Takes the top-left corner, where a window's close button belongs. It
    /// stays visible rather than appearing on hover — the widget sits below
    /// every app window, so a control nobody can see is a control nobody
    /// finds. Hovering turns it red so the intent is unmistakable.
    @ViewBuilder
    private var closeButton: some View {
        if let onClose {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(hoveringClose ? Color.white : .primary.opacity(0.55))
                    .frame(width: 18, height: 18)
                    .background(
                        Circle().fill(hoveringClose
                            ? Self.close
                            : Color.primary.opacity(0.12))
                    )
            }
            .buttonStyle(.plain)
            .help("ซ่อนวิดเจ็ต (เปิดใหม่ได้จากเมนูบาร์)")
            .onHover { hoveringClose = $0 }
        } else {
            Image(systemName: "app.connected.to.app.below.fill")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Self.orange)
        }
    }

    private var subtitleText: String {
        guard let snapshot = model.snapshot else { return "…" }
        let active = snapshot.connected.filter { $0.status == .activeNow }.count
        if active > 0 { return "ใช้งานอยู่ \(active) · เชื่อมไว้ \(snapshot.connected.count)" }
        if snapshot.connected.isEmpty { return "ยังไม่มีการเชื่อมต่อ" }
        return "เชื่อมไว้ \(snapshot.connected.count) แอป"
    }

    // MARK: - Connected

    @ViewBuilder
    private func connectedSection(_ snapshot: ClaudeConnectionsSnapshot) -> some View {
        if !snapshot.connected.isEmpty {
            VStack(spacing: 5) {
                ForEach(snapshot.connected) { connector in
                    connectorRow(connector)
                }
            }
            .animation(.easeOut(duration: 0.3), value: snapshot.connected.map(\.id))
        }
    }

    private func connectorRow(_ connector: ClaudeConnector) -> some View {
        let tint = Self.tint(for: connector.name)
        return HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(tint.opacity(0.22))
                .frame(width: 26, height: 26)
                .overlay(
                    Image(systemName: Self.symbol(for: connector.name))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(tint)
                )
            VStack(alignment: .leading, spacing: 1) {
                Text(connector.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(Self.detail(for: connector))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            statusPill(connector.status)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(connector.status == .activeNow
                    ? Self.live.opacity(0.12)
                    : Color.primary.opacity(0.05))
        )
    }

    @ViewBuilder
    private func statusPill(_ status: ClaudeConnector.Status) -> some View {
        switch status {
        case .activeNow:
            HStack(spacing: 4) {
                Circle()
                    .fill(Self.live)
                    .frame(width: 6, height: 6)
                Text("ใช้อยู่")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Self.live)
            }
        case .connected:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(Self.mint.opacity(0.85))
        case .needsAuth:
            Image(systemName: "lock.fill")
                .font(.system(size: 11))
                .foregroundStyle(Self.amber)
        }
    }

    // MARK: - Waiting for sign-in

    @ViewBuilder
    private func pendingSection(_ snapshot: ClaudeConnectionsSnapshot) -> some View {
        if !snapshot.pending.isEmpty {
            Rectangle()
                .fill(.primary.opacity(0.15))
                .frame(height: 1)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 10))
                    Text("ยังไม่ได้ล็อกอิน (\(snapshot.pending.count))")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(Self.amber)

                // Names only, wrapped and capped — a full row each would push
                // the widget past the panel long before the list ends.
                let shown = snapshot.pending.prefix(Self.pendingChipLimit)
                let overflow = snapshot.pending.count - shown.count
                FlowLayout(spacing: 5) {
                    ForEach(shown) { connector in
                        chip(connector.name, filled: true)
                    }
                    if overflow > 0 {
                        chip("+\(overflow) อื่น ๆ", filled: false)
                    }
                }
            }
        }
    }

    private static let pendingChipLimit = 12

    private func chip(_ text: String, filled: Bool) -> some View {
        Text(text)
            .font(.system(size: 10.5))
            .foregroundStyle(.primary.opacity(filled ? 0.8 : 0.55))
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(
                Capsule().fill(filled ? Self.amber.opacity(0.16) : Color.primary.opacity(0.07))
            )
    }

    // MARK: - Footer

    @ViewBuilder
    private func footer(_ snapshot: ClaudeConnectionsSnapshot) -> some View {
        if let title = snapshot.activeSessionTitle, let last = snapshot.lastActivity {
            HStack(spacing: 5) {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .font(.system(size: 10))
                Text("\(title) · \(Self.relativeText(last))")
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "powerplug")
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
            Text("ยังไม่พบแอปที่เชื่อมกับ Claude")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    // MARK: - Formatting

    private static func detail(for connector: ClaudeConnector) -> String {
        var parts: [String] = []
        if connector.toolCount > 0 {
            if connector.enabledToolCount > 0 && connector.enabledToolCount < connector.toolCount {
                parts.append("\(connector.enabledToolCount)/\(connector.toolCount) เครื่องมือ")
            } else {
                parts.append("\(connector.toolCount) เครื่องมือ")
            }
        }
        switch connector.source {
        case .connector:
            if connector.toolCount == 0 { parts.append("claude.ai") }
        case .local:
            parts.append(connector.context ?? "ตั้งค่าในเครื่อง")
        case .plugin:
            parts.append("ปลั๊กอิน \(connector.context ?? "")")
        }
        if let last = connector.lastUsed, connector.status != .activeNow {
            parts.append(relativeText(last))
        }
        return parts.joined(separator: " · ")
    }

    static func relativeText(_ date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)
        if seconds < 90 { return "เมื่อสักครู่" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes) นาทีที่แล้ว" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours) ชม.ที่แล้ว" }
        let days = hours / 24
        if days == 1 { return "เมื่อวาน" }
        return "\(days) วันที่แล้ว"
    }

    /// SF Symbol per service; falls back to a generic plug for anything new.
    static func symbol(for name: String) -> String {
        let key = name.lowercased()
        switch true {
        case key.contains("slack"): return "number"
        case key.contains("notion"): return "doc.text.fill"
        case key.contains("calendar"): return "calendar"
        case key.contains("drive"): return "externaldrive.fill"
        case key.contains("gmail"), key.contains("mail"): return "envelope.fill"
        case key.contains("canva"): return "paintpalette.fill"
        case key.contains("figma"): return "square.on.circle.fill"
        case key.contains("github"), key.contains("gitlab"):
            return "chevron.left.forwardslash.chevron.right"
        case key.contains("linear"): return "arrow.right.circle.fill"
        case key.contains("asana"): return "circle.hexagongrid.fill"
        case key.contains("atlassian"), key.contains("jira"): return "square.grid.2x2.fill"
        case key.contains("monday"): return "calendar.badge.clock"
        case key.contains("clickup"): return "checkmark.circle.fill"
        case key.contains("intercom"): return "bubble.left.fill"
        case key.contains("datadog"): return "pawprint.fill"
        case key.contains("pagerduty"): return "bell.badge.fill"
        case key.contains("hubspot"): return "person.2.fill"
        case key.contains("klaviyo"): return "envelope.badge.fill"
        case key.contains("ahrefs"), key.contains("similarweb"): return "magnifyingglass"
        case key.contains("amplitude"): return "waveform"
        case key.contains("supermetrics"): return "chart.bar.fill"
        case key.contains("hex"), key.contains("bigquery"), key.contains("query"):
            return "cylinder.split.1x2.fill"
        case key.contains("box"): return "shippingbox.fill"
        case key.contains("gong"): return "waveform.circle.fill"
        case key.contains("granola"): return "note.text"
        case key.contains("chrome"), key.contains("browser"): return "globe"
        case key.contains("playwright"), key.contains("puppeteer"): return "theatermasks.fill"
        case key.contains("discord"): return "gamecontroller.fill"
        case key.contains("telegram"), key.contains("imessage"): return "message.fill"
        case key.contains("firebase"), key.contains("terraform"): return "server.rack"
        default: return "powerplug.fill"
        }
    }

    /// Loose brand tints — enough to tell services apart at a glance.
    static func tint(for name: String) -> Color {
        let key = name.lowercased()
        switch true {
        case key.contains("slack"): return Color(red: 0.90, green: 0.45, blue: 0.60)
        case key.contains("notion"): return Color(red: 0.75, green: 0.75, blue: 0.78)
        case key.contains("calendar"): return Color(red: 0.30, green: 0.60, blue: 0.98)
        case key.contains("drive"): return Color(red: 0.35, green: 0.78, blue: 0.50)
        case key.contains("canva"): return Color(red: 0.20, green: 0.78, blue: 0.86)
        case key.contains("figma"): return Color(red: 0.70, green: 0.45, blue: 1.00)
        case key.contains("github"), key.contains("gitlab"):
            return Color(red: 0.80, green: 0.80, blue: 0.84)
        case key.contains("linear"): return Color(red: 0.45, green: 0.50, blue: 0.98)
        case key.contains("datadog"): return Color(red: 0.60, green: 0.40, blue: 0.90)
        case key.contains("hubspot"), key.contains("pagerduty"):
            return Color(red: 0.98, green: 0.55, blue: 0.35)
        case key.contains("intercom"): return Color(red: 0.35, green: 0.65, blue: 0.95)
        case key.contains("atlassian"), key.contains("jira"):
            return Color(red: 0.36, green: 0.55, blue: 0.95)
        default: return mint
        }
    }
}

/// Minimal wrapping HStack — SwiftUI has no flow layout and the sign-in chips
/// need to wrap onto as many lines as they take.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + lineHeight)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

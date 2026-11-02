import AppKit
import SwiftUI

/// Desktop glass widget: CPU and RAM drawn as square chips with a progress
/// border running around the package, a temperature strip, and the top four
/// apps by usage. Tapping a chip switches which metric the list sorts by;
/// hovering an app row reveals a quit button (two clicks to confirm,
/// Option-click force-quits).
struct SystemStatsView: View {
    @ObservedObject var model: SystemStatsModel

    @State private var hoveredApp: String?
    @State private var confirmingApp: String?

    private static let mint = Color(red: 0.50, green: 0.86, blue: 0.76)
    private static let amber = Color(red: 0.96, green: 0.75, blue: 0.41)
    private static let red = Color(red: 0.89, green: 0.29, blue: 0.29)

    var body: some View {
        VStack(spacing: 12) {
            if let snapshot = model.snapshot {
                chipRow(snapshot)
                temperatureRow(snapshot)
                stuckSection(snapshot)
            } else {
                Text("กำลังวัดการใช้งาน…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 180)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 20)
        .frame(width: 300)
        .smokeGlass(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .environment(\.colorScheme, .dark)
        .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
        .padding(10)
        // Top-anchored inside the fixed-size panel so the card grows
        // downward when the stuck-app row appears.
        .frame(width: 320, height: 460, alignment: .top)
    }

    // MARK: - Chips

    private func chipRow(_ snapshot: SystemStatsSnapshot) -> some View {
        HStack(spacing: 22) {
            gauge(
                symbol: "cpu",
                fraction: snapshot.cpuUsage,
                value: "\(Int((snapshot.cpuUsage * 100).rounded()))%",
                title: "CPU",
                detail: "\(snapshot.coreCount) cores",
                color: Self.heatColor(fraction: snapshot.cpuUsage)
            )
            gauge(
                symbol: "memorychip",
                fraction: ramFraction(snapshot),
                value: Self.gigabytesText(snapshot.ramUsedBytes),
                title: "RAM",
                detail: "/\(Int((Double(snapshot.ramTotalBytes) / 1_073_741_824).rounded())) GB",
                color: ramColor(snapshot)
            )
        }
        .frame(maxWidth: .infinity)
    }

    private func gauge(symbol: String, fraction: Double, value: String,
                       title: String, detail: String, color: Color) -> some View {
        VStack(spacing: 8) {
            GlassRing(fraction: fraction, color: color, lineWidth: 9) {
                VStack(spacing: 1) {
                    Image(systemName: symbol)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.75))
                    Text(value)
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .contentTransition(.numericText())
                        .minimumScaleFactor(0.7)
                        .lineLimit(1)
                }
                .padding(.horizontal, 12)
            }
            .frame(width: 104, height: 104)
            HStack(spacing: 5) {
                Text(title)
                    .font(.system(size: 12, weight: .heavy))
                    .tracking(1.2)
                    .foregroundStyle(.white)
                Text(detail)
                    .font(.system(size: 11.5, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.62))
            }
        }
    }

    private func ramFraction(_ snapshot: SystemStatsSnapshot) -> Double {
        guard snapshot.ramTotalBytes > 0 else { return 0 }
        return Double(snapshot.ramUsedBytes) / Double(snapshot.ramTotalBytes)
    }

    /// RAM color follows memory pressure (the system's own verdict), but
    /// also warms up when usage alone gets high so the widget looks alive
    /// before pressure notifications kick in.
    private func ramColor(_ snapshot: SystemStatsSnapshot) -> Color {
        switch snapshot.memoryPressure {
        case .critical: return Self.red
        case .warning: return Self.amber
        case .normal:
            let used = ramFraction(snapshot)
            if used > 0.92 { return Self.red }
            if used > 0.75 { return Self.amber }
            return Self.mint
        }
    }

    private static func heatColor(fraction: Double) -> Color {
        if fraction > 0.8 { return red }
        if fraction > 0.5 { return amber }
        return mint
    }

    // MARK: - Temperature

    private func temperatureRow(_ snapshot: SystemStatsSnapshot) -> some View {
        let (stateText, stateColor) = Self.thermalDescription(snapshot.thermalState)
        return HStack(spacing: 8) {
            Image(systemName: "thermometer.medium")
                .font(.system(size: 13))
                .frame(width: 18)
                .foregroundStyle(.primary.opacity(0.85))
            if let temperature = snapshot.cpuTemperature {
                Text("\(Int(temperature.rounded()))°C")
                    .font(.system(size: 13.5, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Capsule()
                    .fill(.primary.opacity(0.15))
                    .frame(height: 5)
                    .overlay(alignment: .leading) {
                        GeometryReader { geo in
                            Capsule()
                                .fill(stateColor)
                                .frame(width: geo.size.width * temperatureBarFraction(temperature))
                        }
                        .frame(height: 5)
                    }
                    .animation(.easeOut(duration: 0.35), value: temperature)
            } else {
                Text("อุณหภูมิ")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            Text(stateText)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(stateColor)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            Capsule().fill(Color.white.opacity(0.07))
                .overlay(GlassRim(shape: Capsule(), strength: 0.6))
        )
    }

    /// 30–100°C mapped to 0…1 — the realistic operating span of an M-series die.
    private func temperatureBarFraction(_ celsius: Double) -> CGFloat {
        CGFloat(min(max((celsius - 30) / 70, 0), 1))
    }

    private static func thermalDescription(_ state: ProcessInfo.ThermalState) -> (String, Color) {
        switch state {
        case .nominal: return ("ปกติ", mint)
        case .fair: return ("เริ่มร้อน", amber)
        case .serious: return ("ร้อน", red)
        case .critical: return ("วิกฤต", red)
        @unknown default: return ("ปกติ", mint)
        }
    }

    // MARK: - App list

    /// The widget stays minimal — chips and temperature only. App rows exist
    /// solely as an alarm: a red row appears while a Dock app is stuck
    /// (≥90% of a core for 30s+) so it can be force-quit, then vanishes.
    @ViewBuilder
    private func stuckSection(_ snapshot: SystemStatsSnapshot) -> some View {
        let stuck = snapshot.apps
            .filter { $0.isRegularApp && $0.isStuck }
            .sorted { $0.cpu > $1.cpu }
        if !stuck.isEmpty {
            Rectangle()
                .fill(.primary.opacity(0.15))
                .frame(height: 1)
            VStack(spacing: 6) {
                ForEach(stuck) { app in
                    appRow(app, snapshot: snapshot)
                }
            }
            .animation(.easeOut(duration: 0.3), value: stuck.map(\.id))
        }
    }

    private func appRow(_ app: AppUsage, snapshot: SystemStatsSnapshot) -> some View {
        let fraction = min(app.cpu, 1)
        let valueText = "\(Int((app.cpu * 100).rounded()))%"
        let hovered = hoveredApp == app.id
        let confirming = confirmingApp == app.id

        return HStack(spacing: 8) {
            // The quit button takes over the icon slot so the usage number
            // on the right stays readable the whole time.
            if app.isQuittable && (hovered || app.isStuck || confirming) {
                Button {
                    confirming ? quit(app) : beginQuitConfirmation(app)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(Self.red))
                }
                .buttonStyle(.plain)
            } else if let icon = app.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 18, height: 18)
            } else {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 12))
                    .frame(width: 18, height: 18)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 4) {
                Text(app.name)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if app.isStuck {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Self.red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Capsule()
                .fill(.primary.opacity(0.15))
                .frame(width: 64, height: 5)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(Self.heatColor(fraction: fraction))
                        .frame(width: 64 * max(min(fraction, 1), 0.02), height: 5)
                        .animation(.easeOut(duration: 0.35), value: fraction)
                }
            trailingControl(for: app, valueText: valueText, confirming: confirming)
                .frame(width: 40, alignment: .trailing)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(app.isStuck
                    ? Self.red.opacity(hovered ? 0.22 : 0.15)
                    : Color.primary.opacity(hovered ? 0.08 : 0))
        )
        .onHover { inside in
            if inside {
                hoveredApp = app.id
            } else if hoveredApp == app.id {
                hoveredApp = nil
            }
        }
    }

    /// The value stays visible at all times; it only briefly becomes the
    /// "ปิด?" confirmation button for the 2-second arm window.
    @ViewBuilder
    private func trailingControl(
        for app: AppUsage, valueText: String, confirming: Bool
    ) -> some View {
        if app.isQuittable && confirming {
            Button {
                quit(app)
            } label: {
                Text("ปิด?")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Self.red))
            }
            .buttonStyle(.plain)
        } else {
            Text(valueText)
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(.primary.opacity(0.85))
        }
    }

    /// First click arms a 2-second confirmation instead of quitting straight
    /// away, so a stray click on the desktop can't kill an app.
    private func beginQuitConfirmation(_ app: AppUsage) {
        confirmingApp = app.id
        let armed = app.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if confirmingApp == armed {
                confirmingApp = nil
            }
        }
    }

    private func quit(_ app: AppUsage) {
        confirmingApp = nil
        guard let pid = app.pid,
              let running = NSRunningApplication(processIdentifier: pid)
        else { return }
        if app.isStuck || NSEvent.modifierFlags.contains(.option) {
            // A stuck app won't answer a polite quit; skip straight to force.
            running.forceTerminate()
        } else {
            // Graceful quit: the app shows its own unsaved-changes dialogs.
            running.terminate()
        }
    }

    // MARK: - Formatting

    private static func gigabytesText(_ bytes: UInt64) -> String {
        let gigabyte = 1_073_741_824.0
        let value = Double(bytes)
        if value >= gigabyte {
            return String(format: "%.1fG", value / gigabyte)
        }
        return "\(Int(value / 1_048_576))M"
    }
}

import AppKit
import SwiftUI

/// Finish Engine panel — Liquid Glass shell with frosted, high-contrast cards.
/// The shell is real glass (macOS 26+); every block of text sits on a denser
/// surface so it stays readable over any wallpaper, light or dark.
/// Changing an AI still writes Widget Display.AI in Notion.
struct FinishEngineView: View {
    @ObservedObject var model: FinishEngineModel
    var onClose: (() -> Void)? = nil

    @AppStorage("FinishEngineExpanded") private var expandedName = ""
    /// Pill mode: a small capsule that stays out of the way; click it to expand.
    @AppStorage("FinishEngineCompact") private var compact = false
    @State private var copiedAt: Date?
    @State private var listContentHeight: CGFloat = 220

    // MARK: Palette
    private static let accent = Color(red: 0.24, green: 0.42, blue: 0.98)
    private static let accentHi = Color(red: 0.40, green: 0.68, blue: 1.0)
    /// Always dark: smoked glass + white type, like Apple's desktop widgets.
    private let isDark = true
    /// Secondary text: fixed opacity instead of .secondary, which washes out on glass.
    private var subInk: Color { Color.primary.opacity(isDark ? 0.68 : 0.60) }
    private var faintInk: Color { Color.primary.opacity(isDark ? 0.50 : 0.45) }
    private var amber: Color {
        isDark ? Color(red: 1.0, green: 0.72, blue: 0.36) : Color(red: 0.62, green: 0.35, blue: 0.02)
    }
    private var expanded: String? { expandedName.isEmpty ? nil : expandedName }

    var body: some View {
        Group {
            if compact {
                pillView
                    .padding(24)
                    .frame(
                        width: FinishEngineController.panelSize.width,
                        height: FinishEngineController.panelSize.height,
                        alignment: .topLeading
                    )
            } else {
                fullView
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: compact)
    }

    // MARK: Pill (compact mode)

    private var pillView: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(colors: [Self.accentHi, Self.accent],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                    Image(systemName: "flag.checkered")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 24, height: 24)

                if model.projects.isEmpty {
                    Text("Finish Engine")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                } else {
                    ForEach(model.projects.prefix(4)) { project in
                        HStack(spacing: 3) {
                            Text(shortName(project.name))
                                .foregroundStyle(subInk)
                            Text("\(project.mvp)%")
                                .monospacedDigit()
                                .foregroundStyle(project.mvp == 100 ? aiColor(.chatgpt) : .primary)
                        }
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                        .fixedSize()
                        .help("\(project.name) — งานถัดไป: \(project.next)")
                    }
                }
                if model.errorCode != nil {
                    Circle().fill(amber).frame(width: 6, height: 6)
                }
            }
            .padding(.vertical, 2)
            .overlay(WindowDragHandle())
            .help("ลากเพื่อย้าย · กด + เพื่อกาง")

            Button { compact = false } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10.5, weight: .heavy))
                    .foregroundStyle(Color.primary.opacity(0.78))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.white.opacity(0.12)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("กางหน้าต่าง Finish Engine")
        }
        .padding(.leading, 6)
        .padding(.trailing, 7)
        .padding(.vertical, 6)
        .smokeGlass(Capsule())
        .environment(\.colorScheme, .dark)
        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
        .fixedSize()
    }

    /// "Finish Engine" → "FE", "AI OS" → "AI OS": keeps the pill short.
    private func shortName(_ name: String) -> String {
        let words = name.split(separator: " ")
        if name.count <= 6 || words.count < 2 { return name }
        return words.compactMap { $0.first.map(String.init) }.joined().uppercased()
    }

    // MARK: Full card

    private var fullView: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, 16)

            if let code = model.errorCode {
                errorBanner(code)
                    .padding(.bottom, 12)
            }

            if model.projects.isEmpty {
                emptyState
            } else {
                ScrollView(.vertical) {
                    VStack(spacing: 12) {
                        ForEach(model.projects) { project in
                            projectCard(project)
                        }
                    }
                    .padding(.bottom, 4)
                    .onGeometryChange(for: CGFloat.self) { geometry in
                        geometry.size.height
                    } action: { height in
                        listContentHeight = height
                    }
                }
                .scrollIndicators(.hidden)
                .frame(height: listHeight)
                .padding(.bottom, 14)
                footer
            }
        }
        .padding(18)
        .frame(width: 340, alignment: .leading)
        .smokeGlass(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .environment(\.colorScheme, .dark)
        .shadow(color: .black.opacity(isDark ? 0.40 : 0.22), radius: 30, y: 16)
        .padding(24)
        .frame(
            width: FinishEngineController.panelSize.width,
            height: FinishEngineController.panelSize.height,
            alignment: .top
        )
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: expanded)
        .animation(.easeInOut(duration: 0.2), value: copiedAt)
    }

    /// Cap the project area so four cards and long tasks can always scroll.
    private var listHeight: CGFloat {
        min(420, listContentHeight)
    }

    // MARK: Surfaces

    /// Specular edge: bright at the top, fading down — the "glass lip".
    private func glassRim(radius: CGFloat, strength: Double) -> some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .strokeBorder(
                LinearGradient(
                    colors: [
                        Color.white.opacity((isDark ? 0.34 : 0.95) * strength),
                        Color.white.opacity((isDark ? 0.06 : 0.30) * strength),
                        Color.white.opacity((isDark ? 0.14 : 0.55) * strength),
                    ],
                    startPoint: .top, endPoint: .bottom
                ),
                lineWidth: 1
            )
            .allowsHitTesting(false)
    }

    /// Dense frosted layer that carries text (legibility over any wallpaper).
    private func cardFill(_ radius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(isDark ? Color.white.opacity(0.07) : Color.white.opacity(0.80))
            .overlay(glassRim(radius: radius, strength: 0.8))
            .shadow(color: .black.opacity(isDark ? 0.18 : 0.08), radius: 10, y: 4)
    }

    private func pill(_ fill: Color) -> some View {
        Capsule().fill(fill).overlay(
            Capsule().strokeBorder(Color.white.opacity(isDark ? 0.12 : 0.55), lineWidth: 0.8)
        )
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(LinearGradient(colors: [Self.accentHi, Self.accent],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.45), lineWidth: 0.8)
                    Image(systemName: "flag.checkered")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 38, height: 38)
                .shadow(color: Self.accent.opacity(0.35), radius: 8, y: 3)

                VStack(alignment: .leading, spacing: 1) {
                    Text("FINISH ENGINE")
                        .font(.system(size: 10.5, weight: .heavy, design: .rounded))
                        .tracking(1.5)
                        .foregroundStyle(isDark ? Self.accentHi : Self.accent)
                    Text("งานที่กำลังเดิน")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.primary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .overlay(WindowDragHandle())
            .help("ลากเพื่อย้ายหน้าต่าง")

            iconButton("arrow.clockwise", spinning: model.isLoading) { model.refresh() }
                .disabled(model.isLoading)
                .help("ดึงข้อมูลใหม่จาก Notion")

            iconButton("minus") { expandedName = ""; compact = true }
                .help("ย่อเป็นแถบเล็ก (pill)")

            if let onClose {
                iconButton("xmark", action: onClose)
                    .help("ซ่อน (⌃⌥⌘F เปิดใหม่)")
            }
        }
    }

    private func iconButton(_ symbol: String, spinning: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.primary.opacity(0.78))
                .rotationEffect(.degrees(spinning ? 180 : 0))
                .animation(spinning ? .linear(duration: 0.6).repeatForever(autoreverses: false) : .default,
                           value: spinning)
                .frame(width: 30, height: 30)
                .background(
                    Circle().fill(isDark ? Color.white.opacity(0.12) : Color.white.opacity(0.62))
                )
                .overlay(Circle().strokeBorder(Color.white.opacity(isDark ? 0.18 : 0.8), lineWidth: 0.8))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private var syncText: String {
        if model.isLoading && model.lastSync == nil { return "กำลังดึงข้อมูล…" }
        guard let date = model.lastSync else { return "ยังไม่เคยอัปเดต" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "th_TH")
        formatter.dateFormat = "HH:mm"
        return "อัปเดต \(formatter.string(from: date))"
    }

    // MARK: Empty / error

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(Self.accent)
            Text(model.lastSync == nil ? "กำลังดึงโปรเจกต์" : "ยังไม่มีโปรเจกต์ที่เลือก")
                .font(.system(size: 14.5, weight: .semibold))
            Text(model.lastSync == nil
                 ? "รอสักครู่ ข้อมูลจะปรากฏตรงนี้"
                 : "ตรวจ Show และ เสร็จแล้ว ในตาราง Widget Display")
                .font(.system(size: 12.5))
                .foregroundStyle(subInk)
        }
        .frame(maxWidth: .infinity, minHeight: 100, alignment: .leading)
        .padding(16)
        .background(cardFill(20))
    }

    private func errorBanner(_ code: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(amber)
            VStack(alignment: .leading, spacing: 3) {
                Text(FinishEngineModel.message(for: code))
                    .font(.system(size: 12, weight: .semibold))
                if !model.projects.isEmpty {
                    Text("กำลังแสดงข้อมูลที่ดึงได้ล่าสุด")
                        .font(.system(size: 11))
                        .foregroundStyle(subInk)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isDark ? Color.black.opacity(0.4) : Color.white.opacity(0.78))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(amber.opacity(0.12)))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(amber.opacity(0.35), lineWidth: 1))
        )
    }

    // MARK: Project card

    private func projectCard(_ project: FinishEngineProject) -> some View {
        let isOpen = expanded == project.name
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(project.name)
                    .font(.system(size: 15.5, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                aiPicker(project)
            }
            .padding(.bottom, 10)

            Button {
                expandedName = isOpen ? "" : project.name
            } label: {
                VStack(alignment: .leading, spacing: 11) {
                    HStack(alignment: .center, spacing: 12) {
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Text("\(project.mvp)")
                                .font(.system(size: 42, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(.primary)
                                .contentTransition(.numericText())
                            Text("%")
                                .font(.system(size: 18, weight: .bold, design: .rounded))
                                .foregroundStyle(isDark ? Self.accentHi : Self.accent)
                            Text("MVP")
                                .font(.system(size: 10.5, weight: .heavy))
                                .tracking(0.8)
                                .foregroundStyle(subInk)
                                .padding(.leading, 3)
                        }
                        Spacer(minLength: 0)
                        fullRing(project.full)
                    }
                    progressBar(project.mvp)

                    if !isOpen {
                        HStack(alignment: .center, spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("งานถัดไป")
                                    .font(.system(size: 10.5, weight: .bold))
                                    .foregroundStyle(isDark ? Self.accentHi : Self.accent)
                                Text(project.next)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(.primary)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(subInk)
                                .frame(width: 24, height: 24)
                                .background(Circle().fill(Color.primary.opacity(0.06)))
                        }
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Self.accent.opacity(isDark ? 0.16 : 0.07))
                        )
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isOpen ? "ย่อรายการงาน" : "ดูงาน MVP ที่เหลือ")

            if isOpen {
                taskList(project)
                    .padding(.top, 14)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(15)
        .background(cardFill(22))
    }

    private func progressBar(_ value: Int) -> some View {
        GeometryReader { geometry in
            let width = geometry.size.width * CGFloat(max(0, min(value, 100))) / 100
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(isDark ? 0.14 : 0.08))
                Capsule()
                    .fill(LinearGradient(colors: [Self.accent, Self.accentHi],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: width)
                    .shadow(color: Self.accent.opacity(0.45), radius: 5, y: 1)
                // specular highlight on the fill
                Capsule()
                    .fill(LinearGradient(colors: [Color.white.opacity(0.55), .clear],
                                         startPoint: .top, endPoint: .center))
                    .frame(width: width)
            }
        }
        .frame(height: 8)
    }

    private func fullRing(_ full: Int) -> some View {
        let fraction = CGFloat(max(0, min(full, 100))) / 100
        return VStack(spacing: 2) {
            ZStack {
                Circle().stroke(Color.primary.opacity(isDark ? 0.16 : 0.09), lineWidth: 4)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(Self.accentHi, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(full)")
                    .font(.system(size: 11.5, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
            }
            .frame(width: 36, height: 36)
            Text("FULL %")
                .font(.system(size: 8.5, weight: .heavy))
                .tracking(0.6)
                .foregroundStyle(subInk)
        }
        .help("ความคืบหน้ารวม (MVP + LATER)")
    }

    private func aiPicker(_ project: FinishEngineProject) -> some View {
        let color = aiColor(project.ai)
        return Menu {
            ForEach(FinishEngineAI.allCases, id: \.self) { ai in
                Button {
                    model.setAI(ai, for: project.name)
                } label: {
                    if ai == project.ai {
                        Label(ai.rawValue, systemImage: "checkmark")
                    } else {
                        Text(ai.rawValue)
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(project.ai.rawValue)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7.5, weight: .heavy))
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(pill(color.opacity(isDark ? 0.22 : 0.13)))
        }
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("AI ที่ปุ่ม ทำต่อ จะเปิด — คลิกเพื่อสลับ")
    }

    private func aiColor(_ ai: FinishEngineAI) -> Color {
        switch ai {
        case .claude:
            return isDark ? Color(red: 0.96, green: 0.62, blue: 0.48) : Color(red: 0.66, green: 0.30, blue: 0.18)
        case .chatgpt:
            return isDark ? Color(red: 0.42, green: 0.86, blue: 0.66) : Color(red: 0.06, green: 0.46, blue: 0.32)
        case .codex:
            return isDark ? Self.accentHi : Self.accent
        case .gemini:
            return isDark ? Color(red: 0.55, green: 0.66, blue: 1.0) : Color(red: 0.20, green: 0.33, blue: 0.80)
        }
    }

    // MARK: Tasks

    private func taskList(_ project: FinishEngineProject) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("งาน MVP ที่เหลือ")
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundStyle(.primary)
                Spacer()
                Text("\(FinishEngineModel.weightText(project.doneWeight))/\(FinishEngineModel.weightText(project.mvpWeight)) W")
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(subInk)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
            }
            if project.remaining.isEmpty {
                Label("ไม่มีงาน MVP ค้าง", systemImage: "checkmark.seal.fill")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(subInk)
            }
            ForEach(Array(project.remaining.enumerated()), id: \.element.id) { index, task in
                taskRow(task, project: project, isNext: index == 0)
            }
        }
    }

    private func taskRow(_ task: FinishEngineTask, project: FinishEngineProject, isNext: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 9) {
                Capsule()
                    .fill(isNext
                          ? AnyShapeStyle(LinearGradient(colors: [Self.accentHi, Self.accent],
                                                          startPoint: .top, endPoint: .bottom))
                          : AnyShapeStyle(Color.primary.opacity(0.22)))
                    .frame(width: 3.5)
                VStack(alignment: .leading, spacing: 4) {
                    Text(task.task)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(statusLine(task))
                        .font(.system(size: 11))
                        .foregroundStyle(subInk)
                    if !task.blocker.isEmpty {
                        Text("ติดอยู่ที่: \(task.blocker)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(amber)
                            .lineLimit(2)
                            .help(task.blocker)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                suggestionTag(task, project: project)
                Spacer()
                continueButton(task, project: project, prominent: isNext)
            }
        }
        .padding(11)
        .background(
            shape.fill(isNext ? Self.accent.opacity(isDark ? 0.18 : 0.08) : Color.primary.opacity(isDark ? 0.07 : 0.035))
        )
        .overlay(
            shape.strokeBorder(isNext ? Self.accent.opacity(0.28) : Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private func suggestionTag(_ task: FinishEngineTask, project: FinishEngineProject) -> some View {
        let suggested = FinishEngineAI.suggested(for: task.task) ?? project.ai
        let color = aiColor(suggested)
        return Button {
            model.claimAndContinue(project: project.name, ai: suggested, task: task, onContinue: showCopied)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "sparkles")
                    .font(.system(size: 9, weight: .bold))
                Text("แนะนำ \(suggested.rawValue)")
            }
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Capsule().fill(color.opacity(isDark ? 0.14 : 0.07)))
            .overlay(Capsule().strokeBorder(color.opacity(0.40), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("คัดลอกคำสั่ง แล้วเปิด \(suggested.rawValue)")
    }

    private func statusLine(_ task: FinishEngineTask) -> String {
        let status = FinishEngineModel.statusTH[task.status] ?? task.status
        var line = "\(status) · W\(FinishEngineModel.weightText(task.weight))"
        if let holder = task.holder, let heldAt = task.heldAt {
            line += " · \(holder) \(FinishEngineModel.clock(heldAt))"
        }
        return line
    }

    private func continueButton(_ task: FinishEngineTask, project: FinishEngineProject, prominent: Bool) -> some View {
        Button {
            model.claimAndContinue(project: project.name, ai: project.ai, task: task, onContinue: showCopied)
        } label: {
            HStack(spacing: 5) {
                Text("ทำต่อ")
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9.5, weight: .heavy))
            }
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(prominent ? Color.white : (isDark ? Self.accentHi : Self.accent))
            .padding(.horizontal, 14)
            .padding(.vertical, 7.5)
            .background {
                if prominent {
                    Capsule()
                        .fill(LinearGradient(colors: [Self.accentHi, Self.accent],
                                             startPoint: .top, endPoint: .bottom))
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.45), lineWidth: 0.8))
                        .shadow(color: Self.accent.opacity(0.40), radius: 7, y: 3)
                } else {
                    Capsule().fill(Self.accent.opacity(isDark ? 0.20 : 0.10))
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("คัดลอกคำสั่ง แล้วเปิด \(project.ai.rawValue) ของ \(project.name) — วางด้วย ⌘V")
    }

    private func showCopied() {
        copiedAt = Date()
        let stamp = copiedAt
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            if copiedAt == stamp { copiedAt = nil }
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                if copiedAt != nil {
                    Label("คัดลอกแล้ว วางในแชทด้วย ⌘V", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(isDark ? Self.accentHi : Self.accent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(pill(Self.accent.opacity(isDark ? 0.22 : 0.12)))
                        .transition(.opacity)
                    Spacer()
                } else {
                    statChip("exclamationmark.bubble", "Pain Log \(shownPains) ค้าง")
                    Spacer()
                    statChip(evolveReady ? "sparkles" : "bolt.fill", evolveText,
                             tint: evolveReady ? aiColor(.chatgpt) : nil)
                }
            }

            Button {
                let ai = model.projects.first(where: { $0.name == "Finish Engine" })?.ai ?? .claude
                FinishEngineModel.continueInChat(project: "Finish Engine", ai: ai)
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "bubble.left.and.text.bubble.right.fill")
                        .foregroundStyle(isDark ? Self.accentHi : Self.accent)
                    Text("คุยกับ Finish Engine")
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(subInk)
                }
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 14)
                .frame(height: 42)
                .background(cardFill(14))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("เปิด AI ของ Finish Engine เพื่อสั่งแก้งานหรือถามสถานะ")

            HStack(spacing: 5) {
                Circle().fill(model.errorCode == nil ? Color.green : amber)
                    .frame(width: 6, height: 6)
                    .shadow(color: (model.errorCode == nil ? Color.green : amber).opacity(0.6), radius: 3)
                Text(syncText)
                Spacer()
                Image(systemName: "hand.draw")
                Text("ลากหัวแผงเพื่อย้าย")
            }
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(faintInk)
            .padding(.horizontal, 4)
        }
    }

    private func statChip(_ symbol: String, _ text: String, tint: Color? = nil) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 9.5, weight: .bold))
            Text(text)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(tint ?? subInk)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(pill(isDark ? Color.black.opacity(0.30) : Color.white.opacity(0.62)))
    }

    /// Open pains of the projects on screen only: the expanded one if any,
    /// otherwise the (max 4) listed cards. Never counts hidden projects.
    private var shownPains: Int {
        let listed = Array(model.projects.prefix(4))
        let scope = listed.filter { $0.name == expandedName }
        return (scope.isEmpty ? listed : scope)
            .reduce(0) { $0 + (model.painsByProject[$1.name] ?? 0) }
    }

    private var evolveReady: Bool { model.projects.contains(where: { $0.mvp == 100 }) }
    private var evolveText: String { evolveReady ? "EVOLVE พร้อม" : "MVP กำลังเดิน" }
}

/// A transparent AppKit drag region. It accepts the first click on a
/// nonactivating panel and saves the new position after the drag.
/// A click without movement calls `onClick` (used by the pill to expand).
/// The hand cursor uses an always-active tracking area: cursor rects are
/// ignored while OverlayLens isn't the active app, which is almost always.
struct WindowDragHandle: NSViewRepresentable {
    var onClick: (() -> Void)? = nil

    func makeNSView(context: Context) -> NSView {
        let view = DragHandleView()
        view.onClick = onClick
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? DragHandleView)?.onClick = onClick
    }

    private final class DragHandleView: NSView {
        var onClick: (() -> Void)?
        private var tracking: NSTrackingArea?

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate],
                owner: self, userInfo: nil
            )
            addTrackingArea(area)
            tracking = area
        }

        override func cursorUpdate(with event: NSEvent) { NSCursor.openHand.set() }
        override func mouseEntered(with event: NSEvent) { NSCursor.openHand.set() }
        override func mouseMoved(with event: NSEvent) { NSCursor.openHand.set() }
        override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            let before = window.frame.origin
            NSCursor.closedHand.set()
            window.performDrag(with: event)
            NSCursor.openHand.set()
            if window.frame.origin == before {
                onClick?()
                return
            }
            UserDefaults.standard.set(
                NSStringFromRect(window.frame), forKey: FinishEngineController.frameKey
            )
        }
    }
}

import AppKit
import SwiftUI

/// Finish Engine — "Medium" widget layout: a 2×2 grid of MVP rings on the
/// left, the selected project's next task on the right. Same model and
/// behaviour as the old panel (Widget Display, AI picker, claim, status.json).
/// Three sizes: pill (tiny capsule), medium card, and medium + flow (the
/// remaining MVP tasks and the old footer). Drag any empty area to move.
struct FinishEngineMediumView: View {
    @ObservedObject var model: FinishEngineModel
    var onClose: (() -> Void)? = nil
    /// The hosting panel, so a drag anywhere on the card can move it.
    var window: () -> NSWindow? = { nil }

    @AppStorage("FinishEngineSelected") private var selectedName = ""
    /// Pill mode, shared with the old panel's setting.
    @AppStorage("FinishEngineCompact") private var compact = false
    @AppStorage("FinishEngineFlowOpen") private var flowOpen = false
    @State private var copiedAt: Date?
    @State private var dragStart: (mouse: NSPoint, origin: NSPoint)?

    static let cardWidth: CGFloat = 364
    private static let mediumHeight: CGFloat = 176
    private static let ring = Color(red: 0.55, green: 0.62, blue: 1.0)
    private static let done = Color(red: 0.36, green: 0.86, blue: 0.56)
    private static let blocked = Color(red: 1.0, green: 0.72, blue: 0.36)
    private let subInk = Color.white.opacity(0.66)
    private let faintInk = Color.white.opacity(0.44)

    private var shown: [FinishEngineProject] { Array(model.projects.prefix(4)) }
    private var selected: FinishEngineProject? {
        shown.first(where: { $0.name == selectedName }) ?? shown.first
    }

    var body: some View {
        Group {
            if compact { pill } else { card }
        }
        .environment(\.colorScheme, .dark)
        .padding(20)
        .frame(
            width: FinishEngineController.panelSize.width,
            height: FinishEngineController.panelSize.height,
            alignment: .topLeading
        )
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: compact)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: flowOpen)
        .animation(.easeInOut(duration: 0.2), value: copiedAt)
    }

    // MARK: Pill

    private var pill: some View {
        HStack(spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: "flag.checkered")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Self.ring.opacity(0.55)))
                if shown.isEmpty {
                    Text("Finish Engine")
                        .font(.system(size: 11, weight: .semibold))
                } else {
                    ForEach(shown) { p in
                        HStack(spacing: 3) {
                            Text(shortName(p.name)).foregroundStyle(subInk)
                            Text("\(p.mvp)%")
                                .monospacedDigit()
                                .foregroundStyle(p.mvp >= 100 ? Self.done : .white)
                        }
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                        .fixedSize()
                        .help("\(p.name) — งานถัดไป: \(p.next)")
                    }
                }
                if model.errorCode != nil {
                    Circle().fill(Self.blocked).frame(width: 5, height: 5)
                }
            }
            .padding(.vertical, 2)
            .help("ลากเพื่อย้าย · กด + เพื่อกาง")

            Button { compact = false } label: {
                Image(systemName: "plus")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(width: 19, height: 19)
                    .background(Circle().fill(Color.white.opacity(0.12)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("กาง Finish Engine")
        }
        .padding(.leading, 5)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .smokeGlass(Capsule(), darkness: 0.55)
        .contentShape(Capsule())
        // Body only drags (a stray click no longer expands); + expands.
        .gesture(moveGesture)
        .shadow(color: .black.opacity(0.35), radius: 12, y: 5)
        .fixedSize()
    }

    /// "Finish Engine" → "FE", "AI OS" stays: keeps the pill short.
    private func shortName(_ name: String) -> String {
        let words = name.split(separator: " ")
        if name.count <= 6 || words.count < 2 { return name }
        return words.compactMap { $0.first.map(String.init) }.joined().uppercased()
    }

    // MARK: Card

    private var card: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                grid
                detail
            }
            .frame(height: Self.mediumHeight - 20)

            if flowOpen {
                flow
                    .padding(.top, 10)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(10)
        .frame(width: Self.cardWidth, alignment: .topLeading)
        .smokeGlass(shape, darkness: 0.62)
        .contentShape(shape)
        // Drag anywhere on the card (text included) to move the panel;
        // taps still go to the buttons.
        .gesture(moveGesture)
        .overlay(alignment: .topLeading) { statusDot }
        .contextMenu { contextItems }
        .shadow(color: .black.opacity(0.35), radius: 16, y: 8)
    }

    /// Uses screen coordinates (NSEvent.mouseLocation), not the gesture's own,
    /// because the view's coordinate space moves along with the window.
    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                guard let panel = window() else { return }
                let mouse = NSEvent.mouseLocation
                if dragStart == nil {
                    // Back out the few points moved before the gesture began
                    // (screen y points up, view y points down).
                    let pressed = NSPoint(x: mouse.x - value.translation.width,
                                          y: mouse.y + value.translation.height)
                    dragStart = (pressed, panel.frame.origin)
                }
                guard let start = dragStart else { return }
                panel.setFrameOrigin(NSPoint(x: start.origin.x + mouse.x - start.mouse.x,
                                             y: start.origin.y + mouse.y - start.mouse.y))
            }
            .onEnded { _ in
                dragStart = nil
                if let panel = window() {
                    UserDefaults.standard.set(NSStringFromRect(panel.frame),
                                              forKey: FinishEngineController.frameKey)
                }
            }
    }

    // MARK: Rings

    private var grid: some View {
        let slots = gridSlots
        return VStack(spacing: 4) {
            ForEach(0..<2, id: \.self) { row in
                HStack(spacing: 4) {
                    ForEach(0..<2, id: \.self) { col in
                        slots[row * 2 + col]
                    }
                }
            }
        }
        .frame(width: 144)
    }

    /// Up to four projects, then one "+" slot, then empty placeholders.
    private var gridSlots: [AnyView] {
        var views: [AnyView] = shown.map { AnyView(projectCell($0)) }
        if views.count < 4 { views.append(AnyView(addCell)) }
        while views.count < 4 { views.append(AnyView(emptyCell)) }
        return views
    }

    private func projectCell(_ p: FinishEngineProject) -> some View {
        let isSelected = shown.count > 1 && p.name == selected?.name
        return Button {
            selectedName = p.name
        } label: {
            VStack(spacing: 4) {
                GlassRing(fraction: Double(p.mvp) / 100, color: ringColor(p), lineWidth: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        Text("\(p.mvp)")
                            .font(.system(size: 13.5, weight: .bold, design: .rounded))
                        Text("%")
                            .font(.system(size: 7.5, weight: .bold, design: .rounded))
                    }
                    .foregroundStyle(.white)
                    .monospacedDigit()
                }
                .frame(width: 47, height: 47)
                HStack(spacing: 3) {
                    Circle().fill(aiColor(p.ai)).frame(width: 4.5, height: 4.5)
                    Text(p.name)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.white.opacity(isSelected ? 1 : 0.8))
            }
            .frame(width: 70, height: 74)
            .background {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(Color.white.opacity(isSelected ? 0.08 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(p.name) · MVP \(p.mvp)% · FULL \(p.full)%")
        .contextMenu {
            Button("📦 เก็บเข้าคลัง") { archive(p) }
            Divider()
            contextItems
        }
    }

    private var addCell: some View {
        Button(action: talkToFinishEngine) {
            VStack(spacing: 4) {
                ZStack {
                    Circle()
                        .strokeBorder(Color.white.opacity(0.28),
                                      style: StrokeStyle(lineWidth: 5, dash: [2.5, 3.2]))
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                }
                .frame(width: 47, height: 47)
                Text("เพิ่ม")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(subInk)
            }
            .frame(width: 70, height: 74)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("เปิดแชท Finish Engine เพื่อเพิ่มโปรเจกต์ (ติ๊ก Show ใน Widget Display)")
    }

    private var emptyCell: some View {
        VStack(spacing: 4) {
            Circle()
                .stroke(Color.white.opacity(0.10), lineWidth: 5)
                .padding(2.5)
                .frame(width: 47, height: 47)
            Text(" ").font(.system(size: 9.5))
        }
        .frame(width: 70, height: 74)
    }

    // MARK: Detail card

    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let p = selected {
                detailContent(p)
            } else {
                placeholder
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.09))
                .overlay(GlassRim(shape: RoundedRectangle(cornerRadius: 16, style: .continuous), strength: 0.6))
        }
    }

    private func detailContent(_ p: FinishEngineProject) -> some View {
        let task = p.remaining.first
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Text("งานถัดไป · \(p.name)")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Self.ring)
                    .lineLimit(1)
                Spacer(minLength: 2)
                toolbar
            }
            .padding(.bottom, 3)
            Text(p.next)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .help(p.next)
            if let blocker = task?.blocker, !blocker.isEmpty {
                Text(blocker)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Self.blocked)
                    .lineLimit(1)
                    .padding(.top, 2)
                    .help(blocker)
            }
            progressBar(p.mvp, color: ringColor(p))
                .padding(.top, 7)
            HStack(spacing: 9) {
                Text("MVP \(p.mvp)%")
                Text("FULL \(p.full)%")
            }
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(subInk)
            .monospacedDigit()
            .padding(.top, 5)

            Spacer(minLength: 5)

            HStack(spacing: 5) {
                aiChip(p)
                if p.mvp >= 100 {
                    archiveChip(p)
                } else {
                    painChip(model.painsByProject[p.name] ?? 0)
                }
                continueChip(p, task: task)
            }
        }
    }

    /// Tiny controls: flow (task list), pill, close. Refresh lives in the flow
    /// footer and the right-click menu.
    private var toolbar: some View {
        HStack(spacing: 3) {
            if !model.archived.isEmpty {
                archiveBox
            }
            smallIcon(flowOpen ? "chevron.up" : "list.bullet", help: flowOpen ? "ซ่อนรายการงาน" : "ดูงาน MVP ที่เหลือ") {
                flowOpen.toggle()
            }
            smallIcon("minus", help: "ย่อเป็นแถบเล็ก") { compact = true }
            if let onClose {
                smallIcon("xmark", help: "ซ่อน (⌃⌥⌘F เปิดใหม่)", action: onClose)
            }
        }
    }

    /// 📦 เสร็จแล้ว box: archived projects, click one to bring it back.
    private var archiveBox: some View {
        Menu {
            archiveBoxItems
        } label: {
            Image(systemName: "archivebox")
                .font(.system(size: 7.5, weight: .heavy))
                .foregroundStyle(.white.opacity(0.75))
                .frame(width: 17, height: 17)
                .background(Circle().fill(Color.white.opacity(0.12)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("📦 เสร็จแล้ว (\(model.archived.count)) — คลิกเพื่อดึงโปรเจกต์กลับ")
    }

    @ViewBuilder
    private var archiveBoxItems: some View {
        Text("📦 เสร็จแล้ว — เลือกเพื่อดึงกลับ")
        ForEach(model.archived) { a in
            Button("↩︎ \(a.name) · MVP \(a.mvp)%") { model.setFinished(false, for: a.name) }
        }
    }

    /// MVP 100% → archive at once; otherwise confirm first (right-click path).
    private func archive(_ p: FinishEngineProject) {
        if p.mvp < 100 {
            let alert = NSAlert()
            alert.messageText = "เก็บ \(p.name) เข้าคลัง?"
            alert.informativeText = "MVP ยังอยู่ที่ \(p.mvp)% — โปรเจกต์จะหายจากแผง (ดึงกลับได้จาก 📦 เสร็จแล้ว)"
            alert.addButton(withTitle: "ยกเลิก")
            alert.addButton(withTitle: "เก็บเข้าคลัง")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertSecondButtonReturn else { return }
        }
        model.setFinished(true, for: p.name)
    }

    private func archiveChip(_ p: FinishEngineProject) -> some View {
        Button { archive(p) } label: {
            Text("📦 เก็บ")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .frame(minHeight: 30)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Self.done.opacity(0.28)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("MVP ครบแล้ว — เก็บเข้าคลัง (ดึงกลับได้จาก 📦)")
    }

    private func smallIcon(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 7.5, weight: .heavy))
                .foregroundStyle(.white.opacity(0.75))
                .frame(width: 17, height: 17)
                .background(Circle().fill(Color.white.opacity(0.12)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var placeholder: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Finish Engine")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Self.ring)
                Spacer()
                toolbar
            }
            if let code = model.errorCode {
                Text(FinishEngineModel.message(for: code))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Self.blocked)
            } else {
                Text(model.lastSync == nil ? "กำลังดึงโปรเจกต์…" : "ยังไม่มีโปรเจกต์ที่เลือก")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                Text(model.lastSync == nil
                     ? "รอสักครู่ ข้อมูลจะปรากฏตรงนี้"
                     : "ตรวจ Show และ เสร็จแล้ว ในตาราง Widget Display")
                    .font(.system(size: 9.5))
                    .foregroundStyle(subInk)
            }
        }
    }

    private func progressBar(_ value: Int, color: Color) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.14))
                Capsule()
                    .fill(color)
                    .frame(width: max(4, geo.size.width * CGFloat(min(max(value, 0), 100)) / 100))
            }
        }
        .frame(height: 4)
    }

    // MARK: Chips

    private func chipBackground(_ opacity: Double = 0.10) -> some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(Color.white.opacity(opacity))
    }

    private func aiChip(_ p: FinishEngineProject) -> some View {
        Menu {
            ForEach(FinishEngineAI.allCases, id: \.self) { ai in
                Button {
                    model.setAI(ai, for: p.name)
                } label: {
                    if ai == p.ai {
                        Label(ai.rawValue, systemImage: "checkmark")
                    } else {
                        Text(ai.rawValue)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Circle().fill(aiColor(p.ai)).frame(width: 5, height: 5)
                Text(shortAI(p.ai))
            }
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 7)
            .frame(height: 30)
            .background(chipBackground())
        }
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("AI ที่ปุ่ม ทำต่อ จะเปิด — คลิกเพื่อสลับ")
    }

    private func painChip(_ count: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Pain")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(subInk)
            Text("\(count)")
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(count > 0 ? Self.blocked : .white)
                .monospacedDigit()
        }
        .padding(.horizontal, 7)
        .frame(minWidth: 34, minHeight: 30, alignment: .leading)
        .background(chipBackground())
        .help("Pain Log ที่ยังไม่ Fixed ของโปรเจกต์นี้")
    }

    private func continueChip(_ p: FinishEngineProject, task: FinishEngineTask?) -> some View {
        Button {
            if let task {
                model.claimAndContinue(project: p.name, ai: p.ai, task: task, onContinue: showCopied)
            } else {
                FinishEngineModel.continueInChat(project: p.name, ai: p.ai, context: p)
                showCopied()
            }
        } label: {
            HStack(spacing: 3) {
                Text(copiedAt == nil ? "ทำต่อ" : "⌘V วาง")
                if copiedAt == nil {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 8, weight: .bold))
                }
            }
            .font(.system(size: 10.5, weight: .bold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .frame(maxWidth: .infinity, minHeight: 30)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.white.opacity(0.20))
                    .overlay(GlassRim(shape: RoundedRectangle(cornerRadius: 9, style: .continuous), strength: 0.7))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(copiedAt == nil
              ? "คัดลอกคำสั่ง แล้วเปิด \(p.ai.rawValue) ของ \(p.name) — วางด้วย ⌘V"
              : "คัดลอกแล้ว วางในแชทด้วย ⌘V")
    }

    private func showCopied() {
        copiedAt = Date()
        let stamp = copiedAt
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            if copiedAt == stamp { copiedAt = nil }
        }
    }

    // MARK: Flow (remaining MVP tasks + footer)

    private var flow: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let code = model.errorCode {
                errorBanner(code)
            }
            if let p = selected {
                HStack {
                    Text("งาน MVP ที่เหลือ · \(p.name)")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Spacer()
                    Text("\(FinishEngineModel.weightText(p.doneWeight))/\(FinishEngineModel.weightText(p.mvpWeight)) W")
                        .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(subInk)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.white.opacity(0.08)))
                }
                if p.remaining.isEmpty {
                    Label("ไม่มีงาน MVP ค้าง", systemImage: "checkmark.seal.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(subInk)
                } else {
                    ScrollView(.vertical) {
                        VStack(spacing: 5) {
                            ForEach(Array(p.remaining.enumerated()), id: \.element.id) { index, task in
                                taskRow(task, project: p, isNext: index == 0)
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                    .frame(maxHeight: 200)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            footer
        }
    }

    private func taskRow(_ task: FinishEngineTask, project: FinishEngineProject, isNext: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
        return HStack(alignment: .center, spacing: 8) {
            Capsule()
                .fill(isNext ? Self.ring : Color.white.opacity(0.22))
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(task.task)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                Text(statusLine(task))
                    .font(.system(size: 9))
                    .foregroundStyle(subInk)
                if !task.blocker.isEmpty {
                    Text("ติดอยู่ที่: \(task.blocker)")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Self.blocked)
                        .lineLimit(2)
                        .help(task.blocker)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                model.claimAndContinue(project: project.name, ai: project.ai, task: task, onContinue: showCopied)
            } label: {
                HStack(spacing: 3) {
                    Text("ทำต่อ")
                    Image(systemName: "arrow.up.right").font(.system(size: 7.5, weight: .heavy))
                }
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(isNext ? .white : Self.ring)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Capsule().fill(isNext ? Self.ring.opacity(0.55) : Self.ring.opacity(0.16)))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("คัดลอกคำสั่งงานนี้ แล้วเปิด \(project.ai.rawValue)")
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(8)
        .background(shape.fill(isNext ? Self.ring.opacity(0.14) : Color.white.opacity(0.06)))
    }

    private func statusLine(_ task: FinishEngineTask) -> String {
        let status = FinishEngineModel.statusTH[task.status] ?? task.status
        var line = "\(status) · W\(FinishEngineModel.weightText(task.weight))"
        if let holder = task.holder, let heldAt = task.heldAt {
            line += " · \(holder) \(FinishEngineModel.clock(heldAt))"
        }
        return line
    }

    /// Open pains of the project shown on the right — same number as its Pain chip.
    private var selectedPains: Int {
        guard let p = selected else { return 0 }
        return model.painsByProject[p.name] ?? 0
    }

    private var footer: some View {
        VStack(spacing: 7) {
            HStack(spacing: 5) {
                statChip("exclamationmark.bubble", "Pain Log \(selectedPains) ค้าง")
                statChip(evolveReady ? "sparkles" : "bolt.fill", evolveReady ? "EVOLVE พร้อม" : "MVP กำลังเดิน",
                         tint: evolveReady ? Self.done : nil)
                Spacer(minLength: 0)
            }
            Button(action: talkToFinishEngine) {
                HStack(spacing: 7) {
                    Image(systemName: "bubble.left.and.text.bubble.right.fill")
                        .foregroundStyle(Self.ring)
                    Text("คุยกับ Finish Engine")
                        .foregroundStyle(.white)
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(subInk)
                }
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 11)
                .frame(height: 32)
                .background(chipBackground(0.08))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("เปิด AI ของ Finish Engine เพื่อสั่งแก้งานหรือถามสถานะ")
            HStack(spacing: 5) {
                Circle().fill(model.errorCode == nil ? Color.green : Self.blocked)
                    .frame(width: 5, height: 5)
                Text(syncText)
                Button {
                    model.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 8.5, weight: .bold))
                        .rotationEffect(.degrees(model.isLoading ? 180 : 0))
                        .animation(model.isLoading ? .linear(duration: 0.6).repeatForever(autoreverses: false) : .default,
                                   value: model.isLoading)
                }
                .buttonStyle(.plain)
                .disabled(model.isLoading)
                .help("ดึงข้อมูลใหม่จาก Notion")
                Spacer()
                Image(systemName: "hand.draw")
                Text("ลากการ์ดเพื่อย้าย")
            }
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(faintInk)
            .padding(.horizontal, 3)
        }
    }

    private func statChip(_ symbol: String, _ text: String, tint: Color? = nil) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 8, weight: .bold))
            Text(text)
        }
        .font(.system(size: 9.5, weight: .semibold))
        .foregroundStyle(tint ?? subInk)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.black.opacity(0.28)))
    }

    private var evolveReady: Bool { model.projects.contains(where: { $0.mvp == 100 }) }

    private var syncText: String {
        if model.isLoading && model.lastSync == nil { return "กำลังดึงข้อมูล…" }
        guard let date = model.lastSync else { return "ยังไม่เคยอัปเดต" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "th_TH")
        formatter.dateFormat = "HH:mm"
        return "อัปเดต \(formatter.string(from: date))"
    }

    private func errorBanner(_ code: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(Self.blocked)
            VStack(alignment: .leading, spacing: 2) {
                Text(FinishEngineModel.message(for: code))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                if !model.projects.isEmpty {
                    Text("กำลังแสดงข้อมูลที่ดึงได้ล่าสุด")
                        .font(.system(size: 9))
                        .foregroundStyle(subInk)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Self.blocked.opacity(0.14)))
    }

    // MARK: Status + menu

    @ViewBuilder
    private var statusDot: some View {
        if let code = model.errorCode {
            Circle()
                .fill(Self.blocked)
                .frame(width: 6, height: 6)
                .shadow(color: Self.blocked.opacity(0.7), radius: 3)
                .padding(9)
                .help(FinishEngineModel.message(for: code))
        }
    }

    @ViewBuilder
    private var contextItems: some View {
        Button("รีเฟรช") { model.refresh() }
        Button(flowOpen ? "ซ่อนรายการงาน" : "ดูงาน MVP ที่เหลือ") { flowOpen.toggle() }
        Button("ย่อเป็นแถบเล็ก") { compact = true }
        Button("คุยกับ Finish Engine", action: talkToFinishEngine)
        if !model.archived.isEmpty {
            Menu("📦 เสร็จแล้ว (\(model.archived.count))") { archiveBoxItems }
        }
        if let onClose {
            Divider()
            Button("ซ่อน (⌃⌥⌘F)", action: onClose)
        }
    }

    private func talkToFinishEngine() {
        let ai = model.projects.first(where: { $0.name == "Finish Engine" })?.ai ?? .claude
        FinishEngineModel.continueInChat(project: "Finish Engine", ai: ai)
    }

    // MARK: Colors

    private func ringColor(_ p: FinishEngineProject) -> Color {
        if p.mvp >= 100 { return Self.done }
        if let b = p.remaining.first?.blocker, !b.isEmpty { return Self.blocked }
        return Self.ring
    }

    private func shortAI(_ ai: FinishEngineAI) -> String {
        ai == .chatgpt ? "GPT" : ai.rawValue
    }

    private func aiColor(_ ai: FinishEngineAI) -> Color {
        switch ai {
        case .claude: return Color(red: 0.96, green: 0.62, blue: 0.48)
        case .chatgpt: return Color(red: 0.42, green: 0.86, blue: 0.66)
        case .codex: return Color(red: 0.40, green: 0.68, blue: 1.0)
        case .gemini: return Color(red: 0.55, green: 0.66, blue: 1.0)
        }
    }
}

import AppKit
import SwiftUI

/// The Finish Engine box (design C in finish-engine-redesign/mockups.html):
/// search bar, every project on the left, the selected project's next step
/// on the right, key hints at the bottom. Sizes follow the mockup; colours
/// are system colours and materials so light and dark mode both work.
struct FinishEngineSpotlightView: View {
    @ObservedObject var model: FinishEngineModel
    @ObservedObject var state: FinishEngineSpotlightState
    @FocusState private var focus: FinishEngineSpotlightState.Field?

    private typealias Row = FinishEngineSpotlightState.Row

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            HStack(spacing: 0) {
                list
                    .frame(width: 300)
                Rectangle()
                    .fill(Palette.separator)
                    .frame(width: 0.5)
                detail
                    .padding(.horizontal, 22)
                    .padding(.vertical, 18)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(height: 300)
            footer
        }
        .frame(width: FinishEngineSpotlight.size.width, height: FinishEngineSpotlight.size.height)
        .background(SpotlightMaterial())
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Palette.rim, lineWidth: 0.5)
        )
        .scaleEffect(state.appeared ? 1 : 0.97)
        .onChange(of: state.focusToken) { _, _ in focus = state.focusTarget }
        .onChange(of: focus) { _, field in state.focusedField = field }
    }

    // MARK: Search bar

    private var searchBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.tertiary)
            // The prompt needs its own style: left alone, SwiftUI draws it
            // almost as dark as typed text.
            TextField(
                "",
                text: Binding(get: { state.query }, set: { state.setQuery($0) }),
                prompt: Text(state.createMode ? "ตั้งชื่อโปรเจกต์ใหม่…" : "พิมพ์ชื่อโปรเจกต์ หรือสร้างใหม่…")
                    .foregroundStyle(.tertiary)
            )
            .textFieldStyle(.plain)
            .font(.system(size: 20, weight: .medium))
            .focused($focus, equals: .search)
            if let hint = guessHint {
                Text(hint)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                    .help("เลือกโปรเจกต์นี้ไว้ให้ เพราะชื่ออยู่ใน\(state.guess?.source == .chat ? "แชต" : "หน้าต่าง")ที่เปิดอยู่: \(state.guess?.title ?? "")")
            }
            Text("⌃⌥⌘F")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.tertiary)
                .fixedSize()
        }
        .padding(.horizontal, 20)
        .frame(height: 58)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.separator).frame(height: 0.5)
        }
    }

    /// "✦ เดาจากแชต: …" while the guessed project is still the one shown.
    private var guessHint: String? {
        guard state.query.isEmpty, !state.createMode, let guess = state.guess,
              state.current == .project(guess.project) else { return nil }
        let from = guess.source == .chat ? "เดาจากแชต" : "เดาจากหน้าต่าง"
        return "✦ \(from): \(FinishEngineBoard.shortened(guess.title, to: 30))"
    }

    // MARK: Project list

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(spacing: 2) {
                    ForEach(state.visibleProjects) { project in
                        projectRow(project, selected: state.current == .project(project.name))
                            .id(Row.project(project.name))
                    }
                    if state.showsCreateRow {
                        createRow(selected: state.current == .create)
                            .id(Row.create)
                    }
                    if model.projects.isEmpty {
                        emptyList
                    }
                }
                .padding(8)
            }
            .scrollIndicators(.automatic)
            .onChange(of: state.current) { _, row in
                if let row { proxy.scrollTo(row) }
            }
            // A guessed or remembered project further down the list.
            .onChange(of: state.appeared) { _, appeared in
                if appeared, let row = state.current { proxy.scrollTo(row, anchor: .center) }
            }
        }
    }

    private func projectRow(_ project: FinishEngineProject, selected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Circle()
                    .fill(selected ? Color.white : Palette.dot(project.name))
                    .frame(width: 8, height: 8)
                Text(project.displayName)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(selected ? Color.white : Color.primary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                badge(project, selected: selected)
            }
            Text(secondLine(project))
                .font(.system(size: 12))
                .foregroundStyle(selected ? Color.white.opacity(0.82) : Color.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.leading, 16)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selected ? Color.accentColor : Color.clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture { state.click(.project(project.name)) }
    }

    @ViewBuilder
    private func badge(_ project: FinishEngineProject, selected: Bool) -> some View {
        let font = Font.system(size: 11.5, weight: .semibold)
        if project.isComplete {
            Text("ครบแล้ว")
                .font(font)
                .foregroundStyle(selected ? Color.white.opacity(0.82) : Palette.green)
        } else if let days = project.staleDays() {
            Text("นิ่ง \(days) วัน")
                .font(font)
                .foregroundStyle(selected ? Color.white.opacity(0.9) : Palette.amber)
        } else if project.totalCount > 0 {
            Text("\(project.doneCount)/\(project.totalCount)")
                .font(font)
                .monospacedDigit()
                .foregroundStyle(selected ? Color.white.opacity(0.82) : Color.secondary)
        }
    }

    private func secondLine(_ project: FinishEngineProject) -> String {
        if let next = project.nextTask { return next.task }
        return project.isComplete ? "ทำครบทุกขั้นแล้ว" : "ยังไม่มีงาน"
    }

    private func createRow(selected: Bool) -> some View {
        let name = state.trimmedQuery
        return HStack(spacing: 8) {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .bold))
                .frame(width: 8)
            Text(name.isEmpty ? "สร้างโปรเจกต์ใหม่" : "สร้างโปรเจกต์ “\(name)”")
                .font(.system(size: 13.5, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            if selected {
                Text("⏎")
                    .font(.system(size: 11, weight: .bold))
                    .opacity(0.9)
            }
        }
        .foregroundStyle(selected ? Color.white : Color.accentColor)
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selected ? Color.accentColor : Color.clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture { state.click(.create) }
    }

    @ViewBuilder
    private var emptyList: some View {
        VStack(spacing: 8) {
            if model.isLoading {
                ProgressView().controlSize(.small)
                Text("กำลังโหลดจาก Notion…")
            } else {
                Text("ยังไม่มีโปรเจกต์")
                Text("กด ⌘N เพื่อสร้าง")
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        switch state.current {
        case .create?:
            createForm
        case .project(let name)?:
            if let project = model.projects.first(where: { $0.name == name }) {
                if let task = project.nextTask {
                    // Long titles and notes give way, least important first,
                    // so the buttons never fall off the card.
                    ViewThatFits(in: .vertical) {
                        taskDetail(project, task, titleLines: 3, noteLines: 2)
                        taskDetail(project, task, titleLines: 3, noteLines: 1)
                        taskDetail(project, task, titleLines: 3, noteLines: 0)
                        taskDetail(project, task, titleLines: 2, noteLines: 0)
                    }
                } else {
                    emptyDetail(project)
                }
            }
        case nil:
            EmptyView()
        }
    }

    private func projectHeader(_ project: FinishEngineProject) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Palette.dot(project.name))
                    .frame(width: 8, height: 8)
                Text(project.displayName)
                    .font(.system(size: 13, weight: .bold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if project.totalCount > 0 {
                    Text("เสร็จ \(project.doneCount) จาก \(project.totalCount)")
                        .font(.system(size: 12, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            if project.totalCount > 0 {
                ProgressBar(fraction: Double(project.doneCount) / Double(project.totalCount))
                    .padding(.top, 10)
            }
        }
    }

    private func taskDetail(_ project: FinishEngineProject, _ task: FinishEngineTask,
                            titleLines: Int, noteLines: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            projectHeader(project)
            Text("ขั้นต่อไป")
                .font(.system(size: 11.5, weight: .bold))
                .foregroundStyle(Color.accentColor)
                .padding(.top, 14)
            Text(task.task)
                .font(.system(size: 19, weight: .semibold))
                .lineSpacing(2)
                .lineLimit(titleLines)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 3)
            meta(task)
                .padding(.top, 6)
            // Blocker is in practice the latest progress note, so it reads
            // as plain secondary text — never a warning colour.
            if noteLines > 0, !task.blocker.isEmpty {
                Text("ล่าสุด: \(task.blocker)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(noteLines)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            }
            HStack(spacing: 8) {
                SplitButton(
                    title: state.isLaunching ? "กำลังเปิด \(project.ai.rawValue)…" : "ทำต่อกับ \(project.ai.rawValue)",
                    current: project.ai,
                    action: { state.continueWork(project, task) },
                    pick: { model.setAI($0, for: project.name) }
                )
                .help("คัดลอกคำสั่งให้ แล้วเปิด \(project.ai.rawValue) — วางในแชตด้วย ⌘V")
                Button { state.markDone() } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 38, height: 32)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Palette.fill)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
                .help("เสร็จแล้ว (⌘D) — ย้อนกลับได้ใน 5 วินาที")
            }
            .padding(.top, 13)
            if project.remaining.count > 1 {
                HStack(spacing: 6) {
                    Text("ถัดไป")
                        .foregroundStyle(.secondary)
                    Text(project.remaining[1].task)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .font(.system(size: 12))
                .padding(.top, 12)
            }
        }
    }

    /// "● Claude กำลังทำ · เริ่ม 22:02" or "ยังไม่เริ่ม".
    private func meta(_ task: FinishEngineTask) -> some View {
        let doing = task.status == "Doing"
        var text = "ยังไม่เริ่ม"
        if doing {
            text = task.holder.map { "\($0) กำลังทำ" } ?? "กำลังทำ"
            if let heldAt = task.heldAt { text += " · เริ่ม \(FinishEngineModel.clock(heldAt))" }
        }
        return HStack(spacing: 6) {
            Circle()
                .fill(doing ? Palette.ai(task.holder.flatMap { FinishEngineAI(notion: $0) }) : Palette.idle)
                .frame(width: 7, height: 7)
            Text(text)
                .lineLimit(1)
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
    }

    /// Nothing open (new or finished project): the AI drafts the steps.
    private func emptyDetail(_ project: FinishEngineProject) -> some View {
        let unsaved = state.unsavedSteps[project.name]
        return VStack(alignment: .leading, spacing: 0) {
            projectHeader(project)
            Text("ยังไม่มีงาน")
                .font(.system(size: 19, weight: .semibold))
                .padding(.top, 18)
            if unsaved == nil {
                Text(project.isComplete
                     ? "ทำครบ \(project.doneCount) ขั้นแล้ว ให้ AI ช่วยคิดขั้นต่อไป พร้อมเกณฑ์เสร็จ แล้วบันทึกลง Finish Engine"
                     : "ให้ AI แบ่งโปรเจกต์นี้เป็น 3–5 ขั้นแรก พร้อมเกณฑ์เสร็จ แล้วบันทึกลง Finish Engine ให้")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
            SplitButton(
                title: project.isComplete ? "ให้ AI วางแผนขั้นต่อไป" : "ให้ AI วางแผนขั้นแรก",
                current: project.ai,
                action: { state.planFirstSteps(project) },
                pick: { model.setAI($0, for: project.name) }
            )
            .help("คัดลอกคำสั่งวางแผน แล้วเปิด \(project.ai.rawValue) — วางในแชตด้วย ⌘V")
            .padding(.top, 14)
            if let unsaved {
                unsavedStep(project, unsaved)
                    .padding(.top, 14)
            } else {
                Text("คัดลอกคำสั่งไว้ให้ แล้วเปิด \(project.ai.rawValue) · วางด้วย ⌘V")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 6)
            }
        }
    }

    /// Notion refused the first step (no Insert content yet): keep it and
    /// offer the fix plus a retry.
    private func unsavedStep(_ project: FinishEngineProject,
                             _ unsaved: FinishEngineSpotlightState.UnsavedStep) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text(unsaved.message)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .font(.system(size: 12))
            .foregroundStyle(Palette.amber)
            Text("ขั้นแรกที่พิมพ์ไว้: \(unsaved.step)")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack(spacing: 8) {
                Button("เปิดหน้าสิทธิ์ใน Notion") {
                    if let url = URL(string: "https://www.notion.so/profile/integrations") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Button(state.isCreating ? "กำลังบันทึก…" : "บันทึกอีกครั้ง") {
                    state.retryStep(for: project.name)
                }
                .disabled(state.isCreating)
            }
            .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.fill2))
    }

    // MARK: Create

    private var createForm: some View {
        let name = state.trimmedQuery
        let problem = state.createProblem
            ?? (name.isEmpty ? nil : FinishEngineBoard.problem(withNewName: name, existing: model.projects))
        let stepFocused = focus == .step
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(Color.accentColor)
                Text("โปรเจกต์ใหม่")
                    .font(.system(size: 13, weight: .bold))
            }
            Text(name.isEmpty ? "พิมพ์ชื่อในช่องค้นหาด้านบน" : name)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(name.isEmpty ? Color.secondary : Color.primary)
                .lineLimit(2)
                .padding(.top, 14)
            Text("ขั้นแรกคืออะไร (ไม่ใส่ก็ได้)")
                .font(.system(size: 11.5, weight: .bold))
                .foregroundStyle(.secondary)
                .padding(.top, 16)
            TextField("", text: $state.stepText,
                      prompt: Text("เช่น สรุป Brand DNA จากคลาส อ.ไอ๋").foregroundStyle(.tertiary))
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focus, equals: .step)
                .padding(.horizontal, 9)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Palette.field))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(stepFocused ? Color.accentColor.opacity(0.6) : Palette.fieldBorder,
                                      lineWidth: stepFocused ? 1.5 : 0.5)
                )
                .padding(.top, 6)
            HStack(alignment: .center, spacing: 8) {
                Group {
                    if let problem {
                        Text(problem).foregroundStyle(Palette.amber)
                    } else {
                        Text(stepFocused ? "กด ⏎ เพื่อสร้าง" : "กด ⏎ ไปช่องขั้นแรก")
                            .foregroundStyle(.tertiary)
                    }
                }
                .font(.system(size: 11.5))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button { state.create() } label: {
                    Group {
                        if state.isCreating {
                            ProgressView().controlSize(.small).tint(.white)
                        } else {
                            Text("สร้าง")
                        }
                    }
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(minWidth: 72, minHeight: 28)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.accentColor))
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
                .disabled(name.isEmpty || problem != nil || state.isCreating)
                .opacity(name.isEmpty || problem != nil ? 0.5 : 1)
            }
            .padding(.top, 10)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 16) {
            if let undo = state.undo {
                undoBar(undo)
            } else {
                KeyHint(key: "⏎", label: primaryHint)
                KeyHint(key: "⌘N", label: "โปรเจกต์ใหม่")
                KeyHint(key: "⌘D", label: "เสร็จแล้ว")
            }
            Spacer(minLength: 8)
            if let code = model.errorCode {
                let message = FinishEngineModel.message(for: code)
                Button { model.refresh() } label: {
                    Label {
                        Text(message).lineLimit(1).truncationMode(.tail)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .foregroundStyle(Palette.amber)
                }
                .buttonStyle(.plain)
                .help("\(message) · คลิกเพื่อลองใหม่")
            }
            KeyHint(key: "esc", label: "ปิด")
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 18)
        .frame(height: 38)
        .background(Palette.footer)
        .overlay(alignment: .top) {
            Rectangle().fill(Palette.separator).frame(height: 0.5)
        }
    }

    /// What ⏎ does right now.
    private var primaryHint: String {
        switch state.current {
        case .create?:
            return focus == .step ? "สร้าง" : "ใส่ขั้นแรก"
        case .project(_)?:
            return state.currentProject?.nextTask == nil ? "วางแผน" : "ทำต่อ"
        case nil:
            return "ทำต่อ"
        }
    }

    private func undoBar(_ undo: FinishEngineSpotlightState.Undo) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Palette.green)
            Text("เสร็จแล้ว: \(undo.task.task)")
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
            Button("ย้อนกลับ") { state.undoDone() }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .fixedSize()
                .help("ย้อนสถานะงานนี้กลับ (⌘Z)")
        }
    }
}

// MARK: - Pieces

/// "ทำต่อกับ Claude ⌄": the whole width runs the action; the chevron
/// segment picks another AI (Widget Display.AI, or on this Mac for a project
/// without a row).
private struct SplitButton: View {
    let title: String
    let current: FinishEngineAI
    let action: () -> Void
    let pick: (FinishEngineAI) -> Void

    private static let chevronWidth: CGFloat = 30

    var body: some View {
        HStack(spacing: 0) {
            Button(action: action) {
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .lineLimit(1)
                    // Centre the title on the whole button, as in the mockup.
                    .padding(.leading, Self.chevronWidth + 1)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle())
            Rectangle()
                .fill(Color.white.opacity(0.35))
                .frame(width: 1, height: 18)
            Button(action: showMenu) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: Self.chevronWidth)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle())
            .help("เปลี่ยน AI ที่ใช้ทำต่อ")
        }
        .foregroundStyle(.white)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.accentColor))
        .shadow(color: .black.opacity(0.12), radius: 1, y: 1)
    }

    /// A plain AppKit menu at the pointer: SwiftUI's Menu restyles its label
    /// on macOS, which would break the white-on-accent button.
    private func showMenu() {
        let menu = NSMenu()
        for ai in FinishEngineAI.allCases {
            let item = ClosureMenuItem(title: ai.rawValue) { pick(ai) }
            item.state = ai == current ? .on : .off
            item.image = Palette.menuDot(for: ai)
            menu.addItem(item)
        }
        _ = menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func fire() {
        handler()
    }
}

private struct KeyHint: View {
    let key: String
    let label: String

    var body: some View {
        HStack(spacing: 5) {
            Text(key)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 5)
                .frame(minWidth: 20, minHeight: 18)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Palette.fill))
            Text(label)
        }
        .fixedSize()
    }
}

private struct ProgressBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.fill)
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: geometry.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: 4)
    }
}

private struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.72 : 1)
    }
}

/// Behind-window blur like Spotlight's. Forced active: the panel never
/// activates StampLab, and an inactive material turns flat grey.
private struct SpotlightMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// Colours from the mockup mapped to system colours (light + dark).
private enum Palette {
    static let separator = Color(nsColor: .separatorColor)
    static let fill = Color(nsColor: .tertiarySystemFill)
    static let fill2 = Color(nsColor: .quaternarySystemFill)
    static let field = Color(nsColor: .textBackgroundColor)
    static let green = Color(nsColor: .systemGreen)
    static let idle = Color(nsColor: .tertiaryLabelColor)
    static let rim = dynamic(light: NSColor.black.withAlphaComponent(0.14), dark: NSColor.white.withAlphaComponent(0.16))
    static let fieldBorder = dynamic(light: NSColor.black.withAlphaComponent(0.16), dark: NSColor.white.withAlphaComponent(0.18))
    static let footer = dynamic(light: NSColor.white.withAlphaComponent(0.4), dark: NSColor.white.withAlphaComponent(0.03))
    static let amber = dynamic(light: NSColor(srgbRed: 0.725, green: 0.467, blue: 0.055, alpha: 1),
                               dark: NSColor(srgbRed: 1.0, green: 0.74, blue: 0.32, alpha: 1))

    /// The four tracker projects keep the mockup's colours; any other gets a
    /// palette colour that stays the same on every launch.
    private static let known: [String: Color] = [
        "AI OS": .indigo, "OverlayLens": .orange, "Slidegen": .pink, "Finish Engine": .teal,
    ]
    private static let palette: [Color] = [.blue, .green, .purple, .yellow, .mint, .red, .brown, .cyan]

    static func dot(_ project: String) -> Color {
        known[project] ?? palette[FinishEngineBoard.colorIndex(for: project, paletteCount: palette.count)]
    }

    static func ai(_ ai: FinishEngineAI?) -> Color {
        Color(nsColor: aiColor(ai))
    }

    private static func aiColor(_ ai: FinishEngineAI?) -> NSColor {
        switch ai {
        case .claude?: return NSColor(srgbRed: 0.851, green: 0.467, blue: 0.341, alpha: 1)
        case .codex?: return NSColor(srgbRed: 0.294, green: 0.482, blue: 0.961, alpha: 1)
        case .chatgpt?: return NSColor(srgbRed: 0.063, green: 0.639, blue: 0.498, alpha: 1)
        case .gemini?: return NSColor(srgbRed: 0.545, green: 0.486, blue: 0.965, alpha: 1)
        case nil: return .controlAccentColor
        }
    }

    /// Small coloured dot for the AI menu items.
    static func menuDot(for ai: FinishEngineAI) -> NSImage {
        let image = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
            aiColor(ai).setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
        return image
    }

    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
}

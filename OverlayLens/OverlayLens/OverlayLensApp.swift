import SwiftUI

@main
struct OverlayLensApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// No `MenuBarExtra` here: `MenuBarController` owns the single status item
    /// (see AppDelegate) so the lens controls and the Drop Shelf share one
    /// menu bar slot instead of taking one each.
    var body: some Scene {
        Settings { EmptyView() }
            .commands {
                CommandMenu("แปลภาษา") {
                    Button("แปลจากหน้าจอ") { appDelegate.translateScreen() }
                    Button("คัดลอกข้อความจากจอ") { appDelegate.copyTextFromScreen() }
                }
            }
    }
}

/// Quick controls shown when clicking the menu bar icon: lens on/off toggle,
/// glass opacity slider, and Quit.
struct MenuBarControlsView: View {
    @ObservedObject var viewModel: OverlayViewModel
    @ObservedObject var shelfModel: DropShelfModel
    /// Feeds the Finish Engine row (current project + next step).
    @ObservedObject var finishModel: FinishEngineModel
    var onToggleStats: (() -> Void)? = nil
    var onToggleConnections: (() -> Void)? = nil
    var onOpenDropShelf: (() -> Void)? = nil
    var onToggleFinishEngine: (() -> Void)? = nil
    @ObservedObject var meetingModel: MeetingRecorderModel
    var onToggleMeeting: (() -> Void)? = nil
    var onTranslateScreen: (() -> Void)? = nil
    var onCopyTextFromScreen: (() -> Void)? = nil
    var onPreviewAmbient: (() -> Void)? = nil
    @State private var showsSettings = false
    @AppStorage(ShakeToShelf.defaultsKey) private var shakeToShelf = true
    @AppStorage(ClaudeAmbientController.enabledKey) private var claudeAmbientOn = true
    @State private var slidegenOn = SlidegenSwitch.isOn
    @State private var approvalsOn = ClaudeApproval.isEnabled
    @State private var autopilotOn = ClaudeAutopilot.isOn
    /// Rules saved with "อนุญาตเสมอ" on an approval card.
    @ObservedObject private var approvalRules = ClaudeApprovalRules.shared
    @State private var launchAtLogin = LaunchAtLogin.isOn
    @State private var loginNeedsApproval = LaunchAtLogin.needsApproval
    /// Last project picked in the Finish Engine box; the row follows it.
    @AppStorage(FinishEngineModel.selectedKey) private var finishSelected = ""

    /// Every row has the same shape (MenuRow.swift): grey icon, one-line title,
    /// a shortcut or a switch. Two groups — what's being worked on, then the
    /// tools — and a status line only when something needs attention.
    /// Explanations live in `.help` tooltips and in Settings.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            finishEngineRow
            QuotaMenuRow(onOpenSettings: { showsSettings = true })
            approvalRulesRow
            Divider().padding(.vertical, 6)
            translateRow
            dropShelfRow
            meetingRow
            slidegenRow
            Divider().padding(.vertical, 6)
            HStack {
                Button("การตั้งค่า…") { showsSettings = true }
                    .keyboardShortcut(",")
                Spacer()
                Button("ออก") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, MenuStyle.inset)
            .frame(minHeight: 26)
        }
        .font(.system(size: 13.5))
        .controlSize(.regular)
        .padding(10)
        .frame(width: 320)
        .sheet(isPresented: $showsSettings) { settingsView }
    }

    private var settingsView: some View {
        VStack(spacing: 0) {
            HStack {
                Text("การตั้งค่า StampLab").font(.headline)
                Spacer()
                Button("เสร็จสิ้น") { showsSettings = false }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)
            Divider()
            Form {
                Section("ทั่วไป") {
                    Toggle("เปิด StampLab เมื่อเริ่มเครื่อง", isOn: $launchAtLogin)
                        // May have been changed in System Settings meanwhile.
                        .onAppear {
                            launchAtLogin = LaunchAtLogin.isOn
                            loginNeedsApproval = LaunchAtLogin.needsApproval
                        }
                        .onChange(of: launchAtLogin) { _, on in
                            LaunchAtLogin.set(on: on)
                            loginNeedsApproval = LaunchAtLogin.needsApproval
                        }
                    if loginNeedsApproval {
                        Button("macOS ขอให้อนุญาตก่อน — เปิดหน้าตั้งค่า Login Items") {
                            LaunchAtLogin.openSystemSettings()
                        }
                    }
                }
                Section("การแปล") {
                    Toggle("ใช้ Google Translate ออนไลน์", isOn: $viewModel.useOnlineTranslation)
                    Text(viewModel.useOnlineTranslation
                         ? "ข้อความที่อ่านจากหน้าจอจะถูกส่งไป Google Translate หากบริการไม่พร้อม จะลองใช้ Apple Translation ในเครื่อง"
                         : "ใช้ Apple Translation ในเครื่อง ต้องมีภาษาที่รองรับและอาจต้องดาวน์โหลดชุดภาษาก่อน")
                        .font(.system(size: 12, weight: .regular)).foregroundStyle(.secondary)
                }
                Section("Drop Shelf") {
                    Toggle("เขย่าเมาส์ตอนลากไฟล์ เพื่อเปิด Shelf", isOn: $shakeToShelf)
                    Text("ลากไฟล์ รูป หรือลิงก์ค้างไว้ แล้วเขย่าเมาส์ซ้าย-ขวา Shelf จะเด้งขึ้นข้างเคอร์เซอร์ให้วางฝากไว้ก่อน")
                        .font(.system(size: 12, weight: .regular)).foregroundStyle(.secondary)
                }
                Section("อนุมัติคำขอของ Claude") {
                    Toggle("ตอบคำขอสิทธิ์ของ Claude Code จาก StampLab", isOn: $approvalsOn)
                        .onAppear { approvalsOn = ClaudeApproval.isEnabled }
                        .onChange(of: approvalsOn) { _, on in ClaudeApproval.setEnabled(on) }
                    Text("การ์ดมุมขวาบนบอกคำสั่งที่ Claude ขอทำ พร้อมปุ่ม ปฏิเสธ / อนุญาต และ อนุญาตเสมอ เมื่อคำสั่งนั้นตั้งเป็นกฎได้ หน้าต่างของ Claude ยังถามตามปกติ ฝั่งไหนตอบก่อนใช้ฝั่งนั้น")
                        .font(.system(size: 12, weight: .regular)).foregroundStyle(.secondary)
                    approvalRulesList
                    Toggle("ออโต้ไพลอต: ตัดสินคำขอสิทธิ์แทนฉัน", isOn: $autopilotOn)
                        .onAppear { autopilotOn = ClaudeAutopilot.isOn }
                        .onChange(of: autopilotOn) { _, on in ClaudeAutopilot.setOn(on) }
                    Text("ใช้คู่กับ Auto ของ Claude: อ่านอย่างเดียว = อนุญาต อย่างอื่น = ปฏิเสธพร้อมบอกเหตุผล ปฏิเสธติดกัน 3 ครั้ง = หยุดงานแล้วแจ้งเตือน ไม่มีการ์ดให้กด ปิดสวิตช์ = กลับไปใช้การ์ด")
                        .font(.system(size: 12, weight: .regular)).foregroundStyle(.secondary)
                    Button("ดูประวัติการตัดสินของออโต้ไพลอต") {
                        let url = ClaudeAutopilot.logURL
                        if !FileManager.default.fileExists(atPath: url.path) { try? Data().write(to: url) }
                        NSWorkspace.shared.open(url)
                    }
                }
                QuotaSettingsSection(projects: finishModel.projects.map(\.name))
                Section("หน้าจอพัก Claude") {
                    Toggle("แสดงมาสคอตแทนจอดับ ตอน Claude ทำงาน", isOn: $claudeAmbientOn)
                    Button("ดูตัวอย่างหน้าจอพัก") {
                        showsSettings = false
                        onPreviewAmbient?()
                    }
                    Text("ขึ้นเองเมื่อไม่ได้แตะเครื่องจนเกือบถึงเวลาจอดับ และ Claude ยังทำงานหรือรออนุมัติอยู่ ขยับเมาส์เพื่อปิด")
                        .font(.system(size: 12, weight: .regular)).foregroundStyle(.secondary)
                }
                Section("หน้าต่างคำแปล") {
                    slider("ขนาดข้อความ", value: $viewModel.textScale, range: 0.7...2.0)
                }
                Section("เปิดที่อยู่ไฟล์  ⌃⌥⌘O") {
                    Text("เลือกพาธในแอปไหนก็ได้ (รวมแชต Claude) แล้วกด ⌃⌥⌘O Finder จะเปิดไปที่นั่น ถ้าไม่ได้เลือก จะใช้ข้อความที่ Copy ไว้")
                        .font(.system(size: 12, weight: .regular)).foregroundStyle(.secondary)
                    if !RevealPath.canCopySelection {
                        Button("อนุญาต Accessibility ให้ StampLab (ใช้คัดลอกข้อความที่เลือก)") {
                            RevealPath.askForAccessibility()
                        }
                    }
                }
                Section("เครื่องมือเสริม") {
                if let onToggleStats {
                    widgetButton("CPU / RAM", systemImage: "gauge.with.dots.needle.33percent", action: onToggleStats)
                }
                if let onToggleConnections {
                    widgetButton("Claude", systemImage: "app.connected.to.app.below.fill", action: onToggleConnections)
                }
                    Text("Claude ใช้ดูการเชื่อมต่อ ไม่ได้ใช้แปลข้อความ")
                        .font(.system(size: 12, weight: .regular)).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        }
        .font(.system(size: 14, weight: .semibold))
        .controlSize(.regular)
        .frame(width: 460, height: 550)
    }

    private func slider(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>
    ) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int(value.wrappedValue * 100))%")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .font(.system(size: 14, weight: .semibold))
            Slider(value: value, in: range)
        }
    }

    private func widgetButton(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        }
        .help("แสดง/ซ่อนวิดเจ็ต")
    }

    /// Finish Engine sits on top of the menu so it gets seen; one click opens
    /// the box (⌃⌥⌘F) with every project's next step. The row names the
    /// current project only — the next step used to be cut off with "…".
    private var finishEngineRow: some View {
        MenuActionRow(icon: "flag.checkered", title: "Finish Engine", subtitle: finishSubtitle,
                      shortcut: "⌃⌥⌘F") { onToggleFinishEngine?() }
            .help(finishHelp)
    }

    /// The current project; while there's none yet, what's happening.
    private var finishSubtitle: String {
        if let project = finishModel.headline(selected: finishSelected.isEmpty ? nil : finishSelected) {
            return project.displayName
        }
        if finishModel.isLoading { return "กำลังโหลดจาก Notion…" }
        if let code = finishModel.errorCode { return FinishEngineModel.message(for: code) }
        return "ยังไม่มีโปรเจกต์"
    }

    /// The next step, a hover away.
    private var finishHelp: String {
        let box = "เปิดกล่อง Finish Engine: ขั้นต่อไปของทุกโปรเจกต์ · ทำต่อ · สร้างโปรเจกต์ใหม่"
        guard let project = finishModel.headline(selected: finishSelected.isEmpty ? nil : finishSelected),
              !project.next.isEmpty else { return box }
        return "ขั้นต่อไป: \(project.next)\n\(box)"
    }

    /// The translate lens, with the language direction folded into the row
    /// (it used to be a big blue button plus a separate ภาษา row).
    private var translateRow: some View {
        HStack(spacing: MenuStyle.spacing) {
            Button { onTranslateScreen?() } label: {
                HStack(spacing: MenuStyle.spacing) {
                    MenuIcon(name: "text.viewfinder")
                    MenuTitle(title: viewModel.isLensVisible ? "กำลังแปลบนจอ" : "แปลจากหน้าจอ")
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("ชี้แล้วคลิกข้อความ หรือลากครอบพื้นที่ที่ต้องการแปล · คัดลอกข้อความจากจอใช้ ⌥⌘G")
            Menu(viewModel.directionOverride.label) {
                Picker("ภาษา", selection: $viewModel.directionOverride) {
                    ForEach(DirectionOverride.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .font(.system(size: 12))
            .foregroundStyle(MenuStyle.secondary)
            .help("ทิศทางภาษา")
            MenuShortcut(keys: "⌥⌘T")
        }
        .modifier(MenuRowFrame())
    }

    /// The Drop Shelf lost its own menu bar icon when the two status items
    /// merged; this row (plus right-click on the icon, ⌥⌘D, or dragging files
    /// onto the icon) is how it opens now.
    private var dropShelfRow: some View {
        MenuActionRow(icon: "tray.and.arrow.down", title: "Drop Shelf", badge: shelfModel.items.count,
                      shortcut: "⌃⌥⌘D") { onOpenDropShelf?() }
            .help("ลากไฟล์/รูป/ลิงก์มาวางบนไอคอนเมนูบาร์ หรือคลิกขวาที่ไอคอน ก็เปิด Drop Shelf ได้")
    }

    /// Meeting recorder: floating card + ⌃⌥⌘R to start/stop from anywhere.
    private var meetingRow: some View {
        MenuActionRow(icon: meetingModel.isRecording ? "record.circle" : "waveform",
                      tint: meetingModel.isRecording ? .red : nil,
                      title: meetingModel.isRecording ? "กำลังบันทึก…" : "Meeting Notes",
                      shortcut: "⌃⌥⌘R") { onToggleMeeting?() }
            .help("อัดเสียงประชุม (Zoom/Teams/Discord/LINE/Meet) แล้วถอดเสียงไทย + สรุปให้อัตโนมัติ")
    }

    /// The rules kept from "อนุญาตเสมอ", newest first, each with its project
    /// and a ลบ that also takes it out of that project's settings file.
    @ViewBuilder private var approvalRulesList: some View {
        if approvalRules.rules.isEmpty {
            Text("ยังไม่มีกฎที่กด อนุญาตเสมอ ไว้ กฎที่กดจะมาอยู่ตรงนี้ ลบได้ทุกเมื่อ")
                .font(.system(size: 12, weight: .regular)).foregroundStyle(.secondary)
                .onAppear { approvalRules.reload() }
        } else {
            ForEach(approvalRules.rules) { entry in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.display)
                            .font(.system(size: 12.5, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(1).truncationMode(.middle)
                        Text(entry.projectName)
                            .font(.system(size: 11, weight: .regular)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button("ลบ") { approvalRules.forget(entry) }
                        .font(.system(size: 12, weight: .regular))
                        .help("เอากฎออกจาก \(ClaudeApproval.localSettingsURL(project: entry.project).path) แล้ว Claude Code จะกลับมาถามคำสั่งนี้อีก")
                }
            }
            .onAppear { approvalRules.reload() }
        }
    }

    /// Only when there is something to act on: the rules kept from
    /// "อนุญาตเสมอ" cards (nothing saved = the menu stays as short as it was).
    /// Managing them needs room for long rules, so the row counts them and the
    /// list with the ลบ buttons lives in Settings. MenuBarController refreshes
    /// the list as the popover opens.
    @ViewBuilder private var approvalRulesRow: some View {
        if !approvalRules.rules.isEmpty {
            MenuActionRow(icon: "checkmark.shield", title: "กฎอนุญาตเสมอ",
                          subtitle: approvalRules.rules.first?.display,
                          badge: approvalRules.rules.count,
                          shortcut: "") { showsSettings = true }
                .help("คำสั่งที่กด อนุญาตเสมอ ไว้ Claude Code จะไม่ถามอีก · กดเพื่อดูทั้งหมดและลบ")
        }
    }

    /// Local slide-image generator switch (see SlidegenSwitch). Off stops
    /// Claude/Codex from using it until switched back on.
    private var slidegenRow: some View {
        MenuControlRow(icon: "photo.stack", title: "Slidegen") {
            MenuSwitch(title: "Slidegen", isOn: $slidegenOn)
        }
        .onAppear { slidegenOn = SlidegenSwitch.isOn }
        .onChange(of: slidegenOn) { _, on in SlidegenSwitch.set(on: on) }
        .help("ปิด = Claude และ Codex ใช้ slidegen สร้างภาพสไลด์ในเครื่องไม่ได้ จนกว่าจะเปิดใหม่ (ถ้ากำลังวาดอยู่ ภาพที่วาดค้างจะเสร็จก่อนแล้วหยุด)")
    }

}

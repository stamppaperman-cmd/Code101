import SwiftUI

/// "ใช้โควตา Claude ให้คุ้ม" — one switch for the two quota features that used
/// to be separate menu rows:
/// - ทำต่ออัตโนมัติ (QuotaResume): a chat stopped by the usage limit waits and
///   continues at the reset, with the Mac kept awake on AC power until then.
/// - กะดึก (NightShiftController): at night, quota that would reset unused goes
///   to Finish Engine work in the projects the user allows.
/// On turns both on, off turns both off. Settings › โควตา Claude
/// (`QuotaSettingsSection`) holds each one separately plus their options.
struct QuotaMenuRow: View {
    @ObservedObject private var quota = QuotaResume.shared
    @ObservedObject private var shift = NightShiftController.shared
    var onOpenSettings: () -> Void

    private var isOn: Bool { quota.isOn || shift.config.enabled }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MenuControlRow(icon: "gauge.with.needle", title: "ใช้โควตา Claude ให้คุ้ม") {
                MenuSwitch(title: "ใช้โควตา Claude ให้คุ้ม", isOn: Binding(
                    get: { isOn },
                    set: { on in
                        quota.setOn(on)
                        shift.setEnabled(on)
                    }
                ))
            }
            status
        }
        .onAppear {
            quota.reload()
            shift.start()
        }
        .help("เปิด = แชตที่ชนโควตากลางงานจะรอแล้วทำต่อเองเมื่อรีเซ็ต และตอนกลางคืนกะดึกใช้โควตาที่เหลือ (ตามงบรายวัน เก็บ \(shift.config.reserve)% ไว้ให้คุณ) ทำงานในโปรเจกต์ที่เลือกไว้ · วันสุดท้ายก่อนรีเซ็ตจะถามคุณก่อน · ปรับได้ใน การตั้งค่า › โควตา Claude")
    }

    /// One line, only when there's something to act on: chats waiting for the
    /// reset, chats stuck past it (only while ทำต่ออัตโนมัติ is on — when it's
    /// off, a stopped chat waiting for the user is the expected outcome), a
    /// night shift that can't run, or last night's report.
    @ViewBuilder private var status: some View {
        if quota.isOn, let first = quota.waiting.min(by: { $0.deadline < $1.deadline }) {
            MenuStatus {
                Text("ค้าง \(quota.waiting.count) แชต · ทำต่อเอง \(QuotaResume.clock(first.resetAt))"
                     + (quota.holdingAwake ? " · กันเครื่องหลับอยู่" : ""))
            }
        } else if shift.config.enabled, !shift.routineInstalled || !shift.config.hasProjects {
            MenuStatus(warning: true) {
                Text(shift.routineInstalled ? "กะดึกยังไม่ได้เลือกโปรเจกต์" : "ยังไม่ได้ติดตั้ง Routine กะดึกในแอป Claude")
                Button("ตั้งค่า", action: onOpenSettings)
            }
        } else if shift.lastDayPending {
            MenuStatus {
                Text("วันสุดท้ายก่อนรีเซ็ต · วันนี้จะใช้ไหม?")
                Button("ทำงาน") { shift.answerLastDay(free: false) }
                Button("ไม่ทำ") { shift.answerLastDay(free: true) }
            }
        } else if quota.isOn, quota.stuck.contains(where: { Date().timeIntervalSince($0.deadline) < 12 * 3600 }) {
            // Older ones stay listed in Settings, where "ไม่ต้องรอ" clears them.
            MenuStatus(warning: true) {
                Text("แชตยังไม่ขยับหลังโควตารีเซ็ต")
                Button("เปิด Claude") { quota.openClaude() }
            }
        } else if let plan = shift.todayPlan {
            MenuStatus {
                Text(plan)
                if let report = shift.report, NightShiftController.isRecent(report) {
                    Button("รายงาน") { shift.openReport() }
                }
            }
        } else if let report = shift.report, NightShiftController.isRecent(report) {
            MenuStatus {
                Text("กะดึกคืน \(NightShiftController.nightLabel(report.night)): \(report.entries.count) รายการ")
                Button("ดูรายงาน") { shift.openReport() }
            }
        }
    }
}

/// Settings › โควตา Claude: each feature on its own, and their options.
struct QuotaSettingsSection: View {
    @ObservedObject private var quota = QuotaResume.shared
    @ObservedObject private var shift = NightShiftController.shared
    /// The Tracker's projects, so any of them can be ticked.
    let projects: [String]

    private var choices: [String] {
        var all = projects
        for name in shift.config.projects where !all.contains(name) { all.append(name) }
        return all
    }

    var body: some View {
        Section("โควตา Claude") {
            Toggle("ชนโควตากลางงาน → รอแล้วทำต่อเองเมื่อรีเซ็ต", isOn: Binding(
                get: { quota.isOn },
                set: { quota.setOn($0) }
            ))
            Toggle("กันเครื่องหลับจนถึงเวลารีเซ็ต (ตอนเสียบสาย)", isOn: $quota.keepAwake)
                .disabled(!quota.isOn)
            ForEach(quota.stuck) { chat in
                HStack {
                    Text("ค้าง: \(chat.title)").lineLimit(1)
                    Spacer()
                    Button("เปิด Claude") { quota.openClaude() }
                    Button("ไม่ต้องรอ") { quota.dismiss(chat.id) }
                }
                .font(.system(size: 12, weight: .regular))
            }

            Toggle("กะดึก: ใช้โควตาที่เหลือตอนกลางคืน", isOn: Binding(
                get: { shift.config.enabled },
                set: { shift.setEnabled($0) }
            ))
            if !shift.routineInstalled {
                Text("ยังไม่ได้ติดตั้ง Routine \"Finish Engine กะดึก\" ในแอป Claude")
                    .font(.system(size: 12, weight: .regular)).foregroundStyle(.orange)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("โปรเจกต์ที่กะดึกทำได้ (งานที่ต้องรอคุณจะถูกข้าม)")
                    .font(.system(size: 12, weight: .regular)).foregroundStyle(.secondary)
                Toggle("อัตโนมัติ: เลือกงานเองจากทุกโปรเจกต์", isOn: Binding(
                    get: { shift.config.allProjects },
                    set: { shift.setAllProjects($0) }
                ))
                .toggleStyle(.checkbox)
                .help("ใช้ไปก่อนจนกว่าจะอยากโฟกัส: เอาติ๊กออกแล้วเลือกเฉพาะโปรเจกต์ด้านล่าง")
                ForEach(choices, id: \.self) { name in
                    Toggle(FinishEngineBoard.displayName(name), isOn: Binding(
                        get: { shift.config.allProjects || shift.config.projects.contains(name) },
                        set: { _ in shift.toggle(project: name) }
                    ))
                    .toggleStyle(.checkbox)
                    .disabled(shift.config.allProjects)
                    .padding(.leading, 18)
                }
            }
            Picker("กะดึกใช้โควตาได้แค่ไหน", selection: Binding(
                get: { shift.config.mode },
                set: { shift.setMode($0) }
            )) {
                ForEach(NightShiftConfig.Mode.allCases, id: \.self) { mode in
                    Text(NightShiftController.modeName(mode)).tag(mode)
                }
            }
            Picker("เก็บโควตาไว้ให้คุณ (จนถึงวันสุดท้าย)", selection: Binding(
                get: { shift.config.reserve },
                set: { shift.setReserve($0) }
            )) {
                ForEach([20, 35, 50], id: \.self) { Text("\($0)%").tag($0) }
            }
            .disabled(shift.config.mode != .pace)
            Text("รอบ \(shift.config.schedule) · " + NightShiftController.modeHelp(shift.config) + " · หยุดเองก่อนชนลิมิต ไม่ deploy ไม่ลบ ไม่ส่งข้อความแทนคุณ")
                .font(.system(size: 12, weight: .regular)).foregroundStyle(.secondary)
            if let report = shift.report {
                Button("ดูรายงานกะดึก คืน \(NightShiftController.nightLabel(report.night)) (\(report.entries.count) รายการ)") {
                    shift.openReport()
                }
            }
        }
        .onAppear {
            quota.reload()
            shift.start()
        }
    }
}

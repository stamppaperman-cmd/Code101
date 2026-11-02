import SwiftUI
import UniformTypeIdentifiers

/// Floating glass card for the meeting recorder: record → live meters →
/// transcribe + summarise → open the notes. A file dropped on the card takes
/// the same route from the audio step onwards.
struct MeetingRecorderView: View {
    @ObservedObject var model: MeetingRecorderModel
    var onClose: () -> Void

    @State private var isDropTargeted = false

    private let clay = Color(red: 0.851, green: 0.467, blue: 0.341)

    /// Dropping is only offered while nothing is recording or processing.
    private var acceptsDrop: Bool {
        switch model.phase {
        case .idle, .done, .failed: return model.environmentReady
        default: return false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            card
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            content
            if let warning = model.warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(width: 340, alignment: .leading)
        .foregroundStyle(.white)
        .smokeGlass(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay {
            if isDropTargeted && acceptsDrop {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .strokeBorder(clay, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
            }
        }
        .padding(.horizontal, 16)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
    }

    /// Audio and video arrive as file URLs; everything else is turned down by
    /// the model with a message naming what it can read.
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard acceptsDrop else { return false }
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !fileProviders.isEmpty else { return false }
        let group = DispatchGroup()
        var urls: [URL] = []
        let lock = NSLock()
        for provider in fileProviders {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    lock.lock(); urls.append(url); lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            Task { @MainActor in model.importFiles(urls) }
        }
        return true
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: model.isRecording ? "record.circle.fill" : "waveform.circle.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(model.isRecording ? Color.red : clay)
            Text("Meeting Notes").font(.system(size: 15, weight: .bold))
            Spacer()
            Text("⌃⌥⌘R").font(.caption).foregroundStyle(.white.opacity(0.55))
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.white.opacity(0.12)))
            }
            .buttonStyle(.plain)
            .help("ซ่อนหน้าต่าง (การบันทึกยังทำงานต่อ)")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle:
            if model.environmentReady { idleView } else { setupView }
        case .starting:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("กำลังเริ่มอัดเสียง…").font(.system(size: 13, weight: .medium))
            }
        case .recording:
            recordingView
        case .processing:
            processingView
        case .done:
            doneView
        case .failed(let message):
            failedView(message)
        }
    }

    // MARK: Idle

    private var idleView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: { model.startRecording() }) {
                HStack(spacing: 8) {
                    Circle().fill(Color.red).frame(width: 12, height: 12)
                    Text("เริ่มบันทึกประชุม").font(.system(size: 15, weight: .bold))
                    Spacer()
                }
                .padding(.horizontal, 14)
                .frame(height: 44)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(clay.opacity(0.9)))
            }
            .buttonStyle(.plain)

            Toggle(isOn: $model.includeMic) {
                Text("บันทึกเสียงของฉันด้วย (ไมค์ MacBook)").font(.system(size: 13, weight: .medium))
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .help("ใช้ไมค์ในตัว MacBook เสมอ เพื่อไม่ให้ AirPods สลับไปโหมดเสียงต่ำ · ไม่ใส่หูฟังก็ใช้ได้ (ระบบตัดเสียงสะท้อนให้)")

            TextField("บริบท เช่น วิชา / หัวข้อประชุม (ช่วยให้สรุปแม่นขึ้น)", text: $model.context)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.09)))

            dropZone

            Text("จับเสียงจาก Zoom · Teams · Discord · LINE · Meet ได้ทุกแอป ใส่ AirPods Max หรือไม่ใส่ก็ได้ · ถอดเสียงไทยและสรุปในเครื่อง ไม่ส่งออกไปไหน")
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)

            if !model.recent.isEmpty {
                Divider().overlay(Color.white.opacity(0.12))
                Text("ล่าสุด").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.5))
                ForEach(model.recent.prefix(3)) { session in
                    recentRow(session)
                }
            }
        }
    }

    /// Already have the recording? Drop it here instead of recording a new one.
    private var dropZone: some View {
        VStack(spacing: 5) {
            HStack(spacing: 7) {
                Image(systemName: isDropTargeted ? "square.and.arrow.down.fill" : "waveform.badge.plus")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isDropTargeted ? clay : .white.opacity(0.7))
                Text(isDropTargeted ? "ปล่อยเพื่อถอดเสียงไฟล์นี้" : "มีไฟล์อยู่แล้ว? ลากมาวางตรงนี้")
                    .font(.system(size: 12.5, weight: .semibold))
            }
            HStack(spacing: 4) {
                Text("m4a · mp3 · wav · mp4 · mov")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.5))
                Text("หรือ")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.4))
                Button("เลือกไฟล์…") { model.chooseFileToImport() }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(clay)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(isDropTargeted ? 0.14 : 0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isDropTargeted ? clay.opacity(0.9) : Color.white.opacity(0.18),
                              style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        )
        .animation(.easeOut(duration: 0.12), value: isDropTargeted)
        .help("ลากไฟล์เสียงหรือวิดีโอมาวาง แล้วถอดเสียงไทย + สรุปให้เหมือนประชุมที่อัดเอง")
    }

    private func recentRow(_ session: MeetingSession) -> some View {
        HStack(spacing: 8) {
            Image(systemName: session.hasNotes ? "doc.text.fill" : (session.hasTranscript ? "text.alignleft" : "waveform"))
                .foregroundStyle(session.hasNotes ? clay : .white.opacity(0.6))
                .frame(width: 16)
            Text(session.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
            Spacer()
            if session.hasNotes || session.hasTranscript {
                Button("เปิด") { model.open(session) }
            } else if session.hasAudio {
                Button("ประมวลผล") { model.reprocess(session) }
            }
            Button { model.reveal(session) } label: { Image(systemName: "folder") }
                .help("เปิดโฟลเดอร์")
        }
        .buttonStyle(.plain)
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.white.opacity(0.85))
    }

    // MARK: Setup

    private var setupView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ตั้งค่าครั้งแรก").font(.system(size: 14, weight: .bold))
            Text("ติดตั้งตัวถอดเสียงภาษาไทย (Typhoon Whisper) ลงในเครื่อง ใช้พื้นที่ ~2.5GB · ทำงานออฟไลน์ ไม่ส่งเสียงออกไปไหน")
                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
            if model.isInstalling {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(model.installLog.last ?? "…").font(.system(size: 11)).lineLimit(2)
                        .foregroundStyle(.white.opacity(0.75))
                }
            } else {
                Button(action: { model.install() }) {
                    Text("ติดตั้งเลย").font(.system(size: 14, weight: .bold))
                        .frame(maxWidth: .infinity, minHeight: 38)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(clay.opacity(0.9)))
                }
                .buttonStyle(.plain)
                if let last = model.installLog.last {
                    Text(last).font(.system(size: 11)).foregroundStyle(.orange).lineLimit(3)
                }
            }
        }
    }

    // MARK: Recording

    private var recordingView: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                PulsingDot()
                Text(Self.format(model.elapsed))
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Spacer()
                if let app = model.detectedApp {
                    Text(app).font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 9).padding(.vertical, 3)
                        .background(Capsule().fill(Color.white.opacity(0.12)))
                }
            }
            VStack(spacing: 8) {
                LevelBar(title: "เสียงประชุม", value: model.systemLevel, tint: clay)
                if model.includeMic {
                    LevelBar(title: "ไมค์ของฉัน", value: model.micLevel, tint: .green)
                }
            }
            Button(action: { model.stopRecording() }) {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 3).fill(Color.white).frame(width: 12, height: 12)
                    Text("หยุดและสรุป").font(.system(size: 15, weight: .bold))
                    Spacer()
                }
                .padding(.horizontal, 14)
                .frame(height: 44)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.red.opacity(0.85)))
            }
            .buttonStyle(.plain)
            Text("ปิดหน้าต่างนี้ได้ บันทึกยังทำงานต่อ · กด ⌃⌥⌘R เพื่อหยุดจากที่ไหนก็ได้")
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
        }
    }

    // MARK: Processing

    private var processingView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("กำลังทำโน้ต…").font(.system(size: 14, weight: .bold))
            ProgressView(value: min(max(model.progress, 0.02), 1))
                .progressViewStyle(.linear)
                .tint(clay)
            Text(model.stageText).font(.system(size: 12)).foregroundStyle(.white.opacity(0.7)).lineLimit(2)
            HStack {
                Text("ถอดเสียงไทยใช้เวลา ~1/6 ของความยาวประชุม")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                Spacer()
                Button("ยกเลิก") { model.cancelProcessing() }
                    .buttonStyle(.plain).font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
    }

    // MARK: Done / failed

    private var doneView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("โน้ตพร้อมแล้ว", systemImage: "checkmark.seal.fill")
                .font(.system(size: 14, weight: .bold)).foregroundStyle(.green)
            if !model.summaryPreview.isEmpty {
                ScrollView {
                    Text(model.summaryPreview)
                        .font(.system(size: 12.5))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 130)
            }
            HStack(spacing: 8) {
                pill("เปิดโน้ต", "doc.text") { model.openNotes() }
                pill("คัดลอก", "doc.on.doc") { model.copyNotes() }
                pill("โฟลเดอร์", "folder") { model.reveal() }
            }
            Button("เสร็จ") { model.reset() }
                .buttonStyle(.plain).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.65))
        }
    }

    private func failedView(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("ไม่สำเร็จ", systemImage: "xmark.octagon.fill")
                .font(.system(size: 14, weight: .bold)).foregroundStyle(.red)
            Text(message).font(.system(size: 12)).foregroundStyle(.white.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if let s = model.currentSession, s.hasAudio {
                    pill("ลองใหม่", "arrow.clockwise") { model.reprocess(s) }
                }
                if model.currentSession != nil {
                    pill("โฟลเดอร์", "folder") { model.reveal() }
                }
                pill("ปิด", "xmark") { model.reset() }
            }
        }
    }

    private func pill(_ title: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(Capsule().fill(Color.white.opacity(0.14)))
        }
        .buttonStyle(.plain)
    }

    static func format(_ t: TimeInterval) -> String {
        let s = Int(t)
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60)
            : String(format: "%02d:%02d", s / 60, s % 60)
    }
}

private struct PulsingDot: View {
    @State private var on = false
    var body: some View {
        Circle().fill(Color.red)
            .frame(width: 11, height: 11)
            .opacity(on ? 0.25 : 1)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { on = true }
            }
    }
}

private struct LevelBar: View {
    let title: String
    let value: Float
    let tint: Color

    var body: some View {
        HStack(spacing: 10) {
            Text(title).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.65))
                .frame(width: 74, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.12))
                    Capsule().fill(tint)
                        .frame(width: max(4, geo.size.width * CGFloat(value)))
                        .animation(.easeOut(duration: 0.12), value: value)
                }
            }
            .frame(height: 6)
        }
    }
}

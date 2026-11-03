import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel
    @State private var isDropTargeted = false

    private var selectedJob: Job? {
        guard let id = model.selection else { return nil }
        return model.store.job(id)
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
        } detail: {
            Group {
                if let job = selectedJob {
                    JobDetailView(model: model, job: job)
                } else {
                    EmptyStateView(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.addFiles(urls)
            return true
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                    .background(Color.accentColor.opacity(0.08))
                    .allowsHitTesting(false)
                    .padding(6)
            }
        }
        .task { await model.refreshOllama() }
    }
}

// MARK: - Sidebar

private struct SidebarView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $model.selection) {
                ForEach(model.store.jobs) { job in
                    JobRow(job: job)
                        .tag(job.id)
                        .contextMenu {
                            Button("เปิดโฟลเดอร์ผลลัพธ์") { model.revealInFinder(job) }
                            Button("ทำใหม่") { model.retry(job) }
                            Divider()
                            Button("ลบ", role: .destructive) { model.delete(job) }
                        }
                }
            }
            .listStyle(.sidebar)
            .overlay {
                if model.store.jobs.isEmpty {
                    ContentUnavailableView("ยังไม่มีไฟล์", systemImage: "waveform",
                                           description: Text("ลากไฟล์เสียงหรือวิดีโอมาวาง หรือกด ⌘O"))
                }
            }

            Divider()
            SettingsBar(model: model)
        }
        .toolbar {
            ToolbarItem {
                Button { model.showOpenPanel() } label: {
                    Label("เพิ่มไฟล์", systemImage: "plus")
                }
                .help("เพิ่มไฟล์เสียงหรือวิดีโอ")
            }
        }
    }
}

private struct JobRow: View {
    let job: Job

    var body: some View {
        HStack(spacing: 10) {
            statusIcon
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.filename)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    Text(job.status.isRunning ? job.status.label : job.durationLabel)
                    if job.status.isRunning {
                        Text("\(Int(job.progress * 100))%")
                        if let eta = job.etaLabel {
                            Text("· เหลือ ~\(eta)")
                        }
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch job.status {
        case .queued:
            Image(systemName: "clock").foregroundStyle(.secondary)
        case .decoding, .transcribing, .summarizing:
            ProgressView().controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }
}

private struct SettingsBar: View {
    @Bindable var model: AppModel
    @State private var showingVocabulary = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("ภาษาเสียง", selection: $model.language) {
                ForEach(LanguageOption.allCases) { option in
                    Text(option.label).tag(option)
                }
            }

            Toggle("แยกเสียงผู้พูด", isOn: $model.separateSpeakers)

            Toggle("โหมดปิดระบบ", isOn: $model.offlineOnly)
                .help("ห้ามแอปต่อออกนอกเครื่องทุกกรณี ใช้เฉพาะโมเดลที่มีอยู่แล้วและ Ollama ที่ 127.0.0.1")

            Picker("คุณภาพ", selection: $model.quality) {
                ForEach(TranscriptionQuality.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .help(model.quality.detail)

            Picker("โมเดลสรุป", selection: $model.summaryModel) {
                if model.ollamaModels.isEmpty {
                    Text("ไม่พบโมเดล").tag("")
                }
                ForEach(model.ollamaModels, id: \.self) { name in
                    Text(name).tag(name)
                }
            }
            .disabled(model.ollamaModels.isEmpty)

            HStack(spacing: 6) {
                Circle()
                    .fill(model.ollamaAvailable ? Color.green : Color.orange)
                    .frame(width: 7, height: 7)
                Text(model.ollamaAvailable ? "Ollama พร้อม" : "ไม่พบ Ollama — สรุปไม่ได้")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await model.refreshOllama() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("เปิดแอป Ollama แล้วกดปุ่มนี้เพื่อตรวจใหม่")
            }

            Button {
                showingVocabulary = true
            } label: {
                Label(vocabularyLabel, systemImage: "character.book.closed")
            }
            .buttonStyle(.borderless)
            .help("บอกชื่อคน ชื่อแบรนด์ และศัพท์เฉพาะไว้ล่วงหน้า แม่นกว่ามาแก้ทีหลัง")
        }
        .controlSize(.small)
        .padding(10)
        .sheet(isPresented: $showingVocabulary) { VocabularySheet() }
    }

    private var vocabularyLabel: String {
        let count = Vocabulary.words.count
        return count == 0 ? "คำเฉพาะ (ยังไม่ได้ใส่)" : "คำเฉพาะ (\(count) คำ)"
    }
}

/// Names and jargon, given to Whisper *before* it decodes.
///
/// This is the only place in the app where a user can improve the raw transcript
/// itself rather than clean it up afterwards, which is why it sits in the settings bar
/// and not behind a menu.
private struct VocabularySheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text = Vocabulary.words.joined(separator: "\n")

    private var words: [String] {
        Vocabulary.clean(text.components(separatedBy: .newlines))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("คำเฉพาะในไฟล์เสียง").font(.headline)
            Text("ชื่อคน ชื่อแบรนด์ ศัพท์เฉพาะ — บรรทัดละหนึ่งคำ "
                 + "ขั้นเกลาคำจะเห็นรายการนี้ และแก้เฉพาะคำที่ออกเสียงใกล้เคียง")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: $text)
                .font(.body)
                .frame(height: 190)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))

            Label("ใช้ตอนขั้นเกลาคำ ไม่กระทบการถอดเสียงและไม่ทำให้ตกประโยค "
                  + "ข้อความดิบยังเก็บไว้ครบเหมือนเดิมเสมอ",
                  systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Text("\(words.count) คำ").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("ยกเลิก") { dismiss() }
                Button("บันทึก") {
                    Vocabulary.words = words
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

// MARK: - Empty state

private struct EmptyStateView: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform.circle")
                .font(.system(size: 56, weight: .thin))
                .foregroundStyle(.tint)
            Text("ลากไฟล์เสียงหรือวิดีโอมาวางที่นี่")
                .font(.title3.weight(.medium))
            Text("m4a · mp3 · wav · caf · mp4 · mov — ถอดเสียงและสรุปในเครื่องทั้งหมด ไม่ส่งข้อมูลออกไปไหน")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button("เพิ่มไฟล์…") { model.showOpenPanel() }
                .controlSize(.large)
                .padding(.top, 4)
        }
        .padding(40)
    }
}

enum SpeakerPalette {
    static let colors: [Color] = [.blue, .orange, .purple, .green, .pink, .teal, .indigo, .brown]

    static func color(_ id: Int?) -> Color {
        guard let id else { return .gray }
        return colors[abs(id) % colors.count]
    }
}

/// One chip per voice: colour, name, and how long they held the floor. Tapping a
/// chip lets the user replace a guessed name with the real one.
private struct SpeakerBar: View {
    let model: AppModel
    let job: Job
    @State private var editingSpeaker: Int?
    @State private var draft = ""

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(job.speakers ?? []) { speaker in
                    Button {
                        draft = speaker.name ?? speaker.guessedName ?? ""
                        editingSpeaker = speaker.id
                    } label: {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(SpeakerPalette.color(speaker.id))
                                .frame(width: 8, height: 8)
                            Text(speaker.displayName)
                                .fontWeight(speaker.id == job.mainSpeaker?.id ? .semibold : .regular)
                            Text(speaker.talkTimeLabel)
                                .foregroundStyle(.secondary)
                            if speaker.id == job.mainSpeaker?.id {
                                Image(systemName: "star.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .font(.callout)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(SpeakerPalette.color(speaker.id).opacity(0.12),
                                    in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: Binding(
                        get: { editingSpeaker == speaker.id },
                        set: { if !$0 { editingSpeaker = nil } })) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("ตั้งชื่อผู้พูดคนนี้").font(.headline)
                            TextField("ชื่อ", text: $draft)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 220)
                                .onSubmit { save(speaker.id) }
                            if let evidence = speaker.evidence, !evidence.isEmpty {
                                Text("เดาจาก: \(evidence)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 220, alignment: .leading)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            HStack {
                                Button("ล้างชื่อ") { draft = ""; save(speaker.id) }
                                Spacer()
                                Button("บันทึก") { save(speaker.id) }
                                    .keyboardShortcut(.defaultAction)
                            }
                            .frame(width: 220)
                        }
                        .padding(14)
                    }
                }
                if (job.speakers ?? []).contains(where: { $0.guessedName != nil && !$0.isConfirmed }) {
                    Text("ชื่อที่ต่อท้ายด้วย (เดา) มาจากบทสนทนา กดที่ชื่อเพื่อยืนยันหรือแก้")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private func save(_ speakerId: Int) {
        model.rename(jobID: job.id, speakerId: speakerId, to: draft)
        editingSpeaker = nil
    }
}

// MARK: - Detail

private enum DetailTab: String, CaseIterable, Identifiable {
    case raw, summary, ask
    var id: String { rawValue }
    var label: String {
        switch self {
        case .raw: return "ข้อความดิบ"
        case .summary: return "สรุป"
        case .ask: return "ถาม"
        }
    }
}

private struct JobDetailView: View {
    let model: AppModel
    let job: Job
    @State private var tab: DetailTab = .summary
    @State private var useCorrected = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if job.status.isRunning || job.status == .queued {
                progressStrip
                Divider()
            }

            if let error = job.errorMessage {
                banner(text: error, icon: "exclamationmark.triangle.fill", tint: .orange) {
                    Button("ทำใหม่") { model.retry(job) }
                }
            }

            if job.hasSpeakers {
                SpeakerBar(model: model, job: job)
                Divider()
            }

            if !job.segments.isEmpty {
                Picker("", selection: $tab) {
                    ForEach(DetailTab.allCases) { item in
                        Text(item.label).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                Divider()

                switch tab {
                case .raw: RawTranscriptView(job: job, useCorrected: $useCorrected)
                case .summary: SummaryView(model: model, job: job)
                case .ask: AskPanel(model: model, job: job)
                }
            } else if !job.status.isRunning {
                Spacer()
                ContentUnavailableView("ยังไม่มีข้อความ", systemImage: "text.alignleft",
                                       description: Text("ไฟล์นี้ยังถอดเสียงไม่สำเร็จ กด \"ทำใหม่\" เพื่อลองอีกครั้ง"))
                Spacer()
            } else {
                Spacer()
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Menu {
                    Button("สรุป + ข้อความถอดเสียง (.pdf)") { savePDF([.summary, .transcript], suffix: "") }
                    Button("เฉพาะสรุป (.pdf)") { savePDF([.summary], suffix: "-summary") }
                        .disabled(job.summary == nil)
                    Button("เฉพาะข้อความถอดเสียง (.pdf)") { savePDF([.transcript], suffix: "-transcript") }

                    Divider()

                    Button("ข้อความล้วน (.txt)") { FileExport.save(job.fullText(corrected: exportCorrected), suggestedName: base + ".txt") }
                    Button("ข้อความพร้อมเวลา (.txt)") { FileExport.save(job.timestampedText(corrected: exportCorrected), suggestedName: base + "-timestamps.txt") }
                    Button("ซับไตเติล (.srt)") { FileExport.save(job.srt(corrected: exportCorrected), suggestedName: base + ".srt") }
                    if job.hasSpeakers {
                        Button("ข้อความแยกผู้พูด (.txt)") {
                            FileExport.save(job.attributedText(corrected: exportCorrected),
                                            suggestedName: base + "-speakers.txt")
                        }
                    }
                    if job.summary != nil {
                        Button("สรุป (.md)") { FileExport.save(job.summaryMarkdown, suggestedName: base + "-summary.md") }
                    }
                } label: {
                    Label("บันทึกเป็น", systemImage: "square.and.arrow.down")
                }
                .disabled(job.segments.isEmpty)

                Button { model.revealInFinder(job) } label: {
                    Label("เปิดโฟลเดอร์", systemImage: "folder")
                }
                .help("เปิดโฟลเดอร์ที่เก็บผลลัพธ์ทั้งหมด")
            }
        }
    }

    private var base: String {
        (job.filename as NSString).deletingPathExtension
    }

    /// Export follows whatever the reader is currently showing.
    private var exportCorrected: Bool {
        job.hasCorrections && useCorrected
    }

    private func savePDF(_ parts: Set<TranscriptDocument.Part>, suffix: String) {
        let document = TranscriptDocument.build(job: job, corrected: exportCorrected, parts: parts)
        FileExport.save(PDFExporter.data(from: document), suggestedName: base + suffix + ".pdf")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(job.filename)
                .font(.title2.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            HStack(spacing: 10) {
                Label(job.durationLabel, systemImage: "clock")
                if !job.asrModel.isEmpty {
                    Label(job.asrModel, systemImage: "waveform")
                }
                if let summary = job.summary {
                    Label(summary.model, systemImage: "text.book.closed")
                }
                Label(job.detectedLanguage.map { "ภาษา \($0)" } ?? job.language.label, systemImage: "globe")
                if let quality = job.quality {
                    Label(quality.label, systemImage: "dial.high")
                }
                if let elapsed = job.elapsedLabel, job.status == .done {
                    Label("ใช้เวลา \(elapsed)", systemImage: "stopwatch")
                }
                if let speed = job.speedFactor {
                    Label(String(format: "%.1f× เร็วกว่าเวลาจริง", speed), systemImage: "gauge.with.needle")
                        .help(job.timingSummary
                            .map { "\($0.stage) \(Int($0.seconds)) วิ" }
                            .joined(separator: " · "))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var progressStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: job.progress)
            HStack(spacing: 10) {
                Text(job.stage.isEmpty ? job.status.label : job.stage)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let elapsed = job.elapsedLabel {
                    Label(elapsed, systemImage: "stopwatch")
                        .monospacedDigit()
                }
                if let eta = job.etaLabel {
                    Label("เหลืออีก ~\(eta)", systemImage: "hourglass")
                }
                Text("\(Int(job.progress * 100))%").monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func banner<Action: View>(text: String, icon: String, tint: Color,
                                      @ViewBuilder action: () -> Action) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer()
            action()
        }
        .padding(12)
        .background(tint.opacity(0.1))
    }
}

// MARK: - Raw transcript

import SwiftUI

/// Ask a question of one recording.
///
/// The value here is not that a model answers — it is what happens when it cannot.
/// Retrieval hands it a handful of moments and nothing else, every sentence has to
/// name the line it came from, and a sentence that cannot is dropped before it is
/// shown. "ไม่พบคำตอบในไฟล์นี้" is therefore a real answer, and the most useful one
/// a tool like this can give about something that was never said.
struct AskPanel: View {
    let model: AppModel
    let job: Job

    @State private var question = ""
    @State private var showingKeySheet = false
    @FocusState private var focused: Bool

    private var answers: [GroundedAnswer] { job.answers ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if answers.isEmpty { intro }
                        ForEach(answers) { answer in
                            AnswerCard(job: job, answer: answer).id(answer.id)
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: answers.count) {
                    guard let last = answers.last else { return }
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }

            Divider()
            composer
        }
        .sheet(isPresented: $showingKeySheet) { GeminiKeySheet(model: model) }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("ถามอะไรก็ได้จากไฟล์นี้", systemImage: "text.magnifyingglass")
                .font(.headline)
            Text("ทุกคำตอบจะอ้างอิงบรรทัดที่ใช้ กดที่เวลาเพื่อฟังเสียงจริงตรงนั้นได้ "
                 + "ถ้าในไฟล์ไม่มีคำตอบ จะตอบว่าไม่พบ ไม่เดาให้")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if job.answers == nil {
                Text("ถ้าถามแล้วขึ้นว่ายังไม่มีดัชนี ให้กด \"ทำดัชนีใหม่\" หนึ่งครั้ง")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = model.askError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                TextField("ถามจากไฟล์นี้…", text: $question, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .focused($focused)
                    .onSubmit(send)
                    .disabled(model.isAsking)

                Button(action: send) {
                    if model.isAsking {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.up.circle.fill").font(.title2)
                    }
                }
                .buttonStyle(.plain)
                .disabled(model.isAsking || question.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            HStack(spacing: 10) {
                Picker("", selection: Binding(
                    get: { model.answerBackend },
                    set: { model.answerBackend = $0 }
                )) {
                    ForEach(AnswerBackend.allCases) { backend in
                        Text(backend.label).tag(backend)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()

                if model.answerBackend == .gemini {
                    Button(model.hasGeminiKey ? "ตั้งค่า Gemini" : "ใส่ API key") {
                        showingKeySheet = true
                    }
                }
                Button("ทำดัชนีใหม่") { model.reindex(job) }
                    .disabled(model.isAsking || model.answerBackend != .local)
                if !answers.isEmpty {
                    Button("ล้างคำถาม") { model.clearAnswers(job) }
                }
                Spacer()
            }
            .controlSize(.small)

            // The choice changes where the recording goes, so the consequence is stated
            // every time rather than buried in a settings pane.
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: model.answerBackend.sendsDataOut
                      ? "exclamationmark.triangle.fill" : "lock.fill")
                    .font(.caption)
                    .foregroundStyle(model.answerBackend.sendsDataOut ? .orange : .secondary)
                Text(model.answerBackend.detail)
                    .font(.caption)
                    .foregroundStyle(model.answerBackend.sendsDataOut ? .orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
    }

    private func send() {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !model.isAsking else { return }
        question = ""
        Task { await model.ask(text, of: job) }
    }
}

private struct AnswerCard: View {
    let job: Job
    let answer: GroundedAnswer

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "person.fill").foregroundStyle(.secondary).font(.caption)
                Text(answer.question)
                    .fontWeight(.medium)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                // Which model saw this recording, kept with the answer rather than only
                // in the picker — the picker shows what is selected now, not what was
                // selected when this answer was produced.
                Label(answer.backend.label,
                      systemImage: answer.backend.sendsDataOut ? "cloud" : "lock")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            if answer.refused {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(Asker.refusal)
                        Text("ค้นแล้ว \(answer.consulted.count) บรรทัดที่ใกล้เคียงที่สุด แต่ไม่มีบรรทัดไหนตอบคำถามนี้ได้")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(answer.claims) { claim in
                        ClaimRow(job: job, claim: claim, marker: "›")
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}


/// The user types their own key here; it goes straight to the Keychain and is never
/// held anywhere else. Getting a free key is a Google account and one page, so the
/// link is right there rather than described.
private struct GeminiKeySheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("เชื่อมต่อ Gemini (ฟรี)").font(.headline)

            Text("Gemini มีโควตาฟรีต่อวัน ใช้สำหรับถามคำถามที่ต้องดูทั้งไฟล์พร้อมกัน "
                 + "ซึ่งโมเดลในเครื่องทำไม่ได้เพราะบริบทสั้นกว่ามาก")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Link("ขอ API key ฟรีที่ Google AI Studio",
                 destination: URL(string: "https://aistudio.google.com/apikey")!)
                .font(.callout)

            SecureField("วาง API key ที่นี่", text: $key)
                .textFieldStyle(.roundedBorder)

            TextField("ชื่อโมเดล", text: Binding(
                get: { model.geminiModel },
                set: { model.geminiModel = $0 }
            ))
            .textFieldStyle(.roundedBorder)
            .help("ชื่อรุ่นของ Gemini เปลี่ยนเป็นระยะ ถ้าขึ้นว่าไม่พบโมเดล ให้แก้ตรงนี้")

            Label("เมื่อเลือก Gemini สรุปและข้อความถอดเสียงทั้งไฟล์จะถูกส่งไปที่เซิร์ฟเวอร์ของ Google "
                  + "ส่วนไฟล์เสียงไม่ถูกส่งไปไหนทั้งสิ้น",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                if model.hasGeminiKey {
                    Button("ลบคีย์ออก", role: .destructive) {
                        model.saveGeminiKey("")
                        dismiss()
                    }
                }
                Spacer()
                Button("ยกเลิก") { dismiss() }
                Button("บันทึก") {
                    model.saveGeminiKey(key)
                    key = ""
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Owns the queue and drives one job at a time: decode → transcribe → summarize.
/// Transcription is GPU-bound, so running two files at once would only slow both.
@MainActor
@Observable
final class AppModel {
    let store = JobStore()

    var selection: UUID?
    var ollamaModels: [String] = []
    var ollamaAvailable = false
    var isBusy = false

    var language: LanguageOption = .auto {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: Keys.language) }
    }

    var summaryModel: String = "" {
        didSet { UserDefaults.standard.set(summaryModel, forKey: Keys.summaryModel) }
    }

    /// Every model Ollama has, including the embedding ones the summary picker hides.
    var allOllamaModels: [String] = []
    var isAsking = false
    var askError: String?

    /// Which model answers questions. Local by default and stays local unless the user
    /// changes it — the hosted option sends the transcript off the machine, so it is
    /// never selected on anyone's behalf.
    var answerBackend: AnswerBackend = .local {
        didSet { UserDefaults.standard.set(answerBackend.rawValue, forKey: Keys.answerBackend) }
    }

    var geminiModel: String = GeminiClient.defaultModel {
        didSet { UserDefaults.standard.set(geminiModel, forKey: Keys.geminiModel) }
    }

    /// The key itself never lives in this object; only whether one exists.
    private(set) var hasGeminiKey = Secrets.has(Secrets.geminiKey)

    func saveGeminiKey(_ key: String) {
        Secrets.write(key, for: Secrets.geminiKey)
        hasGeminiKey = Secrets.has(Secrets.geminiKey)
        if !hasGeminiKey, answerBackend == .gemini { answerBackend = .local }
        log("gemini key \(hasGeminiKey ? "saved" : "cleared")")
    }

    /// Set when a dropped file was recognised as one already transcribed. Cleared on
    /// the next drop; purely a message, never a block.
    var duplicateNotice: String?

    var quality: TranscriptionQuality = .fast {
        didSet { UserDefaults.standard.set(quality.rawValue, forKey: Keys.quality) }
    }

    var separateSpeakers = true {
        didSet { UserDefaults.standard.set(separateSpeakers, forKey: Keys.separateSpeakers) }
    }

    /// Closed-system mode: the app may talk to Ollama on 127.0.0.1 and nothing else.
    /// Model downloads are the only outbound connection this app ever makes, so
    /// blocking them is what makes the whole thing airtight.
    var offlineOnly = false {
        didSet { UserDefaults.standard.set(offlineOnly, forKey: Keys.offlineOnly) }
    }

    private var pending: [UUID] = []

    private enum Keys {
        static let language = "language"
        static let summaryModel = "summaryModel"
        static let quality = "quality"
        static let answerBackend = "answerBackend"
        static let geminiModel = "geminiModel"
        static let separateSpeakers = "separateSpeakers"
        static let offlineOnly = "offlineOnly"
    }

    /// Stages that were skipped this run, so the time estimate stops counting them.
    private var skippedStages: Set<PipelineStage> = []

    init() {
        if let raw = UserDefaults.standard.string(forKey: Keys.language),
           let saved = LanguageOption(rawValue: raw) {
            language = saved
        }
        summaryModel = UserDefaults.standard.string(forKey: Keys.summaryModel) ?? ""
        if let rawBackend = UserDefaults.standard.string(forKey: Keys.answerBackend),
           let saved = AnswerBackend(rawValue: rawBackend) {
            answerBackend = saved
        }
        if let saved = UserDefaults.standard.string(forKey: Keys.geminiModel), !saved.isEmpty {
            geminiModel = saved
        }
        if let rawQuality = UserDefaults.standard.string(forKey: Keys.quality),
           let saved = TranscriptionQuality(rawValue: rawQuality) {
            quality = saved
        }
        if UserDefaults.standard.object(forKey: Keys.separateSpeakers) != nil {
            separateSpeakers = UserDefaults.standard.bool(forKey: Keys.separateSpeakers)
        }
        offlineOnly = UserDefaults.standard.bool(forKey: Keys.offlineOnly)
        selection = store.jobs.first?.id
    }

    // MARK: - Intake

    static let acceptedTypes: [UTType] = [.audio, .movie, .mpeg4Audio, .mp3, .wav, .aiff, .quickTimeMovie, .mpeg4Movie]

    func canAccept(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return type.conforms(to: .audio) || type.conforms(to: .movie) || type.conforms(to: .audiovisualContent)
    }

    func addFiles(_ urls: [URL]) {
        let accepted = urls.filter(canAccept)
        guard !accepted.isEmpty else { return }
        duplicateNotice = nil
        for url in accepted {
            let fingerprint = SourceFingerprint.of(url)

            // The same file, already transcribed the same way, is an hour of compute
            // for an answer that is already on disk. Show that result instead of
            // recomputing it; a different quality or language still runs.
            if let fingerprint, let existing = store.jobs.first(where: {
                $0.sourceHash == fingerprint && $0.status == .done
                    && $0.quality == quality && $0.language == language
            }) {
                log("duplicate drop: \(url.lastPathComponent) matches job \(existing.id) — showing that instead")
                duplicateNotice = "\(url.lastPathComponent) เคยถอดไว้แล้วด้วยการตั้งค่าเดียวกัน — เปิดผลเดิมให้แทน"
                selection = existing.id
                continue
            }

            var job = Job(filename: url.lastPathComponent, sourcePath: url.path, language: language)
            job.quality = quality
            job.sourceHash = fingerprint
            log("queued \(job.filename) (\(quality.rawValue), \(language.rawValue)) as \(job.id)")
            store.upsert(job, persist: true)
            pending.append(job.id)
            if selection == nil { selection = job.id }
        }
        startIfNeeded()
    }

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio, .movie, .audiovisualContent]
        panel.prompt = "เพิ่มไฟล์"
        if panel.runModal() == .OK { addFiles(panel.urls) }
    }

    func delete(_ job: Job) {
        pending.removeAll { $0 == job.id }
        if selection == job.id { selection = store.jobs.first { $0.id != job.id }?.id }
        store.delete(job)
    }

    func revealInFinder(_ job: Job) {
        NSWorkspace.shared.activateFileViewerSelecting([store.folder(for: job)])
    }

    // MARK: - Ollama

    func refreshOllama() async {
        let client = OllamaClient()
        let models = (try? await client.installedModels()) ?? []
        allOllamaModels = models
        ollamaModels = models.filter { !$0.contains("embed") }
        ollamaAvailable = !ollamaModels.isEmpty
        if summaryModel.isEmpty || !ollamaModels.contains(summaryModel) {
            summaryModel = ollamaModels.first ?? ""
        }
    }

    // MARK: - Pipeline

    func retry(_ job: Job) {
        var fresh = job
        fresh.status = .queued
        fresh.progress = 0
        fresh.stage = ""
        fresh.errorMessage = nil
        store.upsert(fresh, persist: true)
        pending.append(fresh.id)
        startIfNeeded()
    }

    func retrySummary(_ job: Job) {
        guard !job.segments.isEmpty else { return }
        Task { await summarize(jobID: job.id, finish: true) }
    }

    private func startIfNeeded() {
        guard !isBusy else { return }
        Task { await drain() }
    }

    private func drain() async {
        isBusy = true
        defer { isBusy = false }
        while !pending.isEmpty {
            let id = pending.removeFirst()
            await run(jobID: id)
        }
    }

    /// Times a stage, teaches the estimator how fast this machine really is, and
    /// records the result on the job.
    private func measure<T>(_ stage: PipelineStage, _ jobID: UUID,
                            _ work: () async throws -> T) async rethrows -> T {
        if var job = store.job(jobID) {
            job.currentStage = stage
            store.upsert(job)
        }
        advance(jobID, stage, 0)

        log("stage \(stage.rawValue) begin")
        let start = Date()
        let value = try await work()
        let elapsed = Date().timeIntervalSince(start)
        log("stage \(stage.rawValue) end after \(Int(elapsed))s")

        if var job = store.job(jobID) {
            var timings = job.timings ?? [:]
            timings[stage.label] = elapsed
            job.timings = timings
            store.upsert(job, persist: true)
            StageRates.record(stage: stage, quality: job.quality ?? quality,
                              seconds: elapsed, audioSeconds: job.durationSec)
        }
        return value
    }

    /// One place that moves the bar and refreshes "how much longer".
    private func advance(_ jobID: UUID, _ stage: PipelineStage, _ fraction: Double) {
        guard var job = store.job(jobID) else { return }
        let value = stage.progress(fraction)
        let crossedStep = Int(value * 20) != Int(job.progress * 20)
        job.progress = min(max(value, 0), 1)
        job.currentStage = stage
        job.etaSeconds = StageRates.remainingSeconds(after: stage,
                                                     fraction: fraction,
                                                     audioSeconds: job.durationSec,
                                                     quality: job.quality ?? quality,
                                                     skipping: skippedStages)
        store.upsert(job, persist: crossedStep)
    }

    private func run(jobID: UUID) async {
        guard var job = store.job(jobID) else { return }
        let url = URL(fileURLWithPath: job.sourcePath)
        guard FileManager.default.fileExists(atPath: job.sourcePath) else {
            fail(jobID, "ไฟล์ต้นทางถูกย้ายหรือลบไปแล้ว — ลากไฟล์เข้ามาใหม่\n(เดิมอยู่ที่ \(job.sourcePath))")
            return
        }

        skippedStages = []
        do {
            job.status = .decoding
            job.stage = "กำลังอ่านไฟล์เสียง"
            job.progress = 0
            job.errorMessage = nil
            job.startedAt = Date()
            job.etaSeconds = nil
            store.upsert(job, persist: true)

            let audio = try await measure(.decode, jobID) {
                try await AudioDecoder.decode(url: url) { [weak self] fraction in
                    Task { @MainActor in self?.advance(jobID, .decode, fraction) }
                }
            }

            guard var afterDecode = store.job(jobID) else { return }
            afterDecode.durationSec = audio.duration
            afterDecode.status = .transcribing
            afterDecode.stage = "กำลังเตรียมโมเดล"
            store.upsert(afterDecode, persist: true)

            let jobQuality = job.quality ?? quality
            let modelName = try await TranscriptionEngine.shared.load(quality: jobQuality,
                                                                      offline: offlineOnly) { [weak self] stage in
                Task { @MainActor in self?.setStage(jobID, stage) }
            }

            // Pin one language for the whole file. Left on per window, Whisper
            // mislabels a noisy passage and invents sentences in another language.
            let spoken: String
            if let chosen = job.language.whisperCode {
                spoken = chosen
            } else {
                setStage(jobID, "กำลังตรวจภาษาที่พูด")
                spoken = try await TranscriptionEngine.shared.detectDominantLanguage(samples: audio.samples)
            }
            if var tagged = store.job(jobID) {
                tagged.detectedLanguage = spoken
                store.upsert(tagged, persist: true)
            }
            setStage(jobID, "กำลังถอดเสียง (ภาษา \(spoken))")

            let segments = try await measure(.transcribe, jobID) {
                try await TranscriptionEngine.shared.transcribe(
                    samples: audio.samples,
                    duration: audio.duration,
                    language: spoken,
                    quality: jobQuality,
                    onPartial: { [weak self] partial in
                        Task { @MainActor in self?.keepPartial(jobID, partial) }
                    }
                ) { [weak self] fraction in
                    Task { @MainActor in self?.advance(jobID, .transcribe, fraction) }
                }
            }

            // Whisper drops stretches silently; go back for them before anything
            // downstream treats this transcript as complete.
            let filled = try await measure(.fillGaps, jobID) {
                try await TranscriptionEngine.shared.fillGaps(
                    samples: audio.samples,
                    duration: audio.duration,
                    segments: segments,
                    language: spoken
                ) { [weak self] fraction, found in
                    Task { @MainActor in
                        self?.setStage(jobID, "กำลังเก็บตกช่วงที่ข้ามไป — ได้เพิ่ม \(found) ประโยค")
                        self?.advance(jobID, .fillGaps, fraction)
                    }
                }
            }

            guard var transcribed = store.job(jobID) else { return }
            transcribed.segments = filled
            transcribed.asrModel = modelName
            transcribed.status = .summarizing
            store.upsert(transcribed)
            store.writeTranscript(transcribed)

            await measure(.diarize, jobID) {
                await separateVoices(jobID: jobID, samples: audio.samples)
            }

            // Hand the memory back before the LLM stages: three parallel Ollama
            // requests next to a resident Whisper model is what 16GB cannot hold.
            if pending.isEmpty {
                await TranscriptionEngine.shared.unload()
                await DiarizationEngine.shared.unload()
            }

            await measure(.correct, jobID) {
                await correctSpelling(jobID: jobID)
            }
            await measure(.index, jobID) {
                await buildIndex(jobID: jobID)
            }
            await measure(.summarize, jobID) {
                await summarize(jobID: jobID, finish: true)
            }
        } catch {
            fail(jobID, error.localizedDescription)
        }
    }

    /// Best-effort speaker separation. Like the cleanup pass, a failure here costs
    /// nothing — the transcript is already written, it just stays unattributed.
    private func separateVoices(jobID: UUID, samples: [Float]) async {
        guard separateSpeakers, let job = store.job(jobID), !job.segments.isEmpty else {
            skippedStages.insert(.diarize)
            return
        }
        do {
            try await DiarizationEngine.shared.load(offline: offlineOnly) { [weak self] stage in
                Task { @MainActor in self?.setStage(jobID, stage) }
            }
            setStage(jobID, "กำลังแยกเสียงผู้พูด")
            let spans = try await DiarizationEngine.shared.diarize(samples: samples) { [weak self] fraction in
                Task { @MainActor in self?.advance(jobID, .diarize, fraction) }
            }
            guard var updated = store.job(jobID), !spans.isEmpty else { return }
            SpeakerAssignment.apply(spans: spans, to: &updated.segments)
            updated.speakers = SpeakerAssignment.profiles(spans: spans)
            store.upsert(updated, persist: true)
            store.writeTranscript(updated)
        } catch {
            skippedStages.insert(.diarize)
            setStage(jobID, "แยกเสียงไม่สำเร็จ ข้ามไปก่อน — ข้อความยังครบ")
        }
    }

    /// Attaches names to voices from what is actually said in the room.
    private func nameSpeakers(jobID: UUID) async {
        guard let job = store.job(jobID), job.hasSpeakers,
              ollamaAvailable, !summaryModel.isEmpty else { return }
        // Never overwrite a name the user typed themselves.
        guard (job.speakers ?? []).contains(where: { !$0.isConfirmed }) else { return }

        setStage(jobID, "กำลังหาชื่อผู้พูดจากบทสนทนา")
        let namer = SpeakerNamer(model: summaryModel)
        guard let guesses = try? await namer.guessNames(for: job, corrected: job.hasCorrections),
              !guesses.isEmpty,
              var updated = store.job(jobID) else { return }

        for guess in guesses {
            guard let index = updated.speakers?.firstIndex(where: { $0.id == guess.speakerId }),
                  updated.speakers?[index].isConfirmed == false else { continue }
            updated.speakers?[index].guessedName = guess.name
            updated.speakers?[index].evidence = guess.evidence
        }
        store.upsert(updated, persist: true)
        store.writeTranscript(updated)
    }

    func rename(jobID: UUID, speakerId: Int, to name: String) {
        guard var job = store.job(jobID),
              let index = job.speakers?.firstIndex(where: { $0.id == speakerId }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        job.speakers?[index].name = trimmed.isEmpty ? nil : trimmed
        store.upsert(job, persist: true)
        store.writeTranscript(job)
    }

    /// Best-effort spelling cleanup. Any failure here is silent by design: the raw
    /// transcript is already on disk and is what the user sees by default.
    private func correctSpelling(jobID: UUID) async {
        guard let job = store.job(jobID), !job.segments.isEmpty else { return }
        await refreshOllama()
        guard ollamaAvailable, !summaryModel.isEmpty else {
            skippedStages.insert(.correct)
            return
        }
        do {
            let corrector = TextCorrector(model: summaryModel)
            let corrected = try await corrector.correct(segments: job.segments) { [weak self] stage, fraction in
                Task { @MainActor in
                    self?.setStage(jobID, stage)
                    self?.advance(jobID, .correct, fraction)
                }
            }
            guard var updated = store.job(jobID), corrected.count == updated.segments.count else { return }
            for index in updated.segments.indices where corrected[index] != updated.segments[index].text {
                updated.segments[index].corrected = corrected[index]
            }
            store.upsert(updated)
            store.writeTranscript(updated)
        } catch {
            skippedStages.insert(.correct)
            setStage(jobID, "เกลาคำไม่สำเร็จ ข้ามไปก่อน — ข้อความดิบยังครบ")
        }
        await nameSpeakers(jobID: jobID)
    }

    /// Embeds the transcript so it can be questioned. Best-effort like the cleanup
    /// pass: without it the summary and transcript are still complete, only the
    /// "ถาม" tab goes quiet.
    private func buildIndex(jobID: UUID) async {
        guard let job = store.job(jobID), !job.segments.isEmpty else { return }
        await refreshOllama()
        guard let embedModel = Retriever.installedEmbeddingModel(allOllamaModels) else {
            skippedStages.insert(.index)
            log("index skipped: no embedding model installed")
            return
        }

        setStage(jobID, "กำลังทำดัชนีค้นหา")
        let retriever = Retriever(model: embedModel)
        do {
            let index = try await retriever.build(segments: job.segments,
                                                  corrected: job.hasCorrections) { [weak self] fraction in
                Task { @MainActor in self?.advance(jobID, .index, fraction) }
            }
            guard let current = store.job(jobID) else { return }
            store.writeIndex(index, for: current)
        } catch {
            skippedStages.insert(.index)
            log("index failed: \(error.localizedDescription)")
        }
    }

    /// Answers a question about one recording, from that recording only.
    func ask(_ question: String, of job: Job) async {
        askError = nil
        isAsking = true
        defer { isAsking = false }

        do {
            let answer: GroundedAnswer
            switch answerBackend {
            case .local:
                await refreshOllama()
                guard ollamaAvailable, !summaryModel.isEmpty else {
                    askError = "ต้องเปิด Ollama ก่อนถึงจะถามได้"
                    return
                }
                guard let index = store.readIndex(for: job) else {
                    askError = "ยังไม่มีดัชนีค้นหาของไฟล์นี้ — กด \"ทำดัชนีใหม่\" ก่อน"
                    return
                }
                answer = try await Asker(model: summaryModel)
                    .answer(question, index: index, segments: job.segments)

            case .gemini:
                guard let key = Secrets.read(Secrets.geminiKey) else {
                    askError = "ยังไม่ได้ใส่ API key ของ Gemini — กด \"ตั้งค่า Gemini\""
                    return
                }
                answer = try await Asker.answerExternally(
                    question,
                    segments: job.segments,
                    corrected: job.hasCorrections,
                    client: GeminiClient(model: geminiModel, apiKey: key))
            }

            guard var updated = store.job(job.id) else { return }
            updated.answers = (updated.answers ?? []) + [answer]
            store.upsert(updated, persist: true)
        } catch {
            askError = error.localizedDescription
        }
    }

    /// Rebuilds the vectors for one job on demand — after a re-run, or when the
    /// embedding model was missing the first time.
    func reindex(_ job: Job) {
        Task {
            isAsking = true
            defer { isAsking = false }
            await buildIndex(jobID: job.id)
        }
    }

    func clearAnswers(_ job: Job) {
        guard var updated = store.job(job.id) else { return }
        updated.answers = []
        store.upsert(updated, persist: true)
    }

    private func summarize(jobID: UUID, finish: Bool) async {
        guard var job = store.job(jobID) else { return }

        await refreshOllama()
        guard ollamaAvailable, !summaryModel.isEmpty else {
            job.summaryError = "ยังสรุปไม่ได้เพราะไม่พบ Ollama — ข้อความถอดเสียงอยู่ครบแล้ว เปิด Ollama แล้วกด \"สรุปใหม่\""
            complete(job, finish: finish)
            return
        }

        job.status = .summarizing
        job.stage = "กำลังสรุป"
        job.summaryError = nil
        store.upsert(job, persist: true)

        do {
            let summarizer = Summarizer(model: summaryModel)
            let summary = try await summarizer.summarize(job: job) { [weak self] stage, fraction in
                Task { @MainActor in
                    self?.setStage(jobID, stage)
                    self?.advance(jobID, .summarize, fraction)
                }
            }
            guard var updated = store.job(jobID) else { return }
            updated.summary = summary
            updated.summaryError = nil
            // Must write the *completed* job — writing the pre-complete copy used to
            // stamp job.json back to "summarizing", so a finished job came back as
            // failed on the next launch.
            store.writeSummary(complete(updated, finish: finish))
        } catch {
            guard var updated = store.job(jobID) else { return }
            updated.summaryError = error.localizedDescription
            complete(updated, finish: finish)
        }
    }

    // MARK: - State helpers

    @discardableResult
    private func complete(_ job: Job, finish: Bool) -> Job {
        var updated = job
        if finish {
            updated.status = .done
            updated.stage = ""
            updated.progress = 1
            updated.currentStage = nil
            updated.etaSeconds = nil
            updated.finishedAt = Date()
        }
        store.upsert(updated, persist: true)
        return updated
    }

    /// Segments reach disk as each transcription block lands. A fault late in a
    /// long file then costs the last block instead of the whole hour.
    private func keepPartial(_ jobID: UUID, _ segments: [Segment]) {
        guard var job = store.job(jobID) else { return }
        job.segments = segments
        store.upsert(job, persist: true)
    }

    /// Progress is persisted in 5% steps so an outside observer (or a crash) can
    /// see how far a long job actually got, without writing on every tick.
    private func setProgress(_ jobID: UUID, _ value: Double) {
        guard var job = store.job(jobID) else { return }
        let clamped = min(max(value, 0), 1)
        let crossedStep = Int(clamped * 20) != Int(job.progress * 20)
        job.progress = clamped
        store.upsert(job, persist: crossedStep)
    }

    private func setStage(_ jobID: UUID, _ stage: String) {
        guard var job = store.job(jobID), job.stage != stage else { return }
        job.stage = stage
        store.upsert(job, persist: true)
    }

    private func fail(_ jobID: UUID, _ message: String) {
        log("FAILED \(jobID): \(message)")
        guard var job = store.job(jobID) else { return }
        job.status = .failed
        job.stage = ""
        job.errorMessage = message
        store.upsert(job, persist: true)
    }
}

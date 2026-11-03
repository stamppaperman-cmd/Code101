import Foundation

/// Where a job is in the pipeline. Decoding and transcription always run;
/// summarizing is skipped (and retryable) when Ollama is unreachable.
enum JobStatus: String, Codable {
    case queued, decoding, transcribing, summarizing, done, failed

    var label: String {
        switch self {
        case .queued: return "รอคิว"
        case .decoding: return "กำลังอ่านไฟล์เสียง"
        case .transcribing: return "กำลังถอดเสียง"
        case .summarizing: return "กำลังสรุป"
        case .done: return "เสร็จแล้ว"
        case .failed: return "ล้มเหลว"
        }
    }

    var isRunning: Bool {
        switch self {
        case .decoding, .transcribing, .summarizing: return true
        default: return false
        }
    }
}

enum LanguageOption: String, Codable, CaseIterable, Identifiable {
    case auto, th, en

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "ตรวจอัตโนมัติ"
        case .th: return "ไทย"
        case .en: return "อังกฤษ"
        }
    }

    /// Whisper language code, or nil to let the model detect it.
    var whisperCode: String? { self == .auto ? nil : rawValue }
}

/// Speed/accuracy trade-off. "Fast" splits on silence and decodes chunks in
/// parallel; "accurate" walks the file in order so each window is conditioned on
/// the text before it, which is what keeps Whisper from drifting mid-conversation.
enum TranscriptionQuality: String, Codable, CaseIterable, Identifiable {
    case fast, accurate

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fast: return "เร็ว"
        case .accurate: return "คำแม่นสูง"
        }
    }

    var detail: String {
        switch self {
        case .fast: return "แบ่งท่อนตามช่วงเงียบ แล้วถอดพร้อมกันหลายท่อน — เก็บเสียงได้ครบกว่า"
        case .accurate: return "โมเดลเต็ม ไล่ตามลำดับ สะกดคำแม่นกว่า แต่ช้ากว่า 3-4 เท่า และเสี่ยงข้ามเสียงบางช่วงมากกว่า"
        }
    }
}

struct Segment: Codable, Identifiable, Hashable {
    var id: Int
    var startMS: Int
    var endMS: Int
    /// Exactly what the ASR model produced. Never overwritten — the cleanup pass
    /// only ever adds `corrected`, so the original is always recoverable.
    var text: String
    /// Spelling-corrected text, present only when the cleanup pass ran and its
    /// reply lined up 1:1 with the raw segments.
    var corrected: String?
    /// Which voice said this, from diarization. Nil when diarization didn't run
    /// or no speaker held the floor for this stretch.
    var speakerId: Int?
    /// Whisper's own average log probability for this segment. Already computed on
    /// every decode and previously thrown away; it is what lets the cleanup pass
    /// spend its time on the lines that are actually doubtful. Nil for transcripts
    /// produced before it was kept.
    var confidence: Double?

    func display(corrected useCorrected: Bool) -> String {
        useCorrected ? (corrected ?? text) : text
    }

    var startLabel: String { Segment.clock(startMS) }

    static func clock(_ ms: Int) -> String {
        let total = ms / 1000
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    static func srtStamp(_ ms: Int) -> String {
        let total = ms / 1000
        return String(format: "%02d:%02d:%02d,%03d", total / 3600, (total % 3600) / 60, total % 60, ms % 1000)
    }
}

/// One voice in a recording. `name` is what the user typed; `guessedName` is what
/// the transcript implied. They are kept apart on purpose — a guess must never be
/// mistaken for something the user confirmed.
struct SpeakerProfile: Codable, Hashable, Identifiable {
    var id: Int
    var talkTimeSec: Double
    var name: String?
    var guessedName: String?
    var evidence: String?

    var displayName: String {
        if let name, !name.isEmpty { return name }
        if let guessedName, !guessedName.isEmpty { return "\(guessedName) (เดา)" }
        return "ผู้พูด \(id + 1)"
    }

    var isConfirmed: Bool { !(name ?? "").isEmpty }

    var talkTimeLabel: String { Segment.clock(Int(talkTimeSec * 1000)) }
}

struct Summary: Codable, Hashable {
    var tldr: String
    var bullets: [String]
    var actions: [String]
    var keywords: [String]
    var model: String
    var createdAt: Date
    /// Facts in the summary that could not be found in the transcript.
    /// Optional so summaries written before this check still decode.
    var warnings: [String]?
    /// Every bullet with the transcript segments it was drawn from. Parallel to
    /// `bullets` rather than replacing it, so a summary written before citations
    /// existed still decodes and still renders.
    var citedBullets: [Claim]?
    /// The same for `actions`.
    var citedActions: [Claim]?
    /// Warnings that know where to look. `warnings` says a fact is missing;
    /// these say which segment claimed it.
    var locatedWarnings: [LocatedWarning]?
}

struct Job: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var filename: String
    var sourcePath: String
    var durationSec: Double = 0
    var language: LanguageOption = .auto
    /// The language actually used for decoding, after one-time detection.
    var detectedLanguage: String?
    var quality: TranscriptionQuality?
    var speakers: [SpeakerProfile]?
    /// SHA-256 of the source file, so dropping the same recording twice is caught
    /// before it costs another hour rather than after.
    var sourceHash: String?
    /// When processing actually began, so elapsed time survives a redraw.
    var startedAt: Date?
    var currentStage: PipelineStage?
    /// Seconds still expected, refreshed as each stage reports in.
    var etaSeconds: Double?
    /// Seconds spent in each pipeline stage, so a change that claims to be faster
    /// can be checked against the previous run instead of taken on trust.
    var timings: [String: Double]?
    var asrModel: String = ""
    var status: JobStatus = .queued
    var stage: String = ""
    var progress: Double = 0
    var errorMessage: String?
    var summaryError: String?
    var createdAt: Date = Date()
    var finishedAt: Date?
    var segments: [Segment] = []
    var summary: Summary?
    /// Questions asked of this recording, newest last. Kept on the job so an answer
    /// and the evidence behind it survive a relaunch the same way the summary does.
    var answers: [GroundedAnswer]?

    var durationLabel: String {
        guard durationSec > 0 else { return "—" }
        return Segment.clock(Int(durationSec * 1000))
    }

    var hasSpeakers: Bool { !(speakers ?? []).isEmpty }

    var elapsedSeconds: Double? {
        guard let startedAt else { return nil }
        return (finishedAt ?? Date()).timeIntervalSince(startedAt)
    }

    var elapsedLabel: String? {
        elapsedSeconds.map(StageRates.clock)
    }

    var etaLabel: String? {
        guard status.isRunning, let etaSeconds, etaSeconds > 0 else { return nil }
        return StageRates.humanReadable(etaSeconds)
    }

    /// Share of the audio that ended up inside a transcript segment. Whisper can
    /// skip stretches without saying so, so this is measured and surfaced rather
    /// than assumed to be 100%.
    var coverage: Double? {
        guard durationSec > 0, !segments.isEmpty else { return nil }
        let covered = segments.reduce(0.0) { $0 + Double(max($1.endMS - $1.startMS, 0)) / 1000 }
        return min(covered / durationSec, 1)
    }

    /// Stretches longer than 8 seconds with no transcript at all.
    var gaps: [(start: Int, end: Int)] {
        var result = [(Int, Int)]()
        var previousEnd = 0
        for segment in segments.sorted(by: { $0.startMS < $1.startMS }) {
            if segment.startMS - previousEnd > 8_000 {
                result.append((previousEnd, segment.startMS))
            }
            previousEnd = max(previousEnd, segment.endMS)
        }
        return result
    }

    /// Stage timings in pipeline order, formatted for display.
    var timingSummary: [(stage: String, seconds: Double)] {
        let order = PipelineStage.allCases.map(\.label)
        guard let timings else { return [] }
        return order.compactMap { key in
            guard let value = timings[key] else { return nil }
            return (key, value)
        }
    }

    var totalSeconds: Double { (timings ?? [:]).values.reduce(0, +) }

    /// How many times faster than realtime the whole pipeline ran.
    var speedFactor: Double? {
        guard durationSec > 0, totalSeconds > 0 else { return nil }
        return durationSec / totalSeconds
    }

    /// The voice that holds the floor longest — usually the interviewee.
    var mainSpeaker: SpeakerProfile? { speakers?.first }

    func speaker(_ id: Int?) -> SpeakerProfile? {
        guard let id else { return nil }
        return speakers?.first { $0.id == id }
    }

    /// Transcript with each line attributed, for reading and for feeding the summarizer.
    func attributedText(corrected: Bool) -> String {
        segments.map { segment in
            let who = speaker(segment.speakerId)?.displayName ?? "ไม่ระบุ"
            return "[\(segment.startLabel)] \(who): \(segment.display(corrected: corrected))"
        }.joined(separator: "\n")
    }

    /// True once the cleanup pass has produced usable corrections.
    var hasCorrections: Bool {
        segments.contains { $0.corrected != nil }
    }

    var fullText: String { fullText(corrected: false) }

    func fullText(corrected: Bool) -> String {
        segments.map { $0.display(corrected: corrected) }.joined(separator: " ")
    }

    func timestampedText(corrected: Bool) -> String {
        segments.map { "[\($0.startLabel)] \($0.display(corrected: corrected))" }.joined(separator: "\n")
    }

    func srt(corrected: Bool) -> String {
        segments.enumerated().map { index, seg in
            "\(index + 1)\n\(Segment.srtStamp(seg.startMS)) --> \(Segment.srtStamp(seg.endMS))\n\(seg.display(corrected: corrected))\n"
        }.joined(separator: "\n")
    }

    /// The timestamps a claim cites, rendered as `[12:34]` so an exported summary
    /// stays checkable after it leaves the app — a bullet that names its moment can
    /// be verified against the recording by anyone, without EchoNote.
    private func stamps(for claim: Claim) -> String {
        let labels = claim.segmentIds
            .compactMap { id in segments.first { $0.id == id }?.startLabel }
        guard !labels.isEmpty else { return "" }
        return " " + labels.map { "[\($0)]" }.joined(separator: " ")
    }

    private func markdownLines(_ claims: [Claim]?, fallback: [String], prefix: String) -> String {
        if let claims, !claims.isEmpty {
            return claims.map { "\(prefix)\($0.text)\(stamps(for: $0))" }.joined(separator: "\n")
        }
        return fallback.map { "\(prefix)\($0)" }.joined(separator: "\n")
    }

    var summaryMarkdown: String {
        guard let summary else { return "" }
        var out = "# สรุป: \(filename)\n\n"
        out += "> \(summary.tldr)\n\n"
        if !summary.bullets.isEmpty {
            out += "## ประเด็นสำคัญ\n"
                + markdownLines(summary.citedBullets, fallback: summary.bullets, prefix: "- ") + "\n\n"
        }
        if !summary.actions.isEmpty {
            out += "## สิ่งที่ต้องทำต่อ\n"
                + markdownLines(summary.citedActions, fallback: summary.actions, prefix: "- [ ] ") + "\n\n"
        }
        if !summary.keywords.isEmpty {
            out += "## คำสำคัญ\n" + summary.keywords.joined(separator: " · ") + "\n\n"
        }
        if let located = summary.locatedWarnings, !located.isEmpty {
            out += "## ⚠️ ต้องตรวจสอบ\n"
            out += "ข้อความเหล่านี้มีตัวเลขหรือวันที่ซึ่งไม่ตรงกับต้นฉบับ เวลาในวงเล็บคือบรรทัดที่ถูกอ้าง\n"
            for warning in located {
                let labels = warning.segmentIds
                    .compactMap { id in segments.first { $0.id == id }?.startLabel }
                    .map { "[\($0)]" }.joined(separator: " ")
                out += "- \(warning.summary)\(labels.isEmpty ? "" : " — " + labels)\n"
                for quote in warning.quotes { out += "  - ต้นฉบับ: \u{201C}\(quote)\u{201D}\n" }
            }
            out += "\n"
        } else if let warnings = summary.warnings, !warnings.isEmpty {
            out += "## ⚠️ ต้องตรวจสอบ\n"
            out += "ตัวเลขและวันเหล่านี้อยู่ในสรุป แต่ไม่มีในข้อความถอดเสียง ควรฟังเสียงจริงก่อนนำไปใช้\n"
            out += warnings.map { "- \($0)" }.joined(separator: "\n") + "\n\n"
        }
        if let share = Citations.groundedShare((summary.citedBullets ?? []) + (summary.citedActions ?? [])) {
            out += "_\(Int(share * 100))% ของข้อสรุปมีบรรทัดอ้างอิง_\n\n"
        }
        out += "---\n\nถอดเสียงด้วย \(asmLabel) · สรุปด้วย \(summary.model) · \(DateFormatter.localizedString(from: summary.createdAt, dateStyle: .medium, timeStyle: .short))\n"
        return out
    }

    private var asmLabel: String { asrModel.isEmpty ? "WhisperKit" : asrModel }
}

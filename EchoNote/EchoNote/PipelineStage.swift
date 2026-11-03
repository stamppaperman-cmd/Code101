import Foundation

/// The pipeline as one ordered list, so the progress bar and the time estimate
/// read from the same source. Stages previously carried hand-written weights that
/// overlapped — gap-filling and diarization both wrote into 0.55–0.57 — which made
/// the bar jump backwards.
enum PipelineStage: String, Codable, CaseIterable {
    case decode, transcribe, fillGaps, diarize, correct, index, summarize

    var label: String {
        switch self {
        case .decode: return "อ่านไฟล์"
        case .transcribe: return "ถอดเสียง"
        case .fillGaps: return "เก็บตก"
        case .diarize: return "แยกผู้พูด"
        case .correct: return "เกลาคำ"
        case .index: return "ทำดัชนีค้นหา"
        case .summarize: return "สรุป"
        }
    }

    /// Share of the progress bar. Roughly proportional to real time so the bar
    /// moves at a steady pace instead of racing then stalling.
    var weight: Double {
        switch self {
        case .decode: return 0.04
        case .transcribe: return 0.44
        case .fillGaps: return 0.07
        case .diarize: return 0.11
        case .correct: return 0.17
        case .index: return 0.05
        case .summarize: return 0.12
        }
    }

    /// Where this stage begins on the bar.
    var start: Double {
        PipelineStage.allCases.prefix { $0 != self }.reduce(0) { $0 + $1.weight }
    }

    func progress(_ fraction: Double) -> Double {
        start + min(max(fraction, 0), 1) * weight
    }

    /// Seconds of work per second of audio, seeded from measurements taken on an
    /// M5 with a 64-minute Thai interview. Replaced by the machine's own numbers
    /// as soon as it has run a job.
    func defaultRate(quality: TranscriptionQuality) -> Double {
        switch self {
        case .decode: return 0.01
        // Measured 2026-09-06 on the 64-minute interview, after gap recovery
        // started returning the text the first pass used to drop.
        case .transcribe: return quality == .accurate ? 0.857 : 0.118
        case .fillGaps: return 0.235
        case .diarize: return 0.069
        // Only the least confident quarter of the segments now goes to the model.
        case .correct: return 0.060
        case .index: return 0.010
        case .summarize: return 0.112
        }
    }
}

/// Learns how long each stage actually takes on this machine and uses that to
/// answer "how much longer?" — the question a 30-minute job raises every minute.
enum StageRates {
    private static func key(_ stage: PipelineStage, _ quality: TranscriptionQuality) -> String {
        "rate.\(stage.rawValue).\(quality.rawValue)"
    }

    /// Blends the new measurement with what we knew, so one odd run cannot throw
    /// the estimate off but a real change is picked up within a few jobs.
    static func record(stage: PipelineStage, quality: TranscriptionQuality,
                       seconds: Double, audioSeconds: Double) {
        guard audioSeconds > 1, seconds > 0 else { return }
        let observed = seconds / audioSeconds
        let stored = UserDefaults.standard.double(forKey: key(stage, quality))
        let blended = stored > 0 ? stored * 0.6 + observed * 0.4 : observed
        UserDefaults.standard.set(blended, forKey: key(stage, quality))
    }

    static func rate(stage: PipelineStage, quality: TranscriptionQuality) -> Double {
        let stored = UserDefaults.standard.double(forKey: key(stage, quality))
        return stored > 0 ? stored : stage.defaultRate(quality: quality)
    }

    /// Seconds still to go: what is left of the current stage, plus every stage after it.
    static func remainingSeconds(after stage: PipelineStage, fraction: Double,
                                 audioSeconds: Double, quality: TranscriptionQuality,
                                 skipping skipped: Set<PipelineStage>) -> Double {
        var total = (1 - min(max(fraction, 0), 1)) * rate(stage: stage, quality: quality) * audioSeconds
        var reached = false
        for candidate in PipelineStage.allCases {
            if candidate == stage { reached = true; continue }
            guard reached, !skipped.contains(candidate) else { continue }
            total += rate(stage: candidate, quality: quality) * audioSeconds
        }
        return total
    }

    static func humanReadable(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "—" }
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total) วิ" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes) นาที" }
        return "\(minutes / 60) ชม. \(minutes % 60) นาที"
    }

    static func clock(_ seconds: Double) -> String {
        let total = Int(max(seconds, 0))
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }
}

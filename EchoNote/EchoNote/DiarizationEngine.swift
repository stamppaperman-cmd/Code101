import Foundation
import SpeakerKit
// WhisperKit re-exports ArgmaxCore, where ModelDownloadConfig lives; SpeakerKit does not.
import WhisperKit

struct SpeakerSpan: Sendable {
    let start: Double
    let end: Double
    let speaker: Int
}

enum DiarizationError: LocalizedError {
    case notLoaded
    var errorDescription: String? { "ยังไม่ได้โหลดโมเดลแยกเสียงผู้พูด" }
}

/// Speaker diarization — who spoke when — via SpeakerKit's Pyannote models.
/// Same package as WhisperKit, MIT licensed, and runs entirely on device.
actor DiarizationEngine {
    static let shared = DiarizationEngine()

    private var kit: SpeakerKit?

    private static var downloadBase: String {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = support.appendingPathComponent("EchoNote/models", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    func load(offline: Bool, onStage: @escaping @Sendable (String) -> Void) async throws {
        if kit != nil { return }
        onStage(offline ? "กำลังเตรียมโมเดลแยกเสียงผู้พูดจากในเครื่อง"
                        : "กำลังเตรียมโมเดลแยกเสียงผู้พูด — ครั้งแรกต้องดาวน์โหลด")
        let config = PyannoteConfig(
            modelDownloadConfig: ModelDownloadConfig(downloadBase: Self.downloadBase,
                                                     modelRepo: "argmaxinc/speakerkit-coreml"),
            download: !offline,
            load: true,
            verbose: false,
            logLevel: .error
        )
        kit = try await SpeakerKit(config)
    }

    func diarize(samples: [Float],
                 onProgress: @escaping @Sendable (Double) -> Void) async throws -> [SpeakerSpan] {
        guard let kit else { throw DiarizationError.notLoaded }
        let result = try await kit.diarize(audioArray: samples, options: nil) { progress in
            onProgress(progress.fractionCompleted)
        }
        return result.segments.compactMap { segment in
            guard let id = segment.speaker.speakerId else { return nil }
            return SpeakerSpan(start: Double(segment.startTime),
                               end: Double(segment.endTime),
                               speaker: id)
        }
    }

    func unload() async {
        await kit?.unloadModels()
        kit = nil
    }
}

enum SpeakerAssignment {
    /// A transcript segment can straddle a hand-over, so it goes to whichever
    /// speaker actually holds the floor for most of it.
    static func apply(spans: [SpeakerSpan], to segments: inout [Segment]) {
        guard !spans.isEmpty else { return }
        for index in segments.indices {
            let start = Double(segments[index].startMS) / 1000
            let end = Double(segments[index].endMS) / 1000
            var best: (speaker: Int, overlap: Double)?
            for span in spans {
                let overlap = min(end, span.end) - max(start, span.start)
                guard overlap > 0 else { continue }
                if overlap > (best?.overlap ?? 0) { best = (span.speaker, overlap) }
            }
            segments[index].speakerId = best?.speaker
        }
    }

    /// Total seconds held by each speaker, biggest talker first.
    static func profiles(spans: [SpeakerSpan]) -> [SpeakerProfile] {
        var totals = [Int: Double]()
        for span in spans {
            totals[span.speaker, default: 0] += max(span.end - span.start, 0)
        }
        return totals
            .map { SpeakerProfile(id: $0.key, talkTimeSec: $0.value) }
            .sorted { $0.talkTimeSec > $1.talkTimeSec }
    }
}

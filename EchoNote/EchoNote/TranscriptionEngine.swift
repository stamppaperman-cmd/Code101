import Foundation
import WhisperKit

enum TranscriptionError: LocalizedError {
    case notLoaded
    case empty
    case modelMissing(String)

    var errorDescription: String? {
        switch self {
        case .notLoaded: return "ยังไม่ได้โหลดโมเดลถอดเสียง ลองกดทำใหม่"
        case .empty: return "ไม่พบเสียงพูดในไฟล์นี้ อาจเป็นไฟล์เงียบหรือมีแต่เสียงดนตรี"
        case .modelMissing(let name):
            return "โหมดปิดระบบเปิดอยู่ และยังไม่มีโมเดล \(name) ในเครื่อง — ปิดโหมดปิดระบบเพื่อโหลด หรือคัดลอกโฟลเดอร์โมเดลมาวางเอง"
        }
    }
}

/// Thread-safe progress relay for WhisperKit's `@Sendable` segment callback,
/// which fires from arbitrary worker threads and out of order.
private final class ProgressRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var furthest: Double = 0
    private let duration: Double
    private let report: @Sendable (Double) -> Void

    init(duration: Double, report: @escaping @Sendable (Double) -> Void) {
        self.duration = duration
        self.report = report
    }

    func saw(end seconds: Double) {
        guard duration > 0 else { return }
        lock.lock()
        let fraction = min(seconds / duration, 1)
        let isNewMax = fraction > furthest + 0.005
        if isNewMax { furthest = fraction }
        lock.unlock()
        if isNewMax { report(fraction) }
    }
}

/// Owns the single WhisperKit pipeline. An actor because the model is expensive
/// to load and must not be built twice concurrently.
actor TranscriptionEngine {
    static let shared = TranscriptionEngine()

    private var pipe: WhisperKit?
    private var loadedModel: String?
    private var loadedQuality: TranscriptionQuality?

    var currentModel: String? { loadedModel }

    /// WhisperKit reports what it spent on every call and this app used to discard it.
    /// Kept per stage because the two stages answer different questions: `transcribe`
    /// is the one being tuned, `fillGaps` is the cost of the first one having failed.
    private(set) var lastTranscribeTimings: RunTimings?
    private(set) var lastGapTimings: RunTimings?

    /// Models that only ever transcribe English. `distil-whisper` is distilled
    /// from English data and `.en` variants are trained English-only — either one
    /// silently produces garbage for Thai, so neither may be auto-selected.
    private static func isMultilingual(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return !lowered.contains("distil") && !lowered.contains(".en") && !lowered.hasSuffix("_en")
    }

    /// Picks the best multilingual model this Mac can run. Turbo has a distilled
    /// decoder that is noticeably weaker outside English, so accurate mode asks
    /// for the full large-v3 instead.
    /// Models already on disk, found without touching the network.
    static func localModels() -> [String] {
        let root = downloadBase.appendingPathComponent("models/argmaxinc/whisperkit-coreml", isDirectory: true)
        let contents = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return contents
            .filter { $0.hasDirectoryPath }
            .map { $0.lastPathComponent }
            .filter { !$0.hasPrefix(".") }
    }

    private func resolveModelName(quality: TranscriptionQuality, offline: Bool) async -> String {
        let fallback = quality == .accurate
            ? "openai_whisper-large-v3"
            : "openai_whisper-large-v3-v20240930_turbo"
        // Offline mode must not reach for the catalogue — that is a network call.
        let catalogue = offline ? Self.localModels() : (try? await WhisperKit.fetchAvailableModels())
        guard let all = catalogue, !all.isEmpty else {
            return fallback
        }
        let available = all.filter(Self.isMultilingual)
        guard !available.isEmpty else { return fallback }

        let rules: [(String) -> Bool] = quality == .accurate
            ? [
                { $0.contains("large-v3") && !$0.contains("turbo") },
                { $0.contains("large") && !$0.contains("turbo") },
                { $0.contains("large-v3") },
                { $0.contains("medium") },
                { $0.contains("small") },
              ]
            : [
                { $0.contains("large-v3") && $0.contains("turbo") },
                { $0.contains("large-v3") },
                { $0.contains("large") },
                { $0.contains("medium") },
                { $0.contains("small") },
                { $0.contains("base") },
              ]
        for rule in rules {
            if let match = available.first(where: rule) { return match }
        }
        return available.first ?? fallback
    }

    /// Keeps model weights beside the app's own data instead of cluttering ~/Documents,
    /// which is where WhisperKit's HubApi puts them by default.
    private static var downloadBase: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = support.appendingPathComponent("EchoNote/models", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    func load(quality: TranscriptionQuality,
              offline: Bool,
              onStage: @escaping @Sendable (String) -> Void) async throws -> String {
        if let loadedModel, pipe != nil, loadedQuality == quality { return loadedModel }
        if loadedQuality != quality { await unload() }

        onStage("กำลังเลือกโมเดล…")
        let name = await resolveModelName(quality: quality, offline: offline)

        let folder: URL
        if offline {
            let local = Self.downloadBase
                .appendingPathComponent("models/argmaxinc/whisperkit-coreml", isDirectory: true)
                .appendingPathComponent(name, isDirectory: true)
            guard FileManager.default.fileExists(atPath: local.path) else {
                throw TranscriptionError.modelMissing(name)
            }
            folder = local
        } else {
            // Downloading separately from WhisperKit's init is what makes a real
            // percentage available; init alone reports nothing for several minutes.
            folder = try await WhisperKit.download(variant: name,
                                                   downloadBase: Self.downloadBase) { progress in
                let percent = Int(progress.fractionCompleted * 100)
                onStage("กำลังดาวน์โหลดโมเดล \(name) — \(percent)%")
            }
        }

        // Compiling a 2.9 GB model is minutes of silence with a process that has
        // died here before; the log should show which side of it we are on.
        log("loading model \(name) (\(quality.rawValue), offline=\(offline))")
        AppLog.shared.flush()
        onStage("กำลังคอมไพล์โมเดลให้เข้ากับชิป — ครั้งแรกใช้เวลา 1-3 นาที")
        let config = WhisperKitConfig(model: name,
                                      modelFolder: folder.path,
                                      verbose: false,
                                      logLevel: .error,
                                      prewarm: false,
                                      load: true,
                                      download: false)
        pipe = try await WhisperKit(config)
        loadedModel = name
        loadedQuality = quality
        log("model \(name) ready")
        return name
    }

    /// Whisper re-detects the language for every window when detection is left on.
    /// One muffled passage in a Thai interview gets labelled English, and the model
    /// then writes fluent English sentences that were never spoken. Detecting once
    /// across several points in the file and forcing that language stops it.
    func detectDominantLanguage(samples: [Float]) async throws -> String {
        guard let pipe else { throw TranscriptionError.notLoaded }
        let window = Int(AudioDecoder.sampleRate) * 30
        guard samples.count > window else {
            return try await pipe.detectLangauge(audioArray: samples).language
        }

        let probes = min(5, max(2, samples.count / (window * 4)))
        var votes = [String: Int]()
        for index in 0..<probes {
            let start = (samples.count - window) * index / max(probes - 1, 1)
            let slice = Array(samples[start..<(start + window)])
            guard let language = try? await pipe.detectLangauge(audioArray: slice).language else { continue }
            votes[language, default: 0] += 1
        }
        guard let winner = votes.max(by: { ($0.value, $1.key) < ($1.value, $0.key) })?.key else {
            return try await pipe.detectLangauge(audioArray: Array(samples[0..<window])).language
        }
        return winner
    }

    /// One `transcribe` call over a whole file is a single throw away from losing
    /// everything: a CoreML fault 43 minutes into a 64-minute interview returned no
    /// segments at all and the job was written to disk as failed. The audio is cut
    /// into blocks instead, so a fault costs one block, a retry usually recovers it,
    /// and whatever has been transcribed so far reaches disk as each block lands.
    func transcribe(samples: [Float],
                    duration: Double,
                    language: String,
                    quality: TranscriptionQuality,
                    onPartial: @escaping @Sendable ([Segment]) -> Void = { _ in },
                    onProgress: @escaping @Sendable (Double) -> Void) async throws -> [Segment] {
        guard let pipe else { throw TranscriptionError.notLoaded }

        // Language is now always pinned — never leave detection on per window.
        let options = DecodingOptions(verbose: false,
                                      task: .transcribe,
                                      language: language,
                                      temperature: 0.0,
                                      usePrefillPrompt: true,
                                      detectLanguage: false,
                                      skipSpecialTokens: true,
                                      withoutTimestamps: false,
                                      wordTimestamps: false,
                                      concurrentWorkerCount: quality == .accurate ? 1 : 4,
                                      chunkingStrategy: quality == .accurate ? .none : .vad)

        let rate = AudioDecoder.sampleRate
        let relay = ProgressRelay(duration: duration, report: onProgress)
        let blocks = AudioBlocks.blockRanges(sampleCount: samples.count, sampleRate: rate) { target, radius in
            AudioBlocks.quietestCut(in: samples, near: target, radius: radius, sampleRate: rate)
        }
        log("transcribe: \(String(format: "%.1f", duration / 60)) min, \(blocks.count) block(s), lang=\(language), \(quality.rawValue)")

        var collected = [Segment]()
        var lastError: Error?
        var timings = RunTimings()

        for (index, block) in blocks.enumerated() {
            let offset = Double(block.lowerBound) / rate
            let slice = blocks.count == 1 ? samples : Array(samples[block])

            // Written before the call, not after: this is the line that survives if
            // the process is killed rather than returning.
            log("  block \(index + 1)/\(blocks.count) starting at \(Int(offset))s (\(slice.count / Int(rate))s)")
            AppLog.shared.flush()

            var produced: [TranscriptionResult]?
            let blockStarted = Date()
            for attempt in 0..<2 {
                do {
                    produced = try await pipe.transcribe(audioArray: slice,
                                                         decodeOptions: options,
                                                         callback: nil,
                                                         segmentCallback: { discovered in
                        if let furthest = discovered.map(\.end).max() {
                            relay.saw(end: offset + Double(furthest))
                        }
                    })
                    break
                } catch {
                    // CoreML faults mid-file often enough to plan for
                    // ("Unable to compute the asynchronous prediction"). One retry
                    // clears it; a second failure leaves this stretch to fillGaps
                    // rather than discarding every block that already succeeded.
                    lastError = error
                    log("  block \(index + 1) attempt \(attempt + 1) failed: \(error.localizedDescription)")
                    if attempt == 0 { try? await Task.sleep(nanoseconds: 2_000_000_000) }
                }
            }
            // Measured around the attempts, not around the successful one: a block that
            // failed once and succeeded on retry really did cost that time.
            timings.wallSeconds += Date().timeIntervalSince(blockStarted)

            if let produced {
                timings.absorb(produced)
                let before = collected.count
                for piece in produced.flatMap(\.segments).sorted(by: { $0.start < $1.start }) {
                    let text = piece.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    collected.append(Segment(id: collected.count,
                                             startMS: Int((offset + Double(piece.start)) * 1000),
                                             endMS: Int((offset + Double(piece.end)) * 1000),
                                             text: text,
                                             confidence: Double(piece.avgLogprob)))
                }
                log("  block \(index + 1) done: +\(collected.count - before) segments")
                onPartial(collected)
            } else {
                // A skipped block is the failure mode that used to be invisible.
                log("  block \(index + 1) SKIPPED after 2 attempts — left to fillGaps")
            }
            relay.saw(end: Double(block.upperBound) / rate)
        }

        // Recorded before the guard so a run that produced nothing still says how long
        // it spent producing nothing.
        lastTranscribeTimings = timings
        log("transcribe timings: \(timings.summary)")

        guard !collected.isEmpty else { throw lastError ?? TranscriptionError.empty }
        onProgress(1)
        return collected.sorted { $0.startMS < $1.startMS }
            .enumerated()
            .map { index, segment in
                var renumbered = segment
                renumbered.id = index
                return renumbered
            }
    }

    /// Whisper skips audio without saying so.
    ///
    /// WhisperKit clamps the decode loop to `Constants.maxTokenContext - 1` (223) —
    /// half of Whisper's 448-token context — and that cap cannot be raised from
    /// outside the package. Thai costs two to three tokens per character, so a dense
    /// 30-second window exhausts the budget, decoding stops mid-word, and the rest of
    /// that window is never transcribed. Measured on a 64-minute Thai interview:
    /// 26% of the audio produced no text at all, across 32 separate stretches.
    ///
    /// Rather than fork the package, this finds the stretches that produced nothing
    /// and transcribes each one on its own. A short slice starts its token budget
    /// from zero, so the text that the first pass dropped comes back.
    func fillGaps(samples: [Float],
                  duration: Double,
                  segments: [Segment],
                  language: String,
                  onProgress: @escaping @Sendable (Double, Int) -> Void) async throws -> [Segment] {
        guard let pipe, duration > 0, !segments.isEmpty else { return segments }

        let gaps = AudioBlocks.uncoveredRanges(in: segments, duration: duration, minimumSeconds: 6)
        guard !gaps.isEmpty else { return segments }

        let options = DecodingOptions(verbose: false,
                                      task: .transcribe,
                                      language: language,
                                      temperature: 0.0,
                                      usePrefillPrompt: true,
                                      detectLanguage: false,
                                      skipSpecialTokens: true,
                                      withoutTimestamps: false,
                                      wordTimestamps: false,
                                      concurrentWorkerCount: 2,
                                      chunkingStrategy: .vad)

        let rate = AudioDecoder.sampleRate
        var recovered = [Segment]()
        var timings = RunTimings()
        for (index, gap) in gaps.enumerated() {
            let from = max(Int(gap.start * rate), 0)
            let to = min(Int(gap.end * rate), samples.count)
            guard to - from > Int(rate) else { continue }

            let slice = Array(samples[from..<to])
            let gapStarted = Date()
            let attempt = try? await pipe.transcribe(audioArray: slice, decodeOptions: options)
            timings.wallSeconds += Date().timeIntervalSince(gapStarted)
            guard let results = attempt else { continue }
            timings.absorb(results)

            for piece in results.flatMap(\.segments) {
                let text = piece.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                recovered.append(Segment(id: 0,
                                         startMS: Int((gap.start + Double(piece.start)) * 1000),
                                         endMS: Int((gap.start + Double(piece.end)) * 1000),
                                         text: text,
                                         confidence: Double(piece.avgLogprob)))
            }
            onProgress(Double(index + 1) / Double(gaps.count), recovered.count)
        }

        lastGapTimings = timings
        log("fillGaps: \(gaps.count) gap(s), recovered \(recovered.count) segments")
        log("fillGaps timings: \(timings.summary)")
        guard !recovered.isEmpty else { return segments }
        let merged = (segments + recovered).sorted { $0.startMS < $1.startMS }
        return merged.enumerated().map { index, segment in
            var renumbered = segment
            renumbered.id = index
            return renumbered
        }
    }

    func unload() async {
        if let pipe { await pipe.unloadModels() }
        pipe = nil
        loadedModel = nil
        loadedQuality = nil
    }
}

/// The bridge from WhisperKit's own accounting into `RunTimings`. It lives here rather
/// than beside the struct so that `Metrics.swift` stays free of WhisperKit and its
/// tests keep running without a 2.9 GB model on disk.
///
/// One result per VAD chunk arrives on the chunked path and a single result on the
/// sequential one, so summing is correct for both — and the difference between the
/// summed `fullPipeline` and the wall clock measured around the call is exactly the
/// parallelism that `concurrentWorkerCount` is supposed to buy.
private extension RunTimings {
    mutating func absorb(_ results: [TranscriptionResult]) {
        for result in results {
            let measured = result.timings
            add(audioSeconds: measured.inputAudioSeconds,
                pipeline: measured.fullPipeline,
                encoding: measured.encoding,
                decodingLoop: measured.decodingLoop,
                logmels: measured.logmels,
                fallbacks: measured.totalDecodingFallbacks,
                windows: measured.totalDecodingWindows)
        }
    }
}

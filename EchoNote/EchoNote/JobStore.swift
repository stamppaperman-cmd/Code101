import Foundation
import SwiftUI

/// Jobs live as plain files under Application Support so the transcript and the
/// summary stay readable by any other app even if EchoNote is gone.
///
///   ~/Library/Application Support/EchoNote/jobs/<uuid>/
///       job.json  raw.json  transcript.txt  transcript_timestamps.txt
///       transcript.srt  summary.md
@MainActor
@Observable
final class JobStore {
    private(set) var jobs: [Job] = []

    let root: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        root = support.appendingPathComponent("EchoNote/jobs", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        load()
    }

    func folder(for job: Job) -> URL {
        let url = root.appendingPathComponent(job.id.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func job(_ id: UUID) -> Job? { jobs.first { $0.id == id } }

    func upsert(_ job: Job, persist: Bool = false) {
        if let index = jobs.firstIndex(where: { $0.id == job.id }) {
            jobs[index] = job
        } else {
            jobs.insert(job, at: 0)
        }
        if persist { save(job) }
    }

    func delete(_ job: Job) {
        jobs.removeAll { $0.id == job.id }
        try? FileManager.default.removeItem(at: root.appendingPathComponent(job.id.uuidString))
    }

    // MARK: - Persistence

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let contents = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        var repaired = [Job]()
        jobs = contents.compactMap { directory in
            let file = directory.appendingPathComponent("job.json")
            guard let data = try? Data(contentsOf: file) else { return nil }
            guard var job = try? decoder.decode(Job.self, from: data) else { return nil }
            let originalStatus = job.status
            if job.status.isRunning {
                if job.summary != nil {
                    // Finished work whose final write never landed — the results are
                    // on disk, so recover it as done instead of crying failure.
                    job.status = .done
                } else if !job.segments.isEmpty {
                    job.status = .done
                    job.summaryError = "ปิดแอปก่อนสรุปเสร็จ — ข้อความถอดเสียงอยู่ครบ กด \"สรุปใหม่\" ได้เลย"
                } else {
                    job.status = .failed
                    job.errorMessage = "ปิดแอปตอนยังทำไม่เสร็จ — กด \"ทำใหม่\" เพื่อเริ่มรอบใหม่"
                }
            }
            // Write the repair back so disk and memory agree — otherwise every
            // launch re-repairs the same jobs and anything reading the files
            // still sees a status that is no longer true.
            if job.status != originalStatus { repaired.append(job) }
            return job
        }
        .sorted { $0.createdAt > $1.createdAt }

        repaired.forEach(save)
    }

    private func save(_ job: Job) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(job) else { return }
        try? data.write(to: folder(for: job).appendingPathComponent("job.json"), options: .atomic)
    }

    /// Written as soon as transcription lands, before summarizing is attempted —
    /// a failed summary never costs you the transcript.
    func writeTranscript(_ job: Job) {
        let directory = folder(for: job)
        write(job.fullText(corrected: false), to: directory.appendingPathComponent("transcript.txt"))
        write(job.timestampedText(corrected: false), to: directory.appendingPathComponent("transcript_timestamps.txt"))
        write(job.srt(corrected: false), to: directory.appendingPathComponent("transcript.srt"))

        // The cleaned-up text is written alongside the raw one, never over it.
        if job.hasCorrections {
            write(job.fullText(corrected: true), to: directory.appendingPathComponent("transcript_corrected.txt"))
            write(job.timestampedText(corrected: true), to: directory.appendingPathComponent("transcript_corrected_timestamps.txt"))
            write(job.srt(corrected: true), to: directory.appendingPathComponent("transcript_corrected.srt"))
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        if let data = try? encoder.encode(job.segments) {
            try? data.write(to: directory.appendingPathComponent("raw.json"), options: .atomic)
        }
        save(job)
    }

    /// Vectors live beside the transcript, not inside `job.json` — they are a
    /// megabyte of numbers nobody reads, and `job.json` is written on every 5% step.
    func writeIndex(_ index: RetrievalIndex, for job: Job) {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(index) else { return }
        try? data.write(to: folder(for: job).appendingPathComponent("embeddings.json"), options: .atomic)
    }

    func readIndex(for job: Job) -> RetrievalIndex? {
        let url = folder(for: job).appendingPathComponent("embeddings.json")
        guard let data = try? Data(contentsOf: url),
              let index = try? JSONDecoder().decode(RetrievalIndex.self, from: data) else { return nil }
        // A transcript that has changed since the vectors were built would retrieve
        // the wrong lines and cite them confidently.
        guard index.segmentCount == job.segments.count else { return nil }
        return index
    }

    func writeSummary(_ job: Job) {
        guard job.summary != nil else { return }
        write(job.summaryMarkdown, to: folder(for: job).appendingPathComponent("summary.md"))
        save(job)
    }

    private func write(_ string: String, to url: URL) {
        try? string.data(using: .utf8)?.write(to: url, options: .atomic)
    }
}

import Foundation
import AVFoundation
import SwiftUI

/// A citation in a text-only tool can only ever point at more text. This app has the
/// recording, so a citation can point at the moment itself — which is the one check
/// that survives a transcription error, because the transcript is not the evidence,
/// the audio is.
@MainActor
@Observable
final class AudioPreview {
    static let shared = AudioPreview()

    private var player: AVPlayer?
    private var sourcePath: String?
    private(set) var playingSegmentId: Int?

    /// Stop after this much, so clicking a citation is a check rather than a
    /// commitment to listen to the rest of the interview.
    private var stopWork: DispatchWorkItem?

    func play(job: Job, segment: Segment, seconds: Double = 12) {
        guard FileManager.default.fileExists(atPath: job.sourcePath) else { return }
        if sourcePath != job.sourcePath {
            player = AVPlayer(url: URL(fileURLWithPath: job.sourcePath))
            sourcePath = job.sourcePath
        }
        guard let player else { return }

        stopWork?.cancel()
        let start = max(Double(segment.startMS) / 1000 - 0.4, 0)
        player.seek(to: CMTime(seconds: start, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
        playingSegmentId = segment.id

        let span = max(Double(segment.endMS - segment.startMS) / 1000, 2)
        let work = DispatchWorkItem { [weak self] in
            self?.stop()
        }
        stopWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + min(span + 1, seconds), execute: work)
    }

    func stop() {
        stopWork?.cancel()
        stopWork = nil
        player?.pause()
        playingSegmentId = nil
    }
}

/// The clickable `[12:34]` that a citation renders as.
struct CitationChip: View {
    let job: Job
    let segment: Segment
    var preview = AudioPreview.shared

    private var isPlaying: Bool { preview.playingSegmentId == segment.id }

    var body: some View {
        Button {
            if isPlaying { preview.stop() } else { preview.play(job: job, segment: segment) }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                    .font(.system(size: 7))
                Text(segment.startLabel)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(isPlaying ? Color.accentColor.opacity(0.28) : Color.accentColor.opacity(0.13),
                        in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(Color.accentColor)
        }
        .buttonStyle(.plain)
        .help(segment.text)
    }
}

/// A statement plus its citations, laid out so the citations read as part of the line.
struct ClaimRow: View {
    let job: Job
    let claim: Claim
    var marker: String = "•"

    private var cited: [Segment] {
        claim.segmentIds.compactMap { id in job.segments.first { $0.id == id } }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(marker).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(claim.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 4) {
                    ForEach(cited, id: \.id) { segment in
                        CitationChip(job: job, segment: segment)
                    }
                    if !claim.isGrounded {
                        Label("ไม่มีที่มา", systemImage: "questionmark.circle")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                    }
                    if claim.hasHallucinatedCitation {
                        Label("อ้างบรรทัดที่ไม่มีจริง", systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.red)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }
}

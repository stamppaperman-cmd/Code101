import SwiftUI

/// The transcript as Whisper produced it, with the cleaned-up text available as an
/// overlay rather than a replacement — the raw copy is what makes every later claim
/// checkable, so it is never the thing that gets hidden by default.
struct RawTranscriptView: View {
    let job: Job
    @Binding var useCorrected: Bool

    private var showCorrected: Bool { job.hasCorrections && useCorrected }

    private var correctedCount: Int {
        job.segments.count { $0.corrected != nil }
    }

    private var countLabel: String {
        let base = "\(job.segments.count) ประโยค · \(job.fullText(corrected: showCorrected).count) ตัวอักษร"
        guard showCorrected, correctedCount > 0 else { return base }
        return base + " · เกลาไป \(correctedCount) บรรทัด"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(countLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if job.hasCorrections {
                    Picker("", selection: $useCorrected) {
                        Text("เกลาคำแล้ว").tag(true)
                        Text("ตามที่ถอดได้").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 200)
                }
                Spacer()
                Button("คัดลอกข้อความล้วน") { Clipboard.copy(job.fullText(corrected: showCorrected)) }
                Button("คัดลอกพร้อมเวลา") { Clipboard.copy(job.timestampedText(corrected: showCorrected)) }
                Button {
                    let document = TranscriptDocument.build(job: job, corrected: showCorrected, parts: [.transcript])
                    FileExport.save(PDFExporter.data(from: document),
                                    suggestedName: (job.filename as NSString).deletingPathExtension + "-transcript.pdf")
                } label: {
                    Label("บันทึก PDF", systemImage: "doc.richtext")
                }
            }
            .controlSize(.small)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(job.segments) { segment in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(segment.startLabel)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(showCorrected && segment.corrected != nil ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                                .frame(width: 58, alignment: .trailing)
                            if job.hasSpeakers {
                                Text(job.speaker(segment.speakerId)?.displayName ?? "—")
                                    .font(.caption)
                                    .foregroundStyle(SpeakerPalette.color(segment.speakerId))
                                    .frame(width: 84, alignment: .leading)
                                    .lineLimit(1)
                            }
                            Text(segment.display(corrected: showCorrected))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                    }
                }
                .padding(16)
            }
        }
    }
}

// MARK: - Summary

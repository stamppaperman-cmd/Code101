import SwiftUI

/// The summary, rendered as claims rather than sentences.
///
/// Every bullet shows the moments it was drawn from, and those moments are buttons:
/// pressing one plays the recording there. That is the whole argument for building
/// this offline instead of using a hosted tool — a citation that points at text can
/// only be checked against the transcription, and the transcription is the part most
/// likely to be wrong.
struct SummaryView: View {
    let model: AppModel
    let job: Job

    var body: some View {
        if let summary = job.summary {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    section("สรุปสั้น", icon: "sparkles") {
                        Text(summary.tldr)
                            .font(.title3)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if !summary.bullets.isEmpty {
                        section("ประเด็นสำคัญ", icon: "list.bullet") {
                            claimList(summary.citedBullets, fallback: summary.bullets, marker: "•")
                        }
                    }

                    if !summary.actions.isEmpty {
                        section("สิ่งที่ต้องทำต่อ", icon: "checklist") {
                            claimList(summary.citedActions, fallback: summary.actions, marker: "☐")
                        }
                    }

                    if let located = summary.locatedWarnings, !located.isEmpty {
                        section("ต้องตรวจสอบ", icon: "exclamationmark.triangle") {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("ข้อความเหล่านี้มีตัวเลขหรือวันที่ซึ่งไม่ตรงกับต้นฉบับ กดที่เวลาเพื่อฟังเสียงจริงตรงบรรทัดที่ถูกอ้าง")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                ForEach(located) { warning in
                                    WarningRow(job: job, warning: warning)
                                }
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                        }
                    } else if let warnings = summary.warnings, !warnings.isEmpty {
                        section("ต้องตรวจสอบ", icon: "exclamationmark.triangle") {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("ตัวเลขและวันเหล่านี้อยู่ในสรุป แต่ไม่มีในข้อความถอดเสียง ควรฟังเสียงจริงก่อนนำไปใช้")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                ForEach(Array(warnings.enumerated()), id: \.offset) { _, warning in
                                    Text("• \(warning)")
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }

                    if let share = Citations.groundedShare((summary.citedBullets ?? []) + (summary.citedActions ?? [])) {
                        Label("\(Int(share * 100))% ของข้อสรุปมีบรรทัดอ้างอิง",
                              systemImage: share > 0.9 ? "checkmark.seal" : "info.circle")
                            .font(.callout)
                            .foregroundStyle(share > 0.9 ? .green : .secondary)
                    }

                    if !summary.keywords.isEmpty {
                        section("คำสำคัญ", icon: "tag") {
                            Text(summary.keywords.joined(separator: "  ·  "))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }

                    HStack {
                        Button("คัดลอกสรุป (Markdown)") { Clipboard.copy(job.summaryMarkdown) }
                        Button {
                            let document = TranscriptDocument.build(job: job, corrected: job.hasCorrections, parts: [.summary])
                            FileExport.save(PDFExporter.data(from: document),
                                            suggestedName: (job.filename as NSString).deletingPathExtension + "-summary.pdf")
                        } label: {
                            Label("บันทึก PDF", systemImage: "doc.richtext")
                        }
                        Button("สรุปใหม่") { model.retrySummary(job) }
                    }
                    .controlSize(.small)
                    .padding(.top, 4)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            VStack(spacing: 14) {
                Image(systemName: "text.book.closed")
                    .font(.system(size: 40, weight: .thin))
                    .foregroundStyle(.secondary)
                Text(job.summaryError ?? "ยังไม่มีสรุป")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 460)
                Button("สรุปใหม่") { model.retrySummary(job) }
                    .disabled(job.segments.isEmpty)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(30)
        }
    }

    private func section<Content: View>(_ title: String, icon: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.headline)
            content()
        }
    }

    /// Renders citations when the summary has them, and the plain sentences when it
    /// does not — a summary made before citations existed still displays.
    @ViewBuilder
    private func claimList(_ claims: [Claim]?, fallback: [String], marker: String) -> some View {
        if let claims, !claims.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(claims) { claim in
                    ClaimRow(job: job, claim: claim, marker: marker)
                }
            }
        } else {
            bulletList(fallback, marker: marker)
        }
    }

    private func bulletList(_ items: [String], marker: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(marker).foregroundStyle(.secondary)
                    Text(item)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
    }
}


/// One audit finding, with the lines it points at.
struct WarningRow: View {
    let job: Job
    let warning: LocatedWarning

    private var cited: [Segment] {
        warning.segmentIds.compactMap { id in job.segments.first { $0.id == id } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(warning.severity)
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(warning.missing.isEmpty ? Color.yellow.opacity(0.3) : Color.orange.opacity(0.35),
                                in: RoundedRectangle(cornerRadius: 4))
                Text(warning.claim)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text((warning.missing + warning.misplaced).joined(separator: ", "))
                .font(.callout)
                .foregroundStyle(.secondary)

            if !cited.isEmpty {
                HStack(spacing: 4) {
                    Text("อ้างจาก").font(.caption).foregroundStyle(.secondary)
                    ForEach(cited, id: \.id) { segment in
                        CitationChip(job: job, segment: segment)
                    }
                }
            }
            ForEach(Array(warning.quotes.enumerated()), id: \.offset) { _, quote in
                Text("\u{201C}\(quote)\u{201D}")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

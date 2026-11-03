import AppKit
import CoreText

/// Builds real, multi-page PDFs straight from CoreText.
///
/// Drawn rather than printed because Thai needs specific handling: tone marks and
/// upper vowels stack above the line, so the default leading clips them, and line
/// breaking has to fall to ICU since Thai has no spaces between words.
enum PDFExporter {
    /// A4 at 72 dpi.
    private static let pageSize = CGSize(width: 595, height: 842)
    private static let margin: CGFloat = 56

    static func data(from content: NSAttributedString) -> Data? {
        guard content.length > 0 else { return nil }
        let output = NSMutableData()
        guard let consumer = CGDataConsumer(data: output) else { return nil }
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }

        let framesetter = CTFramesetterCreateWithAttributedString(content)
        let textRect = CGRect(x: margin,
                              y: margin + 22,
                              width: pageSize.width - margin * 2,
                              height: pageSize.height - margin * 2 - 22)
        let path = CGPath(rect: textRect, transform: nil)

        var location = 0
        var page = 0
        while location < content.length {
            context.beginPDFPage(nil)
            context.textMatrix = .identity

            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: location, length: 0), path, nil)
            CTFrameDraw(frame, context)

            let visible = CTFrameGetVisibleStringRange(frame)
            page += 1
            drawFooter(page: page, in: context)
            context.endPDFPage()

            // A frame that fits nothing would loop forever — bail instead.
            guard visible.length > 0 else { break }
            location += visible.length
        }

        context.closePDF()
        return output as Data
    }

    private static func drawFooter(page: Int, in context: CGContext) {
        let text = NSAttributedString(string: "\(page)", attributes: [
            .font: NSFont.systemFont(ofSize: 9),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        let line = CTLineCreateWithAttributedString(text)
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        context.textPosition = CGPoint(x: (pageSize.width - CGFloat(width)) / 2, y: margin * 0.6)
        CTLineDraw(line, context)
    }
}

/// Turns a job into printable pages. Kept separate from the drawing code so the
/// document structure is easy to read and change.
enum TranscriptDocument {
    enum Part {
        case summary, transcript
    }

    static func build(job: Job, corrected: Bool, parts: Set<Part>) -> NSAttributedString {
        let document = NSMutableAttributedString()
        document.append(heading(job.filename, size: 19, weight: .semibold, spacingAfter: 4))
        document.append(body(metaLine(job), size: 9.5, color: .secondaryLabelColor, spacingAfter: 14))

        if parts.contains(.summary), let summary = job.summary {
            document.append(heading("สรุป", size: 14, weight: .semibold, spacingAfter: 6))
            document.append(body(summary.tldr, size: 11.5, spacingAfter: 12))

            if !summary.bullets.isEmpty {
                document.append(heading("ประเด็นสำคัญ", size: 12, weight: .medium, spacingAfter: 4))
                for item in summary.bullets {
                    document.append(body("•  \(item)", size: 11, spacingAfter: 3))
                }
                document.append(body("", size: 8, spacingAfter: 6))
            }
            if !summary.actions.isEmpty {
                document.append(heading("สิ่งที่ต้องทำต่อ", size: 12, weight: .medium, spacingAfter: 4))
                for item in summary.actions {
                    document.append(body("☐  \(item)", size: 11, spacingAfter: 3))
                }
                document.append(body("", size: 8, spacingAfter: 6))
            }
            if !summary.keywords.isEmpty {
                document.append(heading("คำสำคัญ", size: 12, weight: .medium, spacingAfter: 4))
                document.append(body(summary.keywords.joined(separator: " · "), size: 11,
                                     color: .secondaryLabelColor, spacingAfter: 10))
            }
            if let warnings = summary.warnings, !warnings.isEmpty {
                document.append(heading("ต้องตรวจสอบ", size: 12, weight: .medium, spacingAfter: 4))
                document.append(body("ตัวเลขและวันเหล่านี้อยู่ในสรุป แต่ไม่มีในข้อความถอดเสียง ควรฟังเสียงจริงก่อนนำไปใช้",
                                     size: 10, color: .secondaryLabelColor, spacingAfter: 4))
                for warning in warnings {
                    document.append(body("•  \(warning)", size: 10, spacingAfter: 3))
                }
                document.append(body("", size: 8, spacingAfter: 8))
            }
        }

        if parts.contains(.transcript), !job.segments.isEmpty {
            if parts.contains(.summary) { document.append(body("", size: 10, spacingAfter: 10)) }
            document.append(heading("ข้อความถอดเสียง", size: 14, weight: .semibold, spacingAfter: 8))

            for segment in job.segments {
                let speaker = job.speaker(segment.speakerId)?.displayName
                let prefix = speaker.map { "[\(segment.startLabel)] \($0):" } ?? "[\(segment.startLabel)]"
                let line = NSMutableAttributedString()
                line.append(NSAttributedString(string: prefix + " ", attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]))
                line.append(NSAttributedString(string: segment.display(corrected: corrected), attributes: [
                    .font: NSFont.systemFont(ofSize: 10.5),
                    .foregroundColor: NSColor.textColor,
                ]))
                line.addAttribute(.paragraphStyle, value: paragraph(spacingAfter: 3),
                                  range: NSRange(location: 0, length: line.length))
                line.append(NSAttributedString(string: "\n"))
                document.append(line)
            }
        }
        return document
    }

    private static func metaLine(_ job: Job) -> String {
        var parts = ["ความยาว \(job.durationLabel)"]
        if let language = job.detectedLanguage { parts.append("ภาษา \(language)") }
        if !job.asrModel.isEmpty { parts.append(job.asrModel) }
        if job.hasSpeakers { parts.append("ผู้พูด \((job.speakers ?? []).count) คน") }
        parts.append(DateFormatter.localizedString(from: job.createdAt, dateStyle: .medium, timeStyle: .short))
        return parts.joined(separator: "  ·  ")
    }

    /// Thai stacks marks above and below the baseline, so lines need more room
    /// than the Latin default or the marks get clipped by the line above.
    private static func paragraph(spacingAfter: CGFloat) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.38
        style.paragraphSpacing = spacingAfter
        style.lineBreakMode = .byWordWrapping
        return style
    }

    private static func heading(_ text: String, size: CGFloat, weight: NSFont.Weight,
                                spacingAfter: CGFloat) -> NSAttributedString {
        NSAttributedString(string: text + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: NSColor.textColor,
            .paragraphStyle: paragraph(spacingAfter: spacingAfter),
        ])
    }

    private static func body(_ text: String, size: CGFloat,
                             color: NSColor = .textColor, spacingAfter: CGFloat) -> NSAttributedString {
        NSAttributedString(string: text + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: size),
            .foregroundColor: color,
            .paragraphStyle: paragraph(spacingAfter: spacingAfter),
        ])
    }
}

import CoreGraphics
import Vision

/// One recognized line of text with its location in the source image.
/// `boundingBox` is Vision's normalized rect (0...1, origin bottom-left).
struct RecognizedLine: Equatable {
    let text: String
    let boundingBox: CGRect
}

enum OCRService {
    /// Synchronous OCR; call off the main thread. Recognizes English, Thai,
    /// and Chinese so the pipeline can translate any of them.
    /// `languageCorrection` is the expensive part on large images; callers
    /// that only need boxes fast can turn it off.
    /// `thaiFirst`: for Thai/English pages. Vision's language auto-detect reads
    /// a mostly-English line as all English and garbles the Thai words in it
    /// ("ปรับเป็น" came out as "1š1w"); a fixed Thai-then-English list reads
    /// both scripts correctly and is faster. It can't read Chinese, so callers
    /// pass false whenever Chinese may be on screen.
    static func recognizeLines(in image: CGImage, languageCorrection: Bool = true, thaiFirst: Bool = false) throws -> [RecognizedLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = languageCorrection
        if thaiFirst {
            request.recognitionLanguages = ["th-TH", "en-US"]
            request.automaticallyDetectsLanguage = false
        } else {
            request.recognitionLanguages = ["en-US", "th-TH", "zh-Hans", "zh-Hant"]
            request.automaticallyDetectsLanguage = true
        }

        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])

        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first,
                  !candidate.string.trimmingCharacters(in: .whitespaces).isEmpty
            else { return nil }
            return RecognizedLine(text: candidate.string, boundingBox: observation.boundingBox)
        }
    }
}
